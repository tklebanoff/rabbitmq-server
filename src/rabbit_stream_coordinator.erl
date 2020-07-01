%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% Copyright (c) 2012-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%
-module(rabbit_stream_coordinator).

-behaviour(ra_machine).

-export([start/0]).
-export([format_ra_event/2]).

-export([init/1,
         apply/3,
         state_enter/2,
         init_aux/1,
         handle_aux/6,
         tick/2]).

-export([subscribe/2,
         unsubscribe/2]).

-export([recover/0,
         start_cluster/1,
         delete_cluster/2,
         add_replica/2,
         delete_replica/2]).

-export([phase_repair_mnesia/2,
         phase_start_cluster/1,
         phase_delete_cluster/2,
         phase_check_quorum/1,
         phase_start_new_leader/1,
         phase_stop_replicas/1,
         phase_start_replica/3,
         phase_delete_replica/2]).

-export([log_overview/1]).

-define(STREAM_COORDINATOR_STARTUP, {stream_coordinator_startup, self()}).
-define(TICK_TIMEOUT, 60000).
-define(RESTART_TIMEOUT, 1000).

-record(?MODULE, {streams, monitors}).

start() ->
    Nodes = rabbit_mnesia:cluster_nodes(all),
    ServerId = {?MODULE, node()},
    case ra:restart_server(ServerId) of
        {error, Reason} when Reason == not_started orelse
                             Reason == name_not_registered -> 
            case ra:start_server(make_ra_conf(node(), Nodes)) of
                ok ->
                    global:set_lock(?STREAM_COORDINATOR_STARTUP),
                    case find_members(Nodes) of
                        [] ->
                            %% We're the first (and maybe only) one
                            ra:trigger_election(ServerId);
                        Members ->
                            %% What to do if we get a timeout?
                            {ok, _, _} = ra:add_member(Members, ServerId, 30000)
                    end,
                    global:del_lock(?STREAM_COORDINATOR_STARTUP),
                    _ = ra:members(ServerId),
                    ok;
                Error ->
                    exit(Error)
            end;
        ok ->
            ok;
        Error ->
            exit(Error)
    end.

find_members([]) ->
    [];
find_members([Node | Nodes]) ->
    case ra:members({?MODULE, Node}) of
        {_, Members, _} ->
            Members;
        {error, noproc} ->
            find_members(Nodes);
        {timeout, _} ->
            %% not sure what to do here
            find_members(Nodes)
    end.

-spec subscribe(Name :: string(), pid()) -> {error, term()} | {ok, Reply :: term(), Leader :: ra:server_id()}.
subscribe(StreamId, Pid) ->
    process_command({subscribe, #{stream_id => StreamId,
                                  subscriber => Pid}}).

-spec unsubscribe(Name :: string(), pid()) -> {error, term()} | {ok, Reply :: term(), Leader :: ra:server_id()}.
unsubscribe(StreamId, Pid) ->
    process_command({unsubscribe, #{stream_id => StreamId,
                                    subscriber => Pid}}).

recover() ->
    ra:restart_server({?MODULE, node()}).

