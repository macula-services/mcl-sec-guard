%%% @doc Tests for the append-only proposal recorder: one line per
%%% proposal, against a real file.
-module(mcl_sec_guard_recorder_tests).

-include_lib("eunit/include/eunit.hrl").

recorder_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_Pid) ->
        [fun a_proposal_appends_one_line/0]
    end}.

setup() ->
    Path = "/tmp/mcl_sec_guard_proposals_test.log",
    _ = file:delete(Path),
    application:set_env(mcl_sec_guard, proposal_log, Path),
    start_recorder().

teardown({Pid, Keeper}) ->
    Keeper ! stop,
    Ref = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Ref, process, Pid, _Reason} -> ok end,
    application:unset_env(mcl_sec_guard, proposal_log),
    _ = file:delete("/tmp/mcl_sec_guard_proposals_test.log").

%% The recorder starts under a keeper, not the eunit setup process:
%% eunit exits its setup process once the fixture is built, and a
%% start_link'd child dies with it, mid-fixture.
start_recorder() ->
    Parent = self(),
    Keeper = spawn(fun() ->
                           {ok, Pid} = mcl_sec_guard_recorder:start_link(),
                           Parent ! {recorder_started, self(), Pid},
                           receive stop -> ok end
                   end),
    receive {recorder_started, Keeper, Pid} -> {Pid, Keeper} end.

a_proposal_appends_one_line() ->
    Proposal = #{procedure => <<"mcl-echo/echo">>,
                 proposed => #{per_caller_max => 3},
                 reason => <<"test">>,
                 envelope => unknown,
                 decided_at_ms => 1},
    ok = mcl_sec_guard_recorder:record(Proposal),
    ok = mcl_sec_guard_recorder:record(Proposal),
    {ok, Bin} = file:read_file("/tmp/mcl_sec_guard_proposals_test.log"),
    Lines = [Line || Line <- binary:split(Bin, <<"\n">>, [global]), Line =/= <<>>],
    ?assertEqual(2, length(Lines)),
    ?assertMatch(<<"#{", _/binary>>, hd(Lines)).
