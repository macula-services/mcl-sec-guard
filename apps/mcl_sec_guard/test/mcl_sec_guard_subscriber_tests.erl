%%% @doc Tests for the subscriber's payload seam through its public
%%% path: handle_event/4 with a wire-form fact must end in a recorded
%%% proposal. Matching atom keys on the raw wire form (which the mesh
%%% delivers — map keys as {text, K} tuples) is what silently discarded
%%% every denials_observed fact live (mcl-sec-guard#2): the rule fell
%%% through to none and the recorder never ran.
-module(mcl_sec_guard_subscriber_tests).

-include_lib("eunit/include/eunit.hrl").

wire_form_fact_test_() ->
    log_fixture("/tmp/mcl_sec_guard_subscriber_wire_test.log",
                [fun a_wire_form_fact_is_recorded_as_a_proposal/0]).

quiet_wire_form_fact_test_() ->
    log_fixture("/tmp/mcl_sec_guard_subscriber_quiet_test.log",
                [fun a_quiet_wire_form_fact_records_nothing/0]).

log_fixture(Path, Tests) ->
    {setup, fun() -> setup(Path) end, fun teardown/1, fun(_Pid) -> Tests end}.

setup(Path) ->
    _ = file:delete(Path),
    kill_stale_recorder(),
    application:set_env(mcl_sec_guard, proposal_log, Path),
    {Pid, Keeper} = start_recorder(),
    {Pid, Keeper, Path}.

%% The recorder is NAMED, and the service tests' supervisor test starts
%% it without waiting for its shutdown — a race that made a later
%% start_link here return {error, already_started}: the keeper's match
%% failed, the setup's receive never fired, and eunit hung silently.
%% Kill any stale instance and wait for its DOWN first, so the start
%% below is deterministic. The keeper reports its outcome either way:
%% a start failure is an immediate, readable error, never a hang.
kill_stale_recorder() ->
    case whereis(mcl_sec_guard_recorder) of
        undefined -> ok;
        Old ->
            Ref = erlang:monitor(process, Old),
            exit(Old, shutdown),
            receive {'DOWN', Ref, process, Old, _} -> ok
            after 2000 -> exit(Old, kill),
                          receive {'DOWN', Ref, process, Old, _} -> ok
                          after 1000 -> ok
                          end
            end
    end.

teardown({Pid, Keeper, Path}) ->
    Keeper ! stop,
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end,
    application:unset_env(mcl_sec_guard, proposal_log),
    _ = file:delete(Path).

%% The recorder starts under a keeper, not the eunit setup process:
%% eunit exits its setup process once the fixture is built, and a
%% start_link'd child dies with it, mid-fixture.
start_recorder() ->
    Parent = self(),
    Keeper = spawn(fun() ->
                           Parent ! {recorder_started, self(),
                                     catch mcl_sec_guard_recorder:start_link()},
                           receive stop -> ok end
                   end),
    receive
        {recorder_started, Keeper, {ok, Pid}} -> {Pid, Keeper};
        {recorder_started, Keeper, Other} -> error({recorder_start_failed, Other})
    end.

%% The exact shape a subscriber receives for one mcl-om alert fact.
wire_fact(#{denied_rate := Rate, callers_over_limit := Over}) ->
    #{{text, <<"procedure">>} => <<"mcl-echo/echo">>,
      {text, <<"window_start_ms">>} => 1791148830000,
      {text, <<"denied_rate">>} => Rate,
      {text, <<"denied_size">>} => 0,
      {text, <<"callers_over_limit">>} => Over,
      {text, <<"global_count">>} => 0,
      {text, <<"global_max">>} => 300,
      {text, <<"per_caller_max">>} => 20}.

a_wire_form_fact_is_recorded_as_a_proposal() ->
    Wire = wire_fact(#{denied_rate => 7, callers_over_limit => 3}),
    {noreply, #{}} = mcl_sec_guard_subscriber:handle_event(
                        <<"denials_observed">>, Wire, #{}, #{}),
    {ok, Bin} = file:read_file("/tmp/mcl_sec_guard_subscriber_wire_test.log"),
    Lines = [Line || Line <- binary:split(Bin, <<"\n">>, [global]), Line =/= <<>>],
    ?assertEqual(1, length(Lines)),
    ?assertMatch(<<"#{", _/binary>>, hd(Lines)).

a_quiet_wire_form_fact_records_nothing() ->
    Quiet = wire_fact(#{denied_rate => 0, callers_over_limit => 0}),
    {noreply, #{}} = mcl_sec_guard_subscriber:handle_event(
                        <<"denials_observed">>, Quiet, #{}, #{}),
    {ok, Bin} = file:read_file("/tmp/mcl_sec_guard_subscriber_quiet_test.log"),
    Lines = [Line || Line <- binary:split(Bin, <<"\n">>, [global]), Line =/= <<>>],
    ?assertEqual([], Lines).