start_cluster(Q) ->
    process_command({start_cluster, #{queue => Q}}).

delete_cluster(StreamId, ActingUser) ->
    process_command({delete_cluster, #{stream_id => StreamId, acting_user => ActingUser}}).

add_replica(StreamId, Node) ->
    process_command({start_replica, #{stream_id => StreamId, node => Node,
                                      retries => 1}}).

delete_replica(StreamId, Node) ->
    process_command({delete_replica, #{stream_id => StreamId, node => Node}}).

process_command(Cmd) ->
    Servers = ensure_coordinator_started(),
    process_command(Servers, Cmd).

process_command([], _Cmd) ->
    {error, coordinator_unavailable};
process_command([Server | Servers], {CmdName, _} = Cmd) ->
    case ra:process_command(Server, Cmd) of
        {timeout, _} ->
            rabbit_log:warning("Coordinator timeout on server ~p when processing command ~p",
                               [Server, CmdName]),
            process_command(Servers, Cmd);
        {error, noproc} ->
            process_command(Servers, Cmd);
        Reply ->
            Reply
    end.

ensure_coordinator_started() ->
    Local = {?MODULE, node()},
    AllNodes = all_nodes(),
    case ra:restart_server(Local) of
        {error, Reason} when Reason == not_started orelse
                             Reason == name_not_registered ->
            OtherNodes = all_nodes() -- [Local],
            %% We can't use find_members/0 here as a process that timeouts means the cluster is up
            case lists:filter(fun(N) -> global:whereis_name(N) =/= undefined end, OtherNodes) of
                [] ->
                    start_coordinator_cluster();
                _ ->
                    OtherNodes
            end;
        ok ->
            AllNodes;
        {error, {already_started, _}} ->
            AllNodes;
        _ ->
            AllNodes
    end.

start_coordinator_cluster() ->
    Nodes = rabbit_mnesia:cluster_nodes(running),
    case ra:start_cluster([make_ra_conf(Node, Nodes) || Node <-  Nodes]) of
        {ok, Started, _} ->
            Started;
        {error, cluster_not_formed} ->
            rabbit_log:warning("Stream coordinator cluster not formed", []),
            []
    end.

all_nodes() ->
    Nodes = rabbit_mnesia:cluster_nodes(running) -- [node()],
    [{?MODULE, Node} || Node <- [node() | Nodes]].

init(_Conf) ->
    #?MODULE{streams = #{},
             monitors = #{}}.

apply(_Meta, {subscribe, #{stream_id := StreamId, subscriber := Subscriber}},
      #?MODULE{streams = Streams,
               monitors = Monitors0} = State) ->
    case maps:get(StreamId, Streams, undefined) of
        undefined ->
            {State, {error, not_found}, []};
        #{conf := Conf,
          subscribers := Subs} = SState0 ->
            case lists:member(Subscriber, Subs) of
                true ->
                    {State, ok, []};
                false ->
                    SState = SState0#{subscribers  => [Subscriber | Subs]},
                    Monitors = maybe_update_subscribers(Subscriber, StreamId, Monitors0),
                    {State#?MODULE{streams = Streams#{StreamId => SState},
                                   monitors = Monitors},
                     ok, [{monitor, process, Subscriber},
                          leader_event(Conf, Subscriber)]}
            end
    end;
apply(_Meta, {unsubscribe, #{stream_id := StreamId, subscriber := Subscriber}},
      #?MODULE{streams = Streams,
               monitors = Monitors0} = State) ->
    case maps:get(StreamId, Streams, undefined) of
        undefined ->
            {State, ok, []};
        #{subscribers := Subs} = SState0 ->
            case lists:member(Subscriber, Subs) of
                false ->
                    {State, ok, []};
                true ->
                    Monitors = case maps:get(Subscriber, Monitors0) of
                                   {[StreamId], subscriber} ->
                                       maps:remove(Subscriber, Monitors0);
                                   {SubscribedTo, subscriber} ->
                                       maps:put(Subscriber, {lists:delete(StreamId, SubscribedTo), subscriber}, Monitors0)
                               end,
                    SState = SState0#{subscribers  => lists:delete(Subscriber, Subs)},
                    {State#?MODULE{streams = Streams#{StreamId => SState},
                                   monitors = Monitors}, ok, []}
            end
    end;
apply(#{from := From}, {start_cluster, #{queue := Q}}, #?MODULE{streams = Streams} = State) ->
    #{name := StreamId} = Conf = amqqueue:get_type_state(Q),
    case maps:is_key(StreamId, Streams) of
        true ->
            {State, '$ra_no_reply', wrap_reply(From, {error, already_started})};
        false ->
            Phase = phase_start_cluster,
            PhaseArgs = [Q],
            SState = #{state => start_cluster,
                       phase => Phase,
                       phase_args => PhaseArgs,
                       conf => Conf,
                       reply_to => From,
                       pending_cmds => [],
                       pending_replicas => [],
                       subscribers => []},
            rabbit_log:debug("rabbit_stream_coordinator: ~p entering phase_start_cluster", [StreamId]),
            {State#?MODULE{streams = maps:put(StreamId, SState, Streams)}, '$ra_no_reply', 
             [{aux, {phase, StreamId, Phase, PhaseArgs}}]}
    end;
apply(_Meta, {start_cluster_reply, Q}, #?MODULE{streams = Streams,
                                                monitors = Monitors0} = State) ->
    #{name := StreamId,
      leader_pid := LeaderPid,
      replica_pids := ReplicaPids} = Conf = amqqueue:get_type_state(Q),
    SState0 = maps:get(StreamId, Streams),
    Phase = phase_repair_mnesia,
    PhaseArgs = [new, Q],
    SState = SState0#{conf => Conf,
                      phase => Phase,
                      phase_args => PhaseArgs},
    Monitors = lists:foldl(fun(Pid, M) ->
                                   maps:put(Pid, {StreamId, follower}, M)
                           end, maps:put(LeaderPid, {StreamId, leader}, Monitors0), ReplicaPids),
    MonitorActions = [{monitor, process, Pid} || Pid <- ReplicaPids ++ [LeaderPid]],
    rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p "
                     "after start_cluster_reply", [StreamId, Phase]),
    {State#?MODULE{streams = maps:put(StreamId, SState, Streams),
                   monitors = Monitors}, ok,
     MonitorActions ++ [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
apply(_Meta, {start_replica_failed, StreamId, Node, Retries, Reply},
      #?MODULE{streams = Streams0} = State) ->
    rabbit_log:debug("rabbit_stream_coordinator: ~p start replica failed", [StreamId]),
    #{pending_replicas := Pending,
      reply_to := From} = SState = maps:get(StreamId, Streams0),
    Streams = Streams0#{StreamId => clear_stream_state(SState#{pending_replicas =>
                                                                   add_unique(Node, Pending)})},
    reply_and_run_pending(
      From, StreamId, ok, Reply,
      [{mod_call, timer, apply_after,
        [?RESTART_TIMEOUT * Retries, ra, pipeline_command,
         [{?MODULE, node()},
          {start_replica, #{stream_id => StreamId,
                            node => Node,
                            from => undefined,
                            retries => Retries + 1}}]]}],
      State#?MODULE{streams = Streams});
