-module(rabbit_clusterer_utils).

-include("rabbit_clusterer.hrl").

-export([default_config/0,
         proplist_config_to_record/1,
         record_config_to_proplist/2,
         compare_configs/2,
         wipe_mnesia/0,
         merge_configs/3,
         add_node_id/4,
         eliminate_mnesia_dependencies/0,
         configure_cluster/1,
         stop_mnesia/0,
         stop_rabbit/0,
         ensure_start_mnesia/0,
         detect_melisma/2,
         nodenames/1,
         node_in_config/2,
         node_in_config/1
        ]).


%%----------------------------------------------------------------------------
%% Config loading / conversion
%%----------------------------------------------------------------------------

%% Note that here we intentionally deal with NodeID being in the
%% proplist as on disk but not in the #config record.

default_config() ->
    proplist_config_to_record(
      [{nodes, [{node(), disc}]},
       {version, 0},
       {gospel, {node, node()}},
       {shutdown_timeout, infinity}
      ]).

required_keys() ->
    [nodes, version, gospel, shutdown_timeout].

optional_keys() ->
    NodeID = create_node_id(),
    [{map_node_id, orddict:from_list([{node(), NodeID}])},
     {map_id_node, orddict:from_list([{NodeID, node()}])},
     {node_id, NodeID}].

