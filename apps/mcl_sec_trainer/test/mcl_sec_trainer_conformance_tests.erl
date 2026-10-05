%%% @doc The conformance test: identical synthetic traffic replayed
%%% through the REAL mcl_om_guard (short windows, one pool) and through
%%% mcl_sec_trainer_sim must yield identical verdicts, counters, stats
%%% and audit entries — the faber convention of a pure reference held
%%% to the real path by test.
%%%
%%% The real guard keys its windows by wall clock, so each script
%%% window is replayed inside one real window: the test waits for the
%%% window to roll, applies that window's moves through the real
%%% set_limits capability (mcl_om_guard_control), replays the calls
%%% through the real stages in the real pipeline's order (size first,
%%% then rate, denial counting included), and reads the real stats.
%%% The sim runs the same script against its own window indices. The
%%% only fields not compared are the window keys themselves — wall-clock
%%% milliseconds on one side, an index on the other — and the order of
%%% equally-heavy callers in `top_callers', which neither implementation
%%% specifies.
-module(mcl_sec_trainer_conformance_tests).

-include_lib("eunit/include/eunit.hrl").

-define(WINDOW_MS, 50).

mixed_traffic_replays_identically_test() ->
    ensure_guard(),
    Proc = proc(<<"mixed">>),
    {Script, Moves} = script(),
    Real = real_replay(Proc, Script, Moves),
    Sim = sim_replay(Proc, Script, Moves),
    ?assertEqual(Sim, Real).

%% ---- the replay script ----

%% Five windows: plain counting; a size denial; an over-limit caller; a
%% distinct-caller flood (with the global bucket); and a no-op set next
%% to an out-of-envelope refusal.
script() ->
    Calls = [[{<<"a">>, small()}, {<<"a">>, small()}, {<<"b">>, small()}],
             [{<<"a">>, big()}, {<<"a">>, small()}, {<<"b">>, small()}],
             lists:duplicate(11, {<<"a">>, small()}) ++ [{<<"b">>, small()}],
             [{'$global', small()}, {<<"d1">>, small()}, {<<"d2">>, small()},
              {<<"d3">>, small()}, {<<"d4">>, small()}, {<<"d1">>, small()}],
             [{<<"a">>, small()}]],
    Moves = [[],
             [],
             [#{per_caller_max => 5}],
             [#{per_caller_max => 3}],
             [#{per_caller_max => 3}, #{per_caller_max => 30}]],
    {Calls, Moves}.

cap_limits() ->
    #{max_payload_external_size => 4096,
      window_ms                 => ?WINDOW_MS,
      per_caller_max            => 10,
      global_max                => 100,
      max_distinct_callers      => 4,
      envelope => #{per_caller_max => #{min => 1, max => 10},
                    global_max => #{min => 10, max => 100},
                    max_payload_external_size => #{min => 1024, max => 65536},
                    max_distinct_callers => #{min => 1, max => 4}}}.

%% ---- the real side ----

real_replay(Proc, Script, Moves) ->
    ok = mcl_om_guard_limits:declare(Proc, cap_limits()),
    wait_for_roll(Proc),
    replay_real(Proc, Script, Moves, []).

replay_real(_Proc, [], [], Acc) ->
    lists:reverse(Acc);
replay_real(Proc, [Calls | Rest], [Moves | MovesRest], Acc) ->
    MoveResults = [real_move(Proc, Move) || Move <- Moves],
    Verdicts = [real_call(Proc, Caller, Payload) || {Caller, Payload} <- Calls],
    Stats = normalize(mcl_om_guard:stats(Proc)),
    Entry = #{moves => MoveResults, verdicts => Verdicts, stats => Stats},
    wait_for_roll(Proc),
    replay_real(Proc, Rest, MovesRest, [Entry | Acc]).

%% The set_limits capability path, exactly: apply at the guardian tier,
%% record the change when it moved something. The success payload is the
%% new pair — already visible in the stats — so both sides reduce to
%% `ok' or the identical error tuple.
real_move(_Proc, none) ->
    ok;
real_move(Proc, Overrides) ->
    case mcl_om_guard_control:set_limits(#{procedure => Proc, limits => Overrides,
                                           caller => <<"guardian">>}) of
        {ok, _After} -> ok;
        {error, _} = Error -> Error
    end.

