%%% @doc The trainer run api (mcl-sec-guard#15): the three request
%%% shapes, the genome validation, the run set written through the
%%% reporter, and the one-run guardrail.
%%%
%%% Each test runs against its own temp `trainer_runs' directory (the
%%% app env the api reads), so the assertions stay about one run.
-module(mcl_sec_guard_trainer_api_tests).

-include_lib("eunit/include/eunit.hrl").

api_test_() ->
    [?_test(baseline_params_write_the_incumbent_run_set()),
     ?_test(a_named_baseline_run_is_the_same()),
     ?_test(genome_params_write_the_genome_named_run_set()),
     ?_test(a_wrong_length_genome_is_a_typed_error()),
     ?_test(a_non_number_genome_is_a_typed_error()),
     ?_test(an_unknown_shape_is_a_typed_error()),
     ?_test(a_second_run_in_flight_is_refused())].

baseline_params_write_the_incumbent_run_set() ->
    with_run_dir(
      fun(Dir) ->
              {ok, Meta} = mcl_sec_guard_trainer_api:run(#{}),
              ?assertEqual(<<"incumbent">>, maps:get(policy, Meta)),
              ?assertEqual(8, maps:get(reports, Meta)),
              [File] = runset_files(Dir),
              {ok, [{run_set, Props}]} = file:consult(filename:join(Dir, File)),
              Info = maps:from_list(Props),
              ?assertEqual(<<"incumbent">>, maps:get(policy, Info)),
              ?assertEqual(<<"console-run">>, maps:get(commit, Info)),
              ?assertEqual(8, length(maps:get(reports, Info)))
      end).

a_named_baseline_run_is_the_same() ->
    with_run_dir(
      fun(Dir) ->
              {ok, #{policy := <<"incumbent">>}} =
                  mcl_sec_guard_trainer_api:run(#{run => <<"baseline">>}),
              ?assertEqual(1, length(runset_files(Dir)))
      end).

genome_params_write_the_genome_named_run_set() ->
    with_run_dir(
      fun(Dir) ->
              Vector = lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 0.0),
              Name = mcl_sec_trainer_genome:policy_name(Vector),
              {ok, Meta} = mcl_sec_guard_trainer_api:run(#{genome => Vector}),
              ?assertEqual(Name, maps:get(policy, Meta)),
              ?assertEqual(8, maps:get(reports, Meta)),
              [File] = runset_files(Dir),
              ?assertNotEqual(nomatch, string:find(File, binary_to_list(Name))),
              {ok, [{run_set, Props}]} = file:consult(filename:join(Dir, File)),
              Info = maps:from_list(Props),
              ?assertEqual(Name, maps:get(policy, Info)),
              ?assertEqual(8, length(maps:get(reports, Info)))
      end).

a_wrong_length_genome_is_a_typed_error() ->
    with_run_dir(
      fun(Dir) ->
              Want = mcl_sec_trainer_policy_net:param_count(),
              ?assertEqual({error, {malformed_genome, {bad_length, 3, Want}}},
                           mcl_sec_guard_trainer_api:run(#{genome => [1, 2, 3]})),
              ?assertEqual([], runset_files(Dir))
      end).

a_non_number_genome_is_a_typed_error() ->
    Want = mcl_sec_trainer_policy_net:param_count(),
    Bad = [<<"x">> | lists:duplicate(Want - 1, 0.0)],
    ?assertEqual({error, {malformed_genome, {bad_element, <<"x">>}}},
                 mcl_sec_guard_trainer_api:run(#{genome => Bad})),
    ?assertEqual({error, {malformed_genome, not_a_list}},
                 mcl_sec_guard_trainer_api:run(#{genome => <<"nope">>})).

an_unknown_shape_is_a_typed_error() ->
    ?assertEqual({error, {malformed_params, #{run => <<"everything">>}}},
                 mcl_sec_guard_trainer_api:run(#{run => <<"everything">>})),
    ?assertMatch({error, {malformed_params, _}},
                 mcl_sec_guard_trainer_api:run(#{run => <<"baseline">>, extra => 1})).

a_second_run_in_flight_is_refused() ->
    with_run_dir(
      fun(Dir) ->
              ok = mcl_sec_guard_trainer_api:set_run_in_progress(true),
              try
                  ?assertEqual({error, run_in_progress},
                               mcl_sec_guard_trainer_api:run(#{}))
              after
                  ok = mcl_sec_guard_trainer_api:set_run_in_progress(false)
              end,
              ?assertEqual([], runset_files(Dir)),
              {ok, _Meta} = mcl_sec_guard_trainer_api:run(#{}),
              ?assertEqual(1, length(runset_files(Dir)))
      end).

%% Point the api at a fresh temp dir for the duration of one test.
with_run_dir(Test) ->
    Dir = tmp_dir(),
    Old = application:get_env(mcl_sec_guard, trainer_runs),
    application:set_env(mcl_sec_guard, trainer_runs, Dir),
    try Test(Dir)
    after
        case Old of
            undefined -> application:unset_env(mcl_sec_guard, trainer_runs);
            {ok, Value} -> application:set_env(mcl_sec_guard, trainer_runs, Value)
        end,
        _ = file:del_dir_r(Dir),
        ok
    end.

tmp_dir() ->
    Dir = filename:join("/tmp/opencode",
                        "trainer-api-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Dir.

runset_files(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    lists:reverse(lists:sort([F || F <- Files, lists:prefix("runset-", F)])).
