%%% @doc The scoreboard's pure half: reads run-set artifacts (the file
%%% contract mcl_sec_trainer_reporter writes) and renders pages from
%%% them — tolerant of empty dirs and broken files, never fatal.
-module(mcl_sec_guard_trainer_view_tests).

-include_lib("eunit/include/eunit.hrl").

an_empty_dir_renders_the_how_to_test() ->
    Dir = tmp_dir(),
    Page = iolist_to_binary(mcl_sec_guard_trainer_view:scoreboard(
                              mcl_sec_guard_trainer_view:read_run_sets(Dir))),
    ?assert(string:find(Page, "No run sets yet") =/= nomatch),
    ?assert(string:find(Page, "write_runset") =/= nomatch),
    cleanup(Dir).

a_run_set_renders_the_score_table_test() ->
    Dir = tmp_dir(),
    ok = write_baseline(Dir),
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(Dir),
    Page = iolist_to_binary(mcl_sec_guard_trainer_view:scoreboard(RunSets)),
    ?assert(string:find(Page, "latest run set") =/= nomatch),
    ?assert(string:find(Page, "incumbent") =/= nomatch),
    ?assert(string:find(Page, "calm") =/= nomatch),
    ?assert(string:find(Page, "fitness vector v1") =/= nomatch),
    ?assert(string:find(Page, "conformance") =/= nomatch),
    cleanup(Dir).

the_episode_page_drills_into_one_scenario_test() ->
    Dir = tmp_dir(),
    ok = write_baseline(Dir),
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(Dir),
    Page = iolist_to_binary(
             mcl_sec_guard_trainer_view:episode_page(RunSets, <<"calm">>)),
    ?assert(string:find(Page, "episode: calm") =/= nomatch),
    ?assert(string:find(Page, "final limits vs envelope") =/= nomatch),
    Missing = iolist_to_binary(
                mcl_sec_guard_trainer_view:episode_page(RunSets, <<"nope">>)),
    ?assert(string:find(Missing, "no episode named nope") =/= nomatch),
    cleanup(Dir).

a_candidate_run_set_renders_the_diff_against_the_incumbent_test() ->
    Dir = tmp_dir(),
    ok = write_baseline(Dir),
    timer:sleep(2),
    ok = write_candidate(Dir),
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(Dir),
    Page = iolist_to_binary(mcl_sec_guard_trainer_view:scoreboard(RunSets)),
    ?assert(string:find(Page, "candidate vs incumbent") =/= nomatch),
    ?assert(string:find(Page, "held-out seed sweep") =/= nomatch),
    cleanup(Dir).

the_raw_feed_is_json_shaped_per_episode_test() ->
    Dir = tmp_dir(),
    ok = write_baseline(Dir),
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(Dir),
    Lines = mcl_sec_guard_trainer_view:ndjson(RunSets),
    ?assertEqual(8, length(Lines)),
    [First | _] = Lines,
    ?assertMatch(#{<<"scenario">> := <<"calm">>,
                   <<"runset_policy">> := <<"incumbent">>,
                   <<"vector">> := #{<<"containment">> := _}}, First),
    cleanup(Dir).

a_broken_file_is_skipped_test() ->
    Dir = tmp_dir(),
    ok = write_baseline(Dir),
    ok = file:write_file(filename:join(Dir, "runset-999999-broken.terms"),
                         <<"this is not a term.\n">>),
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(Dir),
    ?assertEqual(1, length(RunSets)),
    cleanup(Dir).

write_baseline(Dir) ->
    Reports = [mcl_sec_trainer_episode:run(
                 Name, #{policy => fun(_Ctx) -> none end, policy_name => incumbent})
               || Name <- mcl_sec_trainer_scenarios:names()],
    mcl_sec_trainer_reporter:write_runset(Dir, Reports, #{policy => <<"incumbent">>}).

write_candidate(Dir) ->
    Reports = [mcl_sec_trainer_episode:run(
                 Name, #{policy => fun(_Ctx) -> none end, policy_name => candidate})
               || Name <- mcl_sec_trainer_scenarios:names()],
    mcl_sec_trainer_reporter:write_runset(Dir, Reports, #{policy => <<"candidate">>}).

tmp_dir() ->
    Dir = filename:join("/tmp/opencode",
                        "view-" ++ integer_to_list(erlang:unique_integer([positive]))),
    file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Dir.

cleanup(Dir) ->
    {ok, Files} = file:list_dir(Dir),
    [file:delete(filename:join(Dir, F)) || F <- Files],
    file:del_dir(Dir),
    ok.