%% The pipeline's stage order and denial counting, exactly: size first,
%% then rate; a size refusal is counted by the pipeline, a rate refusal
%% inside mcl_om_guard:allow/3.
real_call(Proc, Caller, Payload) ->
    #{limits := Limits} = mcl_om_guard_limits:get(Proc),
    case mcl_om_guard_size:check(Payload, #{limits => Limits}) of
        pass ->
            case mcl_om_guard:allow(Proc, Caller, Limits) of
                allow -> allow;
                deny -> {deny, rate_limited}
            end;
        {deny, payload_too_large} ->
            mcl_om_guard:count_denial(Proc, size),
            {deny, payload_too_large}
    end.

%% ---- the sim side ----

sim_replay(Proc, Script, Moves) ->
    W0 = mcl_sec_trainer_sim:declare(mcl_sec_trainer_sim:new(), Proc, cap_limits()),
    replay_sim(W0, Proc, Script, Moves, []).

replay_sim(_World, _Proc, [], [], Acc) ->
    lists:reverse(Acc);
replay_sim(World, Proc, [Calls | Rest], [Moves | MovesRest], Acc) ->
    {World1, MoveResults} = sim_moves(World, Proc, Moves, []),
    {Verdicts, World2} =
        lists:foldl(
          fun({Caller, Payload}, {Vs, W}) ->
                  {V, W1} = mcl_sec_trainer_sim:call(W, Proc, Caller, Payload),
                  {[V | Vs], W1}
          end, {[], World1}, Calls),
    Stats = normalize(mcl_sec_trainer_sim:stats(World2, Proc)),
    Entry = #{moves => MoveResults, verdicts => lists:reverse(Verdicts), stats => Stats},
    World3 = mcl_sec_trainer_sim:advance(World2, Proc),
    replay_sim(World3, Proc, Rest, MovesRest, [Entry | Acc]).

sim_moves(World, _Proc, [], Acc) ->
    {World, lists:reverse(Acc)};
sim_moves(World, Proc, [none | Rest], Acc) ->
    sim_moves(World, Proc, Rest, [ok | Acc]);
sim_moves(World, Proc, [Overrides | Rest], Acc) ->
    case mcl_sec_trainer_sim:apply(World, Proc, Overrides,
                                   #{tier => guardian, caller => <<"guardian">>}) of
        {ok, W1} -> sim_moves(W1, Proc, Rest, [ok | Acc]);
        {error, Reason} -> sim_moves(World, Proc, Rest, [{error, Reason} | Acc])
    end.

%% ---- shared plumbing ----

%% The window keys differ by design (wall clock vs index), and the
%% order of equally-heavy callers is unspecified in both
%% implementations: compare everything else, and sort top_callers.
normalize(Stats) ->
    Top = lists:sort(fun(#{count := C1, caller := K1}, #{count := C2, caller := K2}) ->
                             {C1, K1} >= {C2, K2}
                     end, maps:get(top_callers, Stats)),
    maps:remove(current_window, Stats#{top_callers => Top}).

small() ->
    binary:copy(<<0>>, 256).

big() ->
    binary:copy(<<1>>, 8192).

proc(Tag) ->
    <<"conf/", Tag/binary, "-",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

%% The real guard is a registered gen_server; one instance serves every
%% test in the VM. A linked start would die with its starting test
%% process, so a detached holder process owns the link. Its alert timer
%% is pushed an hour out — this VM has no mesh, and the timer must
%% never fire mid-replay.
ensure_guard() ->
    case whereis(mcl_om_guard) of
        undefined ->
            application:set_env(mcl_om, inbound_guard, #{alert_tick_ms => 3600000}),
            Holder = spawn(fun() ->
                                   {ok, _Pid} = mcl_om_guard:start_link(),
                                   receive stop -> ok end
                           end),
            wait_until(fun() -> whereis(mcl_om_guard) =/= undefined end),
            unlink(Holder),
            ok;
        _Pid ->
            ok
    end.

wait_for_roll(Proc) ->
    Start = window_start(Proc),
    wait_until(fun() -> window_start(Proc) =/= Start end).

window_start(Proc) ->
    maps:get(current_window, mcl_om_guard:stats(Proc)).

wait_until(Pred) ->
    wait_until(Pred, 1000).

wait_until(Pred, Retries) when Retries > 0 ->
    case Pred() of
        true -> ok;
        false ->
            timer:sleep(2),
            wait_until(Pred, Retries - 1)
    end;
wait_until(_Pred, 0) ->
    error(waited_too_long).