apply(_Meta, {phase_finished, StreamId, Reply}, #?MODULE{streams = Streams0} = State) ->
    rabbit_log:debug("rabbit_stream_coordinator: ~p phase finished", [StreamId]),
    #{reply_to := From} = SState = maps:get(StreamId, Streams0),
    Streams = Streams0#{StreamId => clear_stream_state(SState)},
    reply_and_run_pending(From, StreamId, ok, Reply, [], State#?MODULE{streams = Streams});
apply(#{from := From}, {start_replica, #{stream_id := StreamId, node := Node,
                                         retries := Retries}} = Cmd,
      #?MODULE{streams = Streams0} = State) ->
    case maps:get(StreamId, Streams0, undefined) of
        undefined ->
            case From of
                undefined ->
                    {State, ok, []};
                _ ->
                    {State, '$ra_no_reply', wrap_reply(From, {error, not_found})}
            end;
        #{conf := Conf,
          state := running} = SState0 ->
            Phase = phase_start_replica,
            PhaseArgs = [Node, Conf, Retries],
            SState = update_stream_state(From, start_replica, Phase, PhaseArgs, SState0),
            rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p on node ~p",
                             [StreamId, Phase, Node]),
            {State#?MODULE{streams = Streams0#{StreamId => SState}}, '$ra_no_reply',
             [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
        SState0 ->
            Streams = maps:put(StreamId, add_pending_cmd(From, Cmd, SState0), Streams0),
            {State#?MODULE{streams = Streams}, '$ra_no_reply', []}
    end;
apply(_Meta, {start_replica_reply, Pid, #{name := StreamId} = Conf},
      #?MODULE{streams = Streams, monitors = Monitors0} = State) ->
    Phase = phase_repair_mnesia,
    PhaseArgs = [update, Conf],
    rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p after start replica", [StreamId, Phase]),
    #{pending_replicas := Pending} = SState0 = maps:get(StreamId, Streams),
    SState = SState0#{conf => Conf,
                      phase => Phase,
                      phase_args => PhaseArgs,
                      pending_replicas => lists:delete(node(Pid), Pending)},
    {State#?MODULE{streams = Streams#{StreamId => SState},
                   monitors = Monitors0#{Pid => {StreamId, follower}}}, ok,
     [{monitor, process, Pid}, {aux, {phase, StreamId, Phase, PhaseArgs}}]};
apply(#{from := From}, {delete_replica, #{stream_id := StreamId, node := Node}} = Cmd,
      #?MODULE{streams = Streams0,
               monitors = Monitors0} = State) ->
    case maps:get(StreamId, Streams0, undefined) of
        undefined ->
            {State, '$ra_no_reply', wrap_reply(From, {error, not_found})};
        #{conf := Conf0,
          state := running,
          pending_replicas := Pending0} = SState0 ->
            Replicas0 = maps:get(replica_nodes, Conf0),
            ReplicaPids0 = maps:get(replica_pids, Conf0),
            case lists:member(Node, Replicas0) of
                false ->
                    reply_and_run_pending(From, StreamId, '$ra_no_reply', ok, [], State);
                true ->
                    [Pid] = lists:filter(fun(P) -> node(P) == Node end, ReplicaPids0),
                    ReplicaPids = lists:delete(Pid, ReplicaPids0),
                    Replicas = lists:delete(Node, Replicas0),
                    Pending = lists:delete(Node, Pending0),
                    Conf = Conf0#{replica_pids => ReplicaPids,
                                  replica_nodes => Replicas},
                    Phase = phase_delete_replica,
                    PhaseArgs = [Node, Conf],
                    SState = update_stream_state(From, delete_replica,
                                                 Phase, PhaseArgs,
                                                 SState0#{conf => Conf0,
                                                          pending_replicas => Pending}),
                    rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p on node ~p", [StreamId, Phase, Node]),
                    {State#?MODULE{monitors = maps:remove(Pid, Monitors0),
                                   streams = Streams0#{StreamId => SState}},
                     '$ra_no_reply',
                     [{demonitor, process, Pid},
                      {aux, {phase, StreamId, Phase, PhaseArgs}}]}
            end;
        SState0 ->
            Streams = maps:put(StreamId, add_pending_cmd(From, Cmd, SState0), Streams0),
            {State#?MODULE{streams = Streams}, '$ra_no_reply', []}
    end;
apply(#{from := From}, {delete_cluster, #{stream_id := StreamId,
                                          acting_user := ActingUser}} = Cmd,
      #?MODULE{streams = Streams0, monitors = Monitors0} = State) ->
    case maps:get(StreamId, Streams0, undefined) of
        undefined ->
            {State, '$ra_no_reply', wrap_reply(From, {ok, 0})};
        #{conf := Conf,
          state := running} = SState0 ->
            ReplicaPids = maps:get(replica_pids, Conf),
            LeaderPid = maps:get(leader_pid, Conf),
            Monitors = lists:foldl(fun(Pid, M) ->
                                           maps:remove(Pid, M)
                                   end, Monitors0, ReplicaPids ++ [LeaderPid]),
            Phase = phase_delete_cluster,
            PhaseArgs = [Conf, ActingUser],
            SState = update_stream_state(From, delete_cluster, Phase, PhaseArgs, SState0),
            Demonitors = [{demonitor, process, Pid} || Pid <- [LeaderPid | ReplicaPids]],
            rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p",
                             [StreamId, Phase]),
            {State#?MODULE{monitors = Monitors,
                           streams = Streams0#{StreamId => SState}}, '$ra_no_reply',
             Demonitors ++ [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
        SState0 ->
            Streams = maps:put(StreamId, add_pending_cmd(From, Cmd, SState0), Streams0),
            {State#?MODULE{streams = Streams}, '$ra_no_reply', []}
    end;
apply(_Meta, {delete_cluster_reply, StreamId}, #?MODULE{streams = Streams,
                                                        monitors = Monitors0} = State0) ->
    #{reply_to := From,
      subscribers := Subs,
      pending_cmds := Pending,
      conf := #{reference := Ref,
                replica_pids := ReplicaPids,
                leader_pid := LeaderPid}} = maps:get(StreamId, Streams),
    Events = emit_queue_deleted_events(Ref, Subs),
    Monitors = lists:foldl(fun(Pid, Acc) ->
                                   maps:remove(Pid, Acc)
                           end, Monitors0, ReplicaPids ++ [LeaderPid]),
    State = State0#?MODULE{streams = maps:remove(StreamId, Streams),
                           monitors = Monitors},
    rabbit_log:debug("rabbit_stream_coordinator: ~p finished delete_cluster_reply",
                     [StreamId]),
    {State, ok, [{aux, {pipeline, Pending}}] ++ wrap_reply(From, {ok, 0}) ++ Events};