proplist_config_to_record(Proplist) when is_list(Proplist) ->
    ok = check_required_keys(Proplist),
    Proplist1 = add_optional_keys(Proplist),
    Fields = record_info(fields, config),
    {_Pos, Config = #config { nodes = Nodes }} =
        lists:foldl(fun (FieldName, {Pos, ConfigN}) ->
                            Value = proplists:get_value(FieldName, Proplist1),
                            {Pos + 1, setelement(Pos, ConfigN, Value)}
                    end, {2, #config {}}, Fields),
    ok = validate_config(Config),
    Config1 = Config #config { nodes = normalise_nodes(Nodes) },
    NodeID = proplists:get_value(node_id, Proplist1),
    true = is_binary(NodeID), %% ASSERTION
    {NodeID, Config1}.

check_required_keys(Proplist) ->
    case required_keys() -- proplists:get_keys(Proplist) of
        []      -> ok;
        Missing -> {error, rabbit_misc:format(
                             "Required keys missing from cluster config: ~p",
                             [Missing])}
    end.

add_optional_keys(Proplist) ->
    lists:foldr(fun ({Key, _Default} = E, ProplistN) ->
                        case proplists:is_defined(Key, ProplistN) of
                            true  -> ProplistN;
                            false -> [E | ProplistN]
                        end
                end, Proplist, optional_keys()).

validate_config(Config) ->
    {Result, _Pos} =
        lists:foldl(fun (FieldName, {ok, Pos}) ->
                            {validate_config_key(
                               FieldName, element(Pos, Config), Config),
                             Pos+1};
                        (_FieldName, {{error, _E}, _Pos} = Err) ->
                            Err
                    end, {ok, 2}, record_info(fields, config)),
    Result.

validate_config_key(version, Version, _Config)
  when is_integer(Version) andalso Version >= 0 ->
    ok;
validate_config_key(version, Version, _Config) ->
    {error, rabbit_misc:format("Require version to be non-negative integer: ~p",
                               [Version])};
validate_config_key(gospel, reset, _Config) ->
    ok;
validate_config_key(gospel, {node, Node}, Config = #config { nodes = Nodes }) ->
    case [true || N <- Nodes,
                  Node =:= N orelse
                  {Node, disc} =:= N orelse
                  {Node, disk} =:= N] of
        []    -> {error, rabbit_misc:format(
                           "Node in gospel (~p) is not in nodes (~p)",
                           [Node, Config #config.nodes])};
        [_|_] -> ok
    end;
validate_config_key(gospel, Gospel, _Config) ->
    {error, rabbit_misc:format("Invalid gospel setting: ~p", [Gospel])};
validate_config_key(shutdown_timeout, infinity, _Config) ->
    ok;
validate_config_key(shutdown_timeout, Timeout, _Config)
  when is_integer(Timeout) andalso Timeout >= 0 ->
    ok;
validate_config_key(shutdown_timeout, Timeout, _Config) ->
    {error,
     rabbit_misc:format(
       "Require shutdown_timeout to be 'infinity' or non-negative integer: ~p",
       [Timeout])};
validate_config_key(nodes, Nodes, _Config) when is_list(Nodes) ->
    {Result, Disc, NodeNames} =
        lists:foldr(
          fun ({Node, disc}, {ok, _, NN}) when is_atom(Node) ->
                  {ok, true, [Node | NN]};
              ({Node, disk}, {ok, _, NN}) when is_atom(Node) ->
                  {ok, true, [Node | NN]};
              ({Node, ram }, {ok, D, NN}) when is_atom(Node) ->
                  {ok, D,    [Node | NN]};
              (Node,         {ok, _, NN}) when is_atom(Node) ->
                  {ok, true, [Node | NN]};
              (Other,        {ok, _, _NN}) ->
                  {error, rabbit_misc:format("Invalid node: ~p", [Other]), []};
              (_, {error, _E, _NN} = Err) -> Err
          end, {ok, false, []}, Nodes),
    case {Result, Disc, length(NodeNames) =:= length(lists:usort(NodeNames))} of
        {ok, true, true} ->
            ok;
        {ok, true, false} ->
            {error, rabbit_misc:format(
                      "Some nodes specified more than once: ~p", [NodeNames])};
        {ok, false, _} ->
            {error, rabbit_misc:format(
                      "Require at least one disc node: ~p", [Nodes])};
        {error, Err, _} ->
            {error, Err}
    end;
validate_config_key(nodes, Nodes, _Config) ->
    {error,
     rabbit_misc:format("Require nodes to be a list of nodes: ~p", [Nodes])};
validate_config_key(map_node_id, _Orddict, _Config) ->
    ok;
validate_config_key(map_id_node, _Orddict, _Config) ->
    ok.

normalise_nodes(Nodes) when is_list(Nodes) ->
    lists:usort(
      lists:map(fun ({Node, disc} = E) when is_atom(Node) -> E;
                    ({Node, disk})     when is_atom(Node) -> {Node, disc};
                    (Node)             when is_atom(Node) -> {Node, disc};
                    ({Node, ram} = E)  when is_atom(Node) -> E
                end, Nodes)).

%% We just regenerate map_id_node rather than trying to tidy both to
%% match. Easy to ensure correctness and for the small maps we're
%% dealing with it'll be just as fast.
tidy_node_id_maps(NodeID, Config = #config { nodes = Nodes,
                                             map_node_id = NodeToID }) ->
    %% We always remove ourself from the maps to take into account our
    %% own node_id has changed (and then add ourself back in).
    MyNode = node(),
    NodeNames = [N || {N, _} <- Nodes, N =/= MyNode],
    NodesToRemove = orddict:fetch_keys(NodeToID) -- NodeNames,
    NodeToID1 = lists:foldr(fun orddict:erase/2, NodeToID, NodesToRemove),
    %% There's a possibility that we need to add in the mapping for
    %% the local node (consider that a previous config didn't include
    %% ourself, but a new one does).
    NodeToID2 = case proplists:is_defined(node(), Nodes) of
                    true  -> orddict:store(node(), NodeID, NodeToID1);
                    false -> NodeToID1
                end,
    IDToNode = orddict:fold(fun (Node, ID, IDToNodeN) ->
                                    orddict:store(ID, Node, IDToNodeN)
                            end, orddict:new(), NodeToID2),
    Config #config { map_node_id = NodeToID2, map_id_node = IDToNode }.

%% We also rely on the rebuilding in the above func in here. High
%% coupling, but the funcs are side by side and it keeps the code
%% simpler.
merge_node_id_maps(NodeID,
                   ConfigDest = #config { map_node_id = NodeToIDDest },
                   _ConfigSrc = #config { map_node_id = NodeToIDSrc }) ->
    NodeToIDDest1 = orddict:merge(fun (_Node, IDDest, _IDSrc) -> IDDest end,
                                  NodeToIDDest, NodeToIDSrc),
    tidy_node_id_maps(NodeID,
                      ConfigDest #config { map_node_id = NodeToIDDest1 }).

merge_configs(NodeID, ConfigDest, ConfigSrc = #config {}) ->
    merge_node_id_maps(NodeID, ConfigDest, ConfigSrc);
merge_configs(_NodeID, Config, undefined) ->
    Config.
%% We deliberately don't have either of the other cases.

add_node_id(NewNode, NewNodeID, NodeID,
            Config = #config { map_node_id = NodeToID,
                               map_id_node = IDToNode }) ->
    {Changed, IDToNode1} =
        case orddict:find(NewNode, NodeToID) of
            error            -> {false, IDToNode};
            {ok, NewNodeID}  -> {false, IDToNode};
            {ok, NewNodeID1} -> {true,  orddict:erase(NewNodeID1, IDToNode)}
        end,
    {Changed, tidy_node_id_maps(
                NodeID, Config #config {
                          map_node_id =
                              orddict:store(NewNode, NewNodeID, NodeToID),
                          map_id_node =
                              orddict:store(NewNodeID, NewNode, IDToNode1) })}.

record_config_to_proplist(NodeID, Config = #config {}) ->
    Fields = record_info(fields, config),
    {_Pos, Proplist} =
        lists:foldl(
          fun (FieldName, {Pos, ProplistN}) ->
                  {Pos + 1, [{FieldName, element(Pos, Config)} | ProplistN]}
          end, {2, []}, Fields),
    [{node_id, NodeID} | Proplist].

%% We very deliberately completely ignore the map_* fields here. They
%% are not semantically important from the POV of config equivalence.
compare_configs(#config { version = V, gospel = GA, nodes = NA,
                          shutdown_timeout = STA },
                #config { version = V, gospel = GB, nodes = NB,
                          shutdown_timeout = STB }) ->
    case {[GA, STA, lists:usort(NA)], [GB, STB, lists:usort(NB)]} of
        {EQ, EQ} -> eq;
        _        -> invalid
    end;
compare_configs(#config { version = VA },
                #config { version = VB }) ->
    case VA > VB of
        true  -> gt;
        false -> lt
    end.

%% If the config has changed, we need to figure out whether we need to
%% do a full join (which may well include wiping out mnesia) or
%% whether the config has simply evolved and we can do something
%% softer (maybe nothing at all). Essentially, if the gospel node in
%% the new config is someone we thought we knew but who's been reset
%% (so their node_id has changed) then we'll need to do a fresh sync
%% to them.
%% Yes, melisma is a surprising choice. But 'compatible' or 'upgrade'
%% isn't right either. I like the idea of a cluster continuing to
%% slide from one config to another, hence melisma.
detect_melisma(#config { gospel = reset }, _OldConfig) ->
    false;
detect_melisma(#config {}, undefined) ->
    false;
detect_melisma(#config { gospel = {node, Node}, map_node_id = MapNodeIDNew },
               ConfigOld = #config { map_node_id = MapNodeIDOld }) ->
    case node_in_config(Node, ConfigOld) of
        true  -> case {orddict:find(Node, MapNodeIDNew),
                       orddict:find(Node, MapNodeIDOld)} of
                     {{ok, IdA}, {ok, IdB}} when IdA =/= IdB -> false;
                     {_        , _        }                  -> true
                 end;
        false -> false
    end.

node_in_config(Config) ->
    node_in_config(node(), Config).

node_in_config(Node, #config { nodes = Nodes }) ->
    [] =/= [N || {N, _} <- Nodes, N =:= Node].

nodenames(#config { nodes = Nodes }) ->
    nodenames(Nodes);
nodenames(Nodes) when is_list(Nodes) ->
    [N || {N, _} <- Nodes].


%%----------------------------------------------------------------------------
%% Node ID and mnesia
%%----------------------------------------------------------------------------

create_node_id() ->
    %% We can't use rabbit_guid here because it may not have been
    %% started at this stage. In reality, this isn't a massive
    %% problem: the fact we need to create a node_id implies that
    %% we're a fresh node, so the guid serial will be 0 anyway.
    erlang:md5(term_to_binary({node(), make_ref()})).

wipe_mnesia() ->
    ok = stop_mnesia(),
    ok = rabbit_mnesia:force_reset(),
    ok = ensure_start_mnesia().

stop_mnesia() ->
    case application:stop(mnesia) of
        ok                             -> ok;
        {error, {not_started, mnesia}} -> ok;
        Other                          -> Other
    end.

ensure_start_mnesia() ->
    ok = application:ensure_started(mnesia).

eliminate_mnesia_dependencies() ->
    %% rabbit_table:force_load() does not error if
    %% mnesia:force_load_table errors(!) Thus we can safely run this
    %% even in clean state - i.e. one where neither the schema nor any
    %% tables actually exist.
    ok = rabbit_table:force_load(),
    ok = rabbit_node_monitor:reset_cluster_status().

configure_cluster(Nodes = [_|_]) ->
    case application:load(rabbit) of
        ok                                -> ok;
        {error, {already_loaded, rabbit}} -> ok
    end,
    NodeNames = nodenames(Nodes),
    Mode = proplists:get_value(node(), Nodes),
    ok = application:set_env(rabbit, cluster_nodes, {NodeNames, Mode}).

stop_rabbit() ->
    case application:stop(rabbit) of
        ok                             -> ok;
        {error, {not_started, rabbit}} -> ok;
        Other                          -> Other
    end.
