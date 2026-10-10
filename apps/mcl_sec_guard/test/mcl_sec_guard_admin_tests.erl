%%% @doc Tests for the admin console's pure pieces: the default port,
%%% the bind posture, the proposal page rendering, and the
%%% POST /api/trainer/run decision (#15).
-module(mcl_sec_guard_admin_tests).

-include_lib("eunit/include/eunit.hrl").

admin_test_() ->
    [fun the_admin_binds_every_interface_by_default/0,
     fun the_page_renders_the_proposal_lines/0].

trainer_run_wire_test_() ->
    {setup, fun trainer_dir/0, fun cleanup/1,
     fun(Ctx) ->
         [?_test(the_run_endpoint_answers_a_flash_303(Ctx)),
          ?_test(a_bad_genome_body_gets_400_naming_it(Ctx)),
          ?_test(a_malformed_json_body_gets_400(Ctx)),
          ?_test(a_run_in_flight_gets_409(Ctx))]
     end}.

the_admin_binds_every_interface_by_default() ->
    ?assertEqual(8458, mcl_sec_guard_admin:port()),
    ?assertEqual([{port, 8458}, {ip, {0, 0, 0, 0}}],
                 mcl_sec_guard_admin:socket_opts()),
    [{'_', _Constraints, Routes}] = mcl_sec_guard_admin_handler:routes(),
    Segments = lists:sort([[S || S <- Segs] || {Segs, _C, _H, _O} <- Routes]),
    ?assertEqual(lists:sort([[], [<<"proposals.ndjson">>], [<<"trainer">>],
                             [<<"trainer.ndjson">>], [<<"trainer">>, <<"episode">>],
                             [<<"api">>, <<"trainer">>, <<"run">>]]),
                 Segments).

the_page_renders_the_proposal_lines() ->
    Page = mcl_sec_guard_admin_handler:page(<<"#{a => 1}.\n#{b => 2}.\n">>),
    ?assert(is_list(Page)),
    ?assert(string:find(Page, "2 proposals.") =/= nomatch),
    ?assert(string:find(Page, "#{a => 1}.") =/= nomatch),
    ?assert(string:find(Page, "#{b => 2}.") =/= nomatch).

%% the wire tests: the endpoint decision, with the run sets landing in a
%% temp dir (no test writes into the checkout's trainer_runs/)

the_run_endpoint_answers_a_flash_303({Dir, _Old}) ->
    {Status, Headers, Body} = mcl_sec_guard_admin_handler:trainer_run_response(<<>>),
    ?assertEqual(303, Status),
    ?assertEqual(<<"/trainer">>, maps:get(<<"location">>, Headers)),
    ?assertEqual(<<>>, Body),
    ?assertEqual(1, length(runset_files(Dir))).

a_bad_genome_body_gets_400_naming_it(_Setup) ->
    {Status, _Headers, Body} =
        mcl_sec_guard_admin_handler:trainer_run_response(<<"{\"genome\":[1,2,3]}">>),
    ?assertEqual(400, Status),
    ?assert(string:find(binary_to_list(Body), "malformed genome") =/= nomatch).

a_malformed_json_body_gets_400(_Setup) ->
    {Status, _Headers, Body} =
        mcl_sec_guard_admin_handler:trainer_run_response(<<"{nope">>),
    ?assertEqual(400, Status),
    ?assert(string:find(binary_to_list(Body), "malformed JSON") =/= nomatch).

a_run_in_flight_gets_409(_Setup) ->
    ok = mcl_sec_guard_trainer_api:set_run_in_progress(true),
    try
        {Status, _Headers, Body} = mcl_sec_guard_admin_handler:trainer_run_response(<<>>),
        ?assertEqual(409, Status),
        ?assert(string:find(binary_to_list(Body), "in progress") =/= nomatch)
    after
        ok = mcl_sec_guard_trainer_api:set_run_in_progress(false)
    end.

trainer_dir() ->
    Dir = filename:join("/tmp/opencode",
                        "admin-wire-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Old = application:get_env(mcl_sec_guard, trainer_runs),
    application:set_env(mcl_sec_guard, trainer_runs, Dir),
    {Dir, Old}.

cleanup({Dir, Old}) ->
    case Old of
        undefined -> application:unset_env(mcl_sec_guard, trainer_runs);
        {ok, Value} -> application:set_env(mcl_sec_guard, trainer_runs, Value)
    end,
    _ = file:del_dir_r(Dir),
    ok.

runset_files(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    [F || F <- Files, lists:prefix("runset-", F)].
