%%% @doc The run-set reporter: the file is the contract between the
%%% trainer and the console, so the tests lock its shape — what the
%%% console's reader (mcl_sec_guard_trainer_view) is written against.
-module(mcl_sec_trainer_reporter_tests).

-include_lib("eunit/include/eunit.hrl").

write_runset_round_trips_through_file_consult_test() ->
    Dir = tmp_dir(),
    Report = sample_report(),
    ok = mcl_sec_trainer_reporter:write_runset(Dir, [Report],
                                               #{policy => <<"incumbent">>}),
    [File] = runset_files(Dir),
    {ok, [{run_set, Props}]} = file:consult(filename:join(Dir, File)),
    Info = maps:from_list(Props),
    ?assertEqual(<<"incumbent">>, maps:get(policy, Info)),
    ?assertEqual(1, length(maps:get(reports, Info))),
    [Written] = maps:get(reports, Info),
    ?assertEqual(calm, maps:get(scenario, Written)),
    %% the console cannot reach the scenario table: the artifact carries
    %% the envelope the episode was evaluated against
    ?assertMatch(#{per_caller_max := _}, maps:get(envelope, Written)),
    ?assertMatch(#{version := 1}, maps:get(fitness_config, Info)),
    ?assert(is_integer(maps:get(written_at_ms, Info))),
    cleanup(Dir).

newest_survive_the_cap_test() ->
    Dir = tmp_dir(),
    Report = sample_report(),
    lists:foreach(
      fun(N) ->
              ok = mcl_sec_trainer_reporter:write_runset(
                     Dir, [Report], #{policy => integer_to_binary(N)})
      end, lists:seq(1, 25)),
    Files = runset_files(Dir),
    ?assertEqual(20, length(Files)),
    Names = [filename:basename(F) || F <- Files],
    %% the naming sorts newest-first, so the survivors are the newest 20
    ?assertEqual(Names, lists:reverse(lists:sort(Names))),
    cleanup(Dir).

an_empty_run_set_is_refused_test() ->
    Dir = tmp_dir(),
    ?assertEqual({error, no_reports}, mcl_sec_trainer_reporter:write_runset(Dir, [])),
    cleanup(Dir).

run_set_files_are_recognized_by_name_test() ->
    %% the console's reader and the reporter agree on which files are
    %% run sets: the reporter's naming convention is the reader's filter
    Dir = tmp_dir(),
    ok = mcl_sec_trainer_reporter:write_runset(Dir, [sample_report()],
                                               #{policy => <<"p">>}),
    [File] = runset_files(Dir),
    ?assert(lists:prefix("runset-", filename:basename(File))),
    ?assert(lists:suffix(".terms", filename:basename(File))),
    cleanup(Dir).

sample_report() ->
    mcl_sec_trainer_episode:run(calm, #{policy => fun(_Ctx) -> none end,
                                        policy_name => incumbent}).

tmp_dir() ->
    Dir = filename:join("/tmp/opencode",
                        "reporter-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Dir.

runset_files(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    lists:reverse(lists:sort([F || F <- Files,
                                  lists:prefix("runset-", F)])).

cleanup(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    [file:delete(filename:join(Dir, F)) || F <- Files],
    file:del_dir(Dir),
    ok.