apply(_Meta, {down, Pid, _Reason} = Cmd, #?MODULE{streams = Streams,
                                                  monitors = Monitors0} = State) ->
    case maps:get(Pid, Monitors0, undefined) of
        {SubscribedTo, subscriber} ->
            Streams1 = remove_subscriber(Pid, SubscribedTo, Streams),
            {State#?MODULE{monitors = maps:remove(Pid, Monitors0),
                           streams = Streams1}, ok, []};
        {StreamId, Role} ->
            Monitors = maps:remove(Pid, Monitors0),
            case maps:get(StreamId, Streams, undefined) of
                #{state := delete_cluster} ->
                    {State#?MODULE{monitors = Monitors}, ok, []};
                undefined ->
                    {State#?MODULE{monitors = Monitors}, ok, []};
                #{state := running,
                  conf := #{reference := Ref} = Conf0,
                  pending_cmds := Pending0,
                  subscribers := Subs} = SState0 ->
                    case Role of
                        leader ->
                            rabbit_log:info("rabbit_stream_coordinator: ~p leader is down, starting election", [StreamId]),
                            Phase = phase_stop_replicas,
                            PhaseArgs = [Conf0],
                            SState = update_stream_state(undefined, leader_election, Phase, PhaseArgs, SState0),
                            Events = emit_leader_down_events(Ref, Pid, Subs),
                            rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p", [StreamId, Phase]),
                            {State#?MODULE{monitors = Monitors,
                                           streams = Streams#{StreamId => SState}},
                             ok, Events ++ [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
                        follower ->
                            case rabbit_misc:is_process_alive(maps:get(leader_pid, Conf0)) of
                                true ->
                                    Phase = phase_start_replica,
                                    PhaseArgs = [node(Pid), Conf0, 1],
                                    SState = update_stream_state(undefined,
                                                                 replica_restart,
                                                                 Phase, PhaseArgs,
                                                                 SState0),
                                    rabbit_log:debug("rabbit_stream_coordinator: ~p replica on node ~p is down, entering ~p", [StreamId, node(Pid), Phase]),
                                    {State#?MODULE{monitors = Monitors,
                                                   streams = Streams#{StreamId => SState}},
                                     ok, [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
                                false ->
                                    SState = SState0#{pending_cmds => Pending0 ++ [Cmd]},
                                    reply_and_run_pending(undefined, StreamId, ok, ok, [], State#?MODULE{streams = Streams#{StreamId => SState}})
                            end
                    end;
                #{pending_cmds := Pending0} = SState0 ->
                    SState = SState0#{pending_cmds => Pending0 ++ [Cmd]},
                    {State#?MODULE{streams = Streams#{StreamId => SState}}, ok, []}
            end;
        undefined ->
            {State, ok, []}
    end;
apply(_Meta, {start_leader_election, StreamId, NewEpoch, Offsets},
      #?MODULE{streams = Streams} = State) ->
    #{conf := Conf0,
      pending_replicas := Pending} = SState0 = maps:get(StreamId, Streams),
    #{leader_node := Leader,
      replica_nodes := Replicas,
      replica_pids := ReplicaPids} = Conf0,
    NewLeader = find_max_offset(Offsets),
    rabbit_log:info("rabbit_stream_coordinator: ~p starting new leader on node ~p",
                    [StreamId, NewLeader]),
    Conf = Conf0#{epoch => NewEpoch,
                  leader_node => NewLeader,
                  replica_nodes => lists:delete(NewLeader, Replicas ++ [Leader]),
                  replica_pids => delete_replica_pid(NewLeader, ReplicaPids)},
    Phase = phase_start_new_leader,
    PhaseArgs = [Conf],
    SState = case NewLeader of
                 Leader ->
                     SState0#{conf => Conf,
                              phase => Phase,
                              phase_args => PhaseArgs};
                 _ ->
                     %% Leader has changed, we have to ensure that the replica on that
                     %% node is eventually restarted
                     add_pending_cmd(
                       undefined,
                       {start_replica, #{stream_id => StreamId, node => Leader,
                                         retries => 1}},
                       SState0#{conf => Conf,
                                phase => Phase,
                                phase_args => PhaseArgs,
                                pending_replicas => add_unique(Leader, Pending)})
             end,
    rabbit_log:debug("rabbit_stream_coordinator: ~p entering phase_start_new_leader",
                     [StreamId]),
    {State#?MODULE{streams = Streams#{StreamId => SState}}, ok,
     [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
apply(_Meta, {leader_elected, #{name := StreamId,
                                  leader_pid := LeaderPid} = Conf},
      #?MODULE{streams = Streams, monitors = Monitors} = State) ->
    rabbit_log:info("rabbit_stream_coordinator: ~p leader elected", [StreamId]),
    #{subscribers := Subs} = SState0 = maps:get(StreamId, Streams),
    Phase = phase_repair_mnesia,
    PhaseArgs = [update, Conf],
    SState = SState0#{conf => Conf,
                      phase => Phase,
                      phase_args => PhaseArgs},
    Events = emit_leader_up_events(maps:get(reference, Conf), LeaderPid, Subs),
    rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p after "
                     "leader election", [StreamId, Phase]),
    {State#?MODULE{streams = Streams#{StreamId => SState},
                   monitors = maps:put(LeaderPid, {StreamId, leader}, Monitors)}, ok,
     Events ++ [{monitor, process, LeaderPid},
                {aux, {phase, StreamId, Phase, PhaseArgs}}]};
apply(_Meta, {replicas_stopped, StreamId}, #?MODULE{streams = Streams} = State) ->
    #{conf := Conf} = maps:get(StreamId, Streams),
    SState0 = maps:get(StreamId, Streams),
    Phase = phase_check_quorum,
    PhaseArgs = [Conf],
    SState = SState0#{phase => Phase,
                      phase_args => PhaseArgs},
    rabbit_log:info("rabbit_stream_coordinator: ~p all replicas have been stopped, "
                    "checking quorum available", [StreamId]),
    {State#?MODULE{streams = Streams#{StreamId => SState}}, ok,
     [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
apply(_Meta, {stream_updated, #{name := StreamId} = Conf}, #?MODULE{streams = Streams} = State) ->
    SState0 = maps:get(StreamId, Streams),
    Phase = phase_repair_mnesia,
    PhaseArgs = [update, Conf],
    SState = SState0#{conf => Conf,
                      phase => Phase,
                      phase_args => PhaseArgs},
    rabbit_log:debug("rabbit_stream_coordinator: ~p entering ~p after"
                     " stream_updated", [StreamId, Phase]),
    {State#?MODULE{streams = Streams#{StreamId => SState}}, ok,
     [{aux, {phase, StreamId, Phase, PhaseArgs}}]};
apply(Meta, {_, #{from := From}} = Cmd, State) ->
    ?MODULE:apply(Meta#{from => From}, Cmd, State).

state_enter(leader, #?MODULE{streams = Streams}) ->
    maps:fold(fun(_, #{conf := Conf,
                       pending_replicas := Pending,
                       state := State,
                       phase := Phase,
                       phase_args := PhaseArgs}, Acc) ->
                      restart_aux_phase(State, Phase, PhaseArgs, maps:get(name, Conf)) ++
                          pipeline_restart_replica_cmds(maps:get(name, Conf), Pending) ++
                          [{monitor, process, maps:get(leader_pid, Conf)}] ++
                          [{monitor, process, Pid} || Pid <- maps:get(replica_pids, Conf)] ++
                          Acc
              end, [], Streams);
state_enter(recover, _) ->
    put('$rabbit_vm_category', ?MODULE),
    [];
state_enter(_, _) ->
    [].

restart_aux_phase(running, _, _, _) ->
    [];
restart_aux_phase(_State, Phase, PhaseArgs, StreamId) ->
    [{aux, {phase, StreamId, Phase, PhaseArgs}}].

pipeline_restart_replica_cmds(StreamId, Pending) ->
    [{mod_call, timer, apply_after,
      [?RESTART_TIMEOUT, ra, pipeline_command,
       [{?MODULE, node()},
        {start_replica, #{stream_id => StreamId,
                          node => Node,
                          from => undefined,
                          retries => 1}}]]} || Node <- Pending].

tick(_Ts, _State) ->
    [{aux, maybe_resize_coordinator_cluster}].

maybe_resize_coordinator_cluster() ->
    spawn(fun() ->
                  case ra:members({?MODULE, node()}) of
                      {_, Members, _} ->
                          MemberNodes = [Node || {_, Node} <- Members],
                          Running = rabbit_mnesia:cluster_nodes(running),
                          All = rabbit_mnesia:cluster_nodes(all),
                          case Running -- MemberNodes of
                              [] ->
                                  ok;
                              New ->
                                  rabbit_log:warning("New rabbit node(s) detected, "
                                                     "adding stream coordinator in: ~p", [New]),
                                  add_members(Members, New)
                          end,
                          case MemberNodes -- All of
                              [] ->
                                  ok;
                              Old ->
                                  rabbit_log:warning("Rabbit node(s) removed from the cluster, "
                                                     "deleting stream coordinator in: ~p", [Old]),
                                  remove_members(Members, Old)
                          end;
                      _ ->
                          ok
                  end
          end).

add_members(_, []) ->
    ok;
add_members(Members, [Node | Nodes]) ->
    Conf = make_ra_conf(Node, [N || {_, N} <- Members]),
    case ra:start_server(Conf) of
        ok ->
            case ra:add_member(Members, {?MODULE, Node}) of
                {ok, NewMembers, _} ->
                    add_members(NewMembers, Nodes);
                _ ->
                    add_members(Members, Nodes)
            end;
        Error ->
            rabbit_log:warning("Stream coordinator failed to start on node ~p : ~p",
                               [Node, Error]),
            add_members(Members, Nodes)
    end.

remove_members(_, []) ->
    ok;
remove_members(Members, [Node | Nodes]) ->
    case ra:remove_member(Members, {?MODULE, Node}) of
        {ok, NewMembers, _} ->
            remove_members(NewMembers, Nodes);
        _ ->
            remove_members(Members, Nodes)
    end.

init_aux(_Name) ->
    {#{}, undefined}.

%% TODO ensure the dead writer is restarted as a replica at some point in time, increasing timeout?
handle_aux(leader, _, maybe_resize_coordinator_cluster, {Monitors, undefined}, LogState, _) ->
    Pid = maybe_resize_coordinator_cluster(),
    {no_reply, {Monitors, Pid}, LogState, [{monitor, process, aux, Pid}]};
handle_aux(leader, _, maybe_resize_coordinator_cluster, AuxState, LogState, _) ->
    %% Coordinator resizing is still happening, let's ignore this tick event
    {no_reply, AuxState, LogState};
handle_aux(leader, _, {down, Pid, _}, {Monitors, Pid}, LogState, _) ->
    %% Coordinator resizing has finished
    {no_reply, {Monitors, undefined}, LogState};
handle_aux(leader, _, {phase, _, Fun, Args} = Cmd, {Monitors, Coordinator}, LogState, _) ->
    Pid = erlang:apply(?MODULE, Fun, Args),
    Actions = [{monitor, process, aux, Pid}],
    {no_reply, {maps:put(Pid, Cmd, Monitors), Coordinator}, LogState, Actions};
handle_aux(leader, _, {down, Pid, normal}, {Monitors, Coordinator}, LogState, _) ->
    {no_reply, {maps:remove(Pid, Monitors), Coordinator}, LogState};
handle_aux(leader, _, {down, Pid, Reason}, {Monitors0, Coordinator}, LogState, _) ->
    %% The phase has failed, let's retry it
    case maps:get(Pid, Monitors0) of
        {phase, StreamId, phase_start_new_leader, Args} ->
            rabbit_log:warning("Error while starting new leader for stream queue ~p, "
                               "restarting election: ~p", [StreamId, Reason]),
            NewPid = erlang:apply(?MODULE, phase_check_quorum, Args),
            Monitors = maps:put(NewPid, {phase, StreamId, phase_check_quorum, Args},
                                maps:remove(Pid, Monitors0)),
            {no_reply, {Monitors, Coordinator}, LogState};
        {phase, StreamId, Fun, Args} = Cmd ->
            rabbit_log:warning("Error while executing coordinator phase ~p for stream queue ~p ~p",
                               [Fun, StreamId, Reason]),
            NewPid = erlang:apply(?MODULE, Fun, Args),
            Monitors = maps:put(NewPid, Cmd, maps:remove(Pid, Monitors0)),
            {no_reply, {Monitors, Coordinator}, LogState}
    end;
handle_aux(leader, _, {pipeline, Cmds}, AuxState, LogState, _) ->
    [ra:pipeline_command({?MODULE, node()}, Cmd) || Cmd <- Cmds],
    {no_reply, AuxState, LogState};
handle_aux(_, _, _, AuxState, LogState, _) ->
    {no_reply, AuxState, LogState}.

reply_and_run_pending(From, StreamId, Reply, WrapReply, Actions0, #?MODULE{streams = Streams} = State) ->
    #{pending_cmds := Pending} = SState0 = maps:get(StreamId, Streams),
    AuxActions = [{aux, {pipeline, Pending}}],
    SState = maps:put(pending_cmds, [], SState0),
    Actions = case From of
                  undefined ->
                      AuxActions ++ Actions0;
                  _ ->
                      wrap_reply(From, WrapReply) ++ AuxActions ++ Actions0
              end,
    {State#?MODULE{streams = Streams#{StreamId => SState}}, Reply, Actions}.

wrap_reply(From, Reply) ->
    [{reply, From, {wrap_reply, Reply}}].

add_pending_cmd(From, {CmdName, CmdMap}, #{pending_cmds := Pending0} = StreamState) ->
    %% Remove from pending the leader election and automatic replica restart when
    %% the command is delete_cluster
    Pending = case CmdName of
                  delete_cluster ->
                      lists:filter(fun({down, _, _}) ->
                                           false;
                                      (_) ->
                                           true
                                   end, Pending0);
                  _ ->
                      Pending0
              end,
    maps:put(pending_cmds, Pending ++ [{CmdName, maps:put(from, From, CmdMap)}],
             StreamState).

clear_stream_state(StreamState) ->
    StreamState#{reply_to => undefined,
                 state => running,
                 phase => undefined,
                 phase_args => undefined}.

update_stream_state(From, State, Phase, PhaseArgs, StreamState) ->
    StreamState#{reply_to => From,
                 state => State,
                 phase => Phase,
                 phase_args => PhaseArgs}.

phase_start_replica(Node, #{replica_nodes := Replicas0,
                            replica_pids := ReplicaPids0,
                            name := StreamId} = Conf0,
                    Retries) ->
    spawn(
      fun() ->
              %% If a new leader hasn't yet been elected, this will fail with a badmatch
              %% as get_reader_context returns a no proc. An unhandled failure will
              %% crash this monitored process and restart it later.
              %% TODO However, do we want that crash in the log? We might need to try/catch
              %% to provide a log message instead as it's 'expected'. We could try to
              %% verify first that the leader is alive, but there would still be potential
              %% for a race condition in here.
              try
                  case osiris_replica:start(Node, Conf0) of
                      {ok, Pid} ->
                          ReplicaPids = [Pid | delete_replica_pid(Node, ReplicaPids0)],
                          Replicas = add_unique(Node, Replicas0),
                          Conf = Conf0#{replica_pids => ReplicaPids,
                                        replica_nodes => Replicas},
                          ra:pipeline_command({?MODULE, node()},
                                              {start_replica_reply, Pid, Conf});
                      {error, already_present} ->
                          ra:pipeline_command({?MODULE, node()}, {phase_finished, StreamId, ok});
                      {error, {already_started, _}} ->
                          ra:pipeline_command({?MODULE, node()}, {phase_finished, StreamId, ok});
                      {error, Reason} = Error ->
                          rabbit_log:warning("Error while starting replica for ~p : ~p",
                                             [maps:get(name, Conf0), Reason]),
                          ra:pipeline_command({?MODULE, node()},
                                              {start_replica_failed, StreamId, Node, Retries, Error})
                  end
              catch _:E->
                      rabbit_log:warning("Error while starting replica for ~p : ~p",
                                         [maps:get(name, Conf0), E]),
                      ra:pipeline_command({?MODULE, node()},
                                          {start_replica_failed, StreamId, Node, Retries, {error, E}})
              end
      end).

phase_delete_replica(Node, Conf) ->
    spawn(
      fun() ->
              ok = osiris_replica:delete(Node, Conf),
              ra:pipeline_command({?MODULE, node()}, {stream_updated, Conf})
      end).

phase_stop_replicas(#{replica_nodes := Replicas,
                      name := StreamId} = Conf) ->
    spawn(
      fun() ->
              [try
                   osiris_replica:stop(Node, Conf)
               catch _:{{nodedown, _}, _} ->
                       %% It could be the old leader that is still down, it's normal.
                       ok
               end  || Node <- Replicas],
              ra:pipeline_command({?MODULE, node()}, {replicas_stopped, StreamId})
      end).

phase_start_new_leader(#{leader_node := Node} = Conf) ->
    spawn(fun() ->
                  osiris_replica:stop(Node, Conf),
                  %% If the start fails, the monitor will capture the crash and restart it
                  case osiris_writer:start(Conf) of
                      {ok, Pid} ->
                          ra:pipeline_command({?MODULE, node()},
                                              {leader_elected, maps:put(leader_pid, Pid, Conf)});
                      {error, already_present} ->
                          ra:pipeline_command({?MODULE, node()},
                                              {leader_elected, Conf});
                      {error, {already_started, Pid}} ->
                          ra:pipeline_command({?MODULE, node()},
                                              {leader_elected, maps:put(leader_pid, Pid, Conf)})
                  end
          end).

phase_check_quorum(#{name := StreamId,
                     epoch := Epoch,
                     replica_nodes := Nodes} = Conf) ->
    spawn(fun() ->
                  Offsets = find_replica_offsets(Conf),
                  case is_quorum(length(Nodes) + 1, length(Offsets)) of
                      true ->
                          ra:pipeline_command({?MODULE, node()},
                                              {start_leader_election, StreamId, Epoch + 1, Offsets});
                      false ->
                          %% Let's crash this process so the monitor will restart it
                          exit({not_enough_quorum, StreamId})
                  end
          end).

find_replica_offsets(#{replica_nodes := Nodes,
                       leader_node := Leader} = Conf) ->
    lists:foldl(
      fun(Node, Acc) ->
              try
                  %% osiris_log:overview/1 needs the directory - last item of the list
                  case rpc:call(Node, rabbit, is_running, []) of
                      false ->
                          Acc;
                      true ->
                          case rpc:call(Node, ?MODULE, log_overview, [Conf]) of
                              {badrpc, nodedown} ->
                                  Acc;
                              {_Range, Offsets} ->
                                  [{Node, select_highest_offset(Offsets)} | Acc]
                          end
                  end
              catch
                  _:_ ->
                      Acc
              end
      end, [], Nodes ++ [Leader]).

select_highest_offset([]) ->
    empty;
select_highest_offset(Offsets) ->
    lists:last(Offsets).

log_overview(Config) ->
    Dir = osiris_log:directory(Config),
    osiris_log:overview(Dir).

find_max_offset(Offsets) ->
    [{Node, _} | _] = lists:sort(fun({_, {Ao, E}}, {_, {Bo, E}}) ->
                                         Ao >= Bo;
                                    ({_, {_, Ae}}, {_, {_, Be}}) ->
                                         Ae >= Be;
                                    ({_, empty}, _) ->
                                         false;
                                    (_, {_, empty}) ->
                                         true
                                 end, Offsets),
    Node.

is_quorum(1, 1) ->
    true;
is_quorum(NumReplicas, NumAlive) ->
    NumAlive >= ((NumReplicas div 2) + 1).

phase_repair_mnesia(new, Q) ->
    spawn(fun() ->
                  Reply = rabbit_amqqueue:internal_declare(Q, false),
                  #{name := StreamId} = amqqueue:get_type_state(Q),
                  ra:pipeline_command({?MODULE, node()}, {phase_finished, StreamId, Reply})
          end);

phase_repair_mnesia(update, #{reference := QName,
                              leader_pid := LeaderPid,
                              name := StreamId} = Conf) ->
    Fun = fun (Q) ->
                  amqqueue:set_type_state(amqqueue:set_pid(Q, LeaderPid), Conf)
          end,
    spawn(fun() ->
                  case rabbit_misc:execute_mnesia_transaction(
                         fun() ->
                                 rabbit_amqqueue:update(QName, Fun)
                         end) of
                      not_found ->
                          %% This can happen during recovery
                          [Q] = mnesia:dirty_read(rabbit_durable_queue, QName),
                          rabbit_amqqueue:ensure_rabbit_queue_record_is_initialized(Fun(Q));
                      _ ->
                          ok
                  end,
                  ra:pipeline_command({?MODULE, node()}, {phase_finished, StreamId, ok})
          end).

phase_start_cluster(Q0) ->
    spawn(
      fun() ->
              case osiris:start_cluster(amqqueue:get_type_state(Q0)) of
                  {ok, #{leader_pid := Pid} = Conf} ->
                      Q = amqqueue:set_type_state(amqqueue:set_pid(Q0, Pid), Conf),
                      ra:pipeline_command({?MODULE, node()}, {start_cluster_reply, Q});
                  {error, {{already_started, _}, _}} ->
                      ra:pipeline_command({?MODULE, node()}, {start_cluster_finished, {error, already_started}})
              end
      end).

phase_delete_cluster(#{name := StreamId,
                       reference := QName} = Conf, ActingUser) ->
    spawn(
      fun() ->
              ok = osiris:delete_cluster(Conf),
              _ = rabbit_amqqueue:internal_delete(QName, ActingUser),
              ra:pipeline_command({?MODULE, node()}, {delete_cluster_reply, StreamId})
      end).

format_ra_event(ServerId, Evt) ->
    {stream_coordinator_event, ServerId, Evt}.

make_ra_conf(Node, Nodes) ->
    UId = ra:new_uid(ra_lib:to_binary(?MODULE)),
    Formatter = {?MODULE, format_ra_event, []},
    Members = [{?MODULE, N} || N <- Nodes],
    TickTimeout = application:get_env(rabbit, stream_tick_interval,
                                      ?TICK_TIMEOUT),
    #{cluster_name => ?MODULE,
      id => {?MODULE, Node},
      uid => UId,
      friendly_name => atom_to_list(?MODULE),
      metrics_key => ?MODULE,
      initial_members => Members,
      log_init_args => #{uid => UId},
      tick_timeout => TickTimeout,
      machine => {module, ?MODULE, #{}},
      ra_event_formatter => Formatter}.

emit_queue_deleted_events(Ref, Subs) ->
    [{send_msg, S, {queue_deleted, Ref}} || S <- Subs].

emit_leader_down_events(Ref, Pid, Subs) ->
    [{send_msg, S, {leader_down, Ref, Pid}} || S <- Subs].

emit_leader_up_events(Ref, Pid, Subs) ->
    [{send_msg, S, {leader_up, Ref, Pid}} || S <- Subs].

leader_event(#{reference := Ref, leader_pid := Pid}, Subscriber) ->
    case rabbit_misc:is_process_alive(Pid) of
        true ->
            {send_msg, Subscriber, {leader_up, Ref, Pid}};
        false ->
            {send_msg, Subscriber, {leader_down, Ref, Pid}}
    end.

maybe_update_subscribers(Subscriber, StreamId, Monitors) ->
    case Monitors of
        #{Subscriber := {Streams, subscriber}} ->
            maps:put(Subscriber, {[StreamId | Streams], subscriber}, Monitors);
        _ ->
            maps:put(Subscriber, {[StreamId], subscriber}, Monitors)
    end.

remove_subscriber(Pid, SubscribedTo, Streams) ->
    lists:foldl(
      fun(StreamId, Acc) ->
              case maps:get(StreamId, Acc, undefined) of
                  undefined ->
                      Acc;
                  #{subscribers := Subs} = SState0 ->
                      SState = SState0#{subscribers => lists:delete(Pid, Subs)},
                      Streams#{StreamId => SState}
              end
      end, Streams, SubscribedTo).

add_unique(Node, Nodes) ->
    case lists:member(Node, Nodes) of
        true ->
            Nodes;
        _ ->
            [Node | Nodes]
    end.

delete_replica_pid(Node, ReplicaPids) ->
    lists:filter(fun(P) -> node(P) =/= Node end, ReplicaPids).
