%%% @doc The trainer scoreboard's pure half: reads run-set artifacts and
%%% renders them (the trainer console, mcl-sec-guard#21, phase A).
%%%
%%% The reader side of the reporter's file contract. The trainer's
%%% modules are deliberately NOT in the released image (Phase B's
%%% decision), so this module knows nothing about them — it consults
%%% the term files `mcl_sec_trainer_reporter` writes and renders what
%%% it finds, tolerating anything unreadable. It imports no cowboy and
%%% no codec; the handler owns the wire and the JSON encoding.
-module(mcl_sec_guard_trainer_view).

-export([read_run_sets/1, scoreboard/1, episode_page/2, ndjson/1]).

-define(BASELINE_POLICY, <<"incumbent">>).

%% @doc Every run set under Dir, newest first: `[{File, Info}]`, where
%% Info is the parsed `{run_set, Props}`. Unreadable files are counted
%% and skipped, never fatal — a broken artifact must not break the
%% page.
-spec read_run_sets(file:name_all()) -> [{file:name_all(), map()}].
read_run_sets(Dir) ->
    {Parsed, _Broken} =
        lists:foldl(fun(File, Acc) -> collect(File, Dir, Acc) end,
                    {[], 0}, sorted_run_files(Dir)),
    lists:reverse(Parsed).

collect(File, Dir, {Acc, Broken}) ->
    case read_one(filename:join(Dir, File)) of
        {ok, Info} -> {[{File, Info} | Acc], Broken};
        broken -> {Acc, Broken + 1}
    end.

sorted_run_files(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:reverse(lists:sort([F || F <- Files, is_runset(F)]));
        {error, _Reason} ->
            []
    end.

is_runset(Name) ->
    lists:prefix("runset-", Name) andalso lists:suffix(".terms", Name).

read_one(Path) ->
    case file:consult(Path) of
        {ok, [{run_set, Props}]} -> {ok, maps:from_list(Props)};
        _UnreadableOrWrongShape -> broken
    end.

%% @doc The scoreboard page body.
-spec scoreboard([{file:name_all(), map()}]) -> iolist().
scoreboard(RunSets) ->
    [<<"<h1>mcl-sec-guard - trainer scoreboard</h1>\n">>,
     case RunSets of
         [] -> no_run_sets();
         [{_File, Latest} | _Rest] ->
             [latest_header(Latest),
              score_table(Latest),
              fitness_block(Latest),
              diff_table(RunSets),
              <<"<p><a href=\"/trainer.ndjson\">raw feed (ndjson)</a></p>\n">>]
     end,
     conformance_note(RunSets)].

no_run_sets() ->
    [<<"<p>No run sets yet. Produce one from the repo (a dev box):</p>\n">>,
     <<"<pre>erl -noshell -pa _build/test/lib/mcl_sec_trainer/ebin "
       "-pa _build/test/lib/mcl_sec_guard/ebin -pa _build/test/lib/mcl_om/ebin "
       "-pa _build/test/lib/macula/ebin -eval "
       "'mcl_sec_trainer_reporter:write_runset(\"trainer_runs\", "
       "mcl_sec_trainer_baseline:run()), halt().'</pre>\n">>].

latest_header(Info) ->
    [<<"<p><strong>latest run set:</strong> ">>,
     policy(Info), <<" - written ">>,
     iolist_to_binary(calendar:system_time_to_rfc3339(
                        written_at(Info), [{unit, millisecond}])),
     <<" - commit ">>, commit(Info),
     <<" - fitness v">>, integer_to_binary(fitness_version(Info)), <<"</p>\n">>].

score_table(Info) ->
    Reports = maps:get(reports, Info),
    Rows = [score_row(R) || R <- Reports],
    [<<"<table border=\"1\" cellpadding=\"4\">\n"
       "<tr><th>scenario</th><th>fitness</th><th>C</th><th>A</th>"
       "<th>R</th><th>S</th><th>applies</th><th>churn</th><th>gates</th>"
       "<th></th></tr>\n">>,
     Rows, <<"</table>\n">>].

score_row(Report) ->
    #{scenario := Scenario, vector := Vector, fitness := Fitness,
      gates := Gates, measurements := Measurements} = Report,
    [<<"<tr><td><a href=\"/trainer/episode?scenario=">>,
     atom_to_binary(Scenario, utf8), <<"\">">>,
     atom_to_binary(Scenario, utf8), <<"</a></td><td>">>,
     fitness_cell(Fitness), <<"</td><td>">>,
     num(maps:get(containment, Vector)), <<"</td><td>">>,
     num(maps:get(admission, Vector)), <<"</td><td>">>,
     num(maps:get(recovery, Vector)), <<"</td><td>">>,
     num(maps:get(stability, Vector)), <<"</td><td>">>,
     integer_to_binary(maps:get(applies, Measurements)), <<"</td><td>">>,
     num(maps:get(churn, Measurements)), <<"</td><td>">>,
     gate_cells(Gates), <<"</td><td>ok</td></tr>\n">>].

fitness_cell(rejected) -> <<"rejected">>;
fitness_cell(F) -> num(F).

gate_cells(Gates) ->
    [gate_cell(Key, maps:get(Key, Gates))
     || Key <- [envelope, starvation, health, runaway]].

gate_cell(_Key, ok) -> <<"-">>;
gate_cell(Key, {fail, _Details}) ->
    [<<"<strong>">>, atom_to_binary(Key, utf8), <<"</strong>">>].

fitness_block(Info) ->
    Config = maps:get(fitness_config, Info, #{}),
    [<<"<h2>fitness vector v">>, integer_to_binary(maps:get(version, Config, 0)),
     <<"</h2>\n<pre>">>,
     io_lib:format("weights    ~p~nbudgets    ~p~nthresholds ~p~n",
                   [maps:get(weights, Config, #{}),
                    maps:get(budgets, Config, #{}),
                    maps:get(thresholds, Config, #{})]),
     <<"</pre>\n">>].

%% A candidate vs the incumbent: the promotion view, rendered whenever
%% the newest run set is not the baseline and a baseline run set exists.
diff_table([{_File, Latest} | Rest]) ->
    case policy(Latest) of
        ?BASELINE_POLICY -> [];
        _Candidate -> diff_for_policy(Latest, Rest)
    end.

diff_for_policy(Latest, Rest) ->
    case find_baseline(Rest) of
        undefined -> [];
        Baseline -> diff_rows(Latest, Baseline)
    end.

find_baseline([]) -> undefined;
find_baseline([{_File, Info} | Rest]) ->
    case policy(Info) of
        ?BASELINE_POLICY -> Info;
        _Other -> find_baseline(Rest)
    end.

diff_rows(Candidate, Baseline) ->
    CandReports = by_scenario(maps:get(reports, Candidate)),
    BaseReports = by_scenario(maps:get(reports, Baseline)),
    Rows = [diff_row(Name, maps:get(Name, CandReports, undefined),
                     maps:get(Name, BaseReports, undefined))
            || Name <- maps:keys(BaseReports)],
    [<<"<h2>candidate vs incumbent</h2>\n">>,
     <<"<table border=\"1\" cellpadding=\"4\">\n"
       "<tr><th>scenario</th><th>candidate fitness</th><th>incumbent</th>"
       "<th>d C</th><th>d A</th><th>d churn</th><th>d recovery</th>"
       "<th>gates</th></tr>\n">>,
     Rows,
     <<"</table>\n<p>Promotion gate (offline -> shadow) also needs the "
       "held-out seed sweep (N >= 200 episodes) - one run set alone is "
       "not the gate, it is the standing.</p>\n">>].

diff_row(Name, undefined, _Base) ->
    [<<"<tr><td>">>, Name, <<"</td><td colspan=\"7\">not run</td></tr>\n">>];
diff_row(Name, Candidate, Baseline) ->
    Cand = maps:get(vector, Candidate),
    Base = maps:get(vector, Baseline),
    CandM = maps:get(measurements, Candidate),
    BaseM = maps:get(measurements, Baseline),
    [<<"<tr><td>">>, Name, <<"</td><td>">>,
     fitness_cell(maps:get(fitness, Candidate)), <<"</td><td>">>,
     fitness_cell(maps:get(fitness, Baseline)), <<"</td><td>">>,
     delta(maps:get(containment, Cand), maps:get(containment, Base)),
     <<"</td><td>">>,
     delta(maps:get(admission, Cand), maps:get(admission, Base)),
     <<"</td><td>">>,
     delta(maps:get(churn, CandM), maps:get(churn, BaseM)),
     <<"</td><td>">>,
     delta(maps:get(recovery, Cand), maps:get(recovery, Base)),
     <<"</td><td>">>, gate_cells(maps:get(gates, Candidate)),
     <<"</td></tr>\n">>].

by_scenario(Reports) ->
    maps:from_list([{atom_to_binary(maps:get(scenario, R), utf8), R}
                    || R <- Reports]).

delta(Candidate, Baseline) ->
    Diff = Candidate - Baseline,
    [io_lib:format("~.3f", [Diff])].

num(N) when is_float(N) -> io_lib:format("~.3f", [N]);
num(I) when is_integer(I) -> integer_to_binary(I).

conformance_note(RunSets) ->
    Commit = case RunSets of
                 [] -> <<"unknown">>;
                 [{_File, Latest} | _] -> commit(Latest)
             end,
    [<<"<p>conformance: the sim is held to the real guard by "
       "test/mcl_sec_trainer_conformance_tests, run in CI for commit ">>,
     Commit, <<" (the repo's lint-and-test workflow).</p>\n">>].

%% @doc One episode's drill-down.
-spec episode_page([{file:name_all(), map()}], binary()) -> iolist().
episode_page([{_File, Latest} | _Rest], Scenario) ->
    case find_episode(maps:get(reports, Latest), Scenario) of
        undefined ->
            [<<"<p>no episode named ">>, Scenario, <<" in the latest run set.</p>\n">>,
             <<"<p><a href=\"/trainer\">back to the scoreboard</a></p>\n">>];
        Report ->
            episode_body(Report)
    end;
episode_page([], _Scenario) ->
    no_run_sets().

episode_body(Report) ->
    #{scenario := Scenario, windows := Windows, seed := Seed,
      measurements := M, vector := V, gates := G, fitness := Fitness,
      envelope := Envelope} = Report,
    Final = maps:get(final_limits, M),
    [<<"<h1>episode: ">>, atom_to_binary(Scenario, utf8), <<"</h1>\n">>,
     <<"<p>windows ">>, integer_to_binary(Windows),
     <<", seed ">>, integer_to_binary(Seed),
     <<", fitness ">>, fitness_cell(Fitness), <<"</p>\n">>,
     <<"<h2>vector</h2>\n<pre>">>,
     io_lib:format("containment ~.3f~nadmission   ~.3f~nrecovery    ~.3f~nstability   ~.3f~n",
                   [maps:get(containment, V), maps:get(admission, V),
                    maps:get(recovery, V), maps:get(stability, V)]),
     <<"</pre>\n<h2>gates</h2>\n<pre>">>,
     io_lib:format("~p~n", [G]),
     <<"</pre>\n<h2>measurements</h2>\n<pre>">>,
     io_lib:format("~p~n", [maps:remove(final_limits, M)]),
     <<"</pre>\n<h2>final limits vs envelope</h2>\n<pre>">>,
     io_lib:format("limits   ~p~nenvelope ~p~n", [Final, Envelope]),
     <<"</pre>\n<p><a href=\"/trainer\">back to the scoreboard</a></p>\n">>].

find_episode(Reports, Scenario) ->
    case [R || R <- Reports, atom_to_binary(maps:get(scenario, R), utf8) =:= Scenario] of
        [Report | _] -> Report;
        [] -> undefined
    end.

%% @doc The raw feed: one JSON-ready map per episode, newest run set
%% first. The handler encodes with jsx; this module only shapes data.
-spec ndjson([{file:name_all(), map()}]) -> [map()].
ndjson(RunSets) ->
    lists:append([run_set_lines(Info) || {_File, Info} <- RunSets]).

run_set_lines(Info) ->
    [maps:merge(json_map(Report),
                #{<<"runset_commit">> => commit(Info),
                  <<"runset_written_at_ms">> => written_at(Info),
                  <<"runset_policy">> => policy(Info)})
     || Report <- maps:get(reports, Info)].

json_map(Map) ->
    maps:from_list([{json_key(K), json_value(V)} || {K, V} <- maps:to_list(Map)]).

json_key(K) when is_atom(K) -> atom_to_binary(K, utf8);
json_key(K) when is_binary(K) -> K;
json_key(K) -> io_lib:format("~p", [K]).

json_value(V) when is_map(V) -> json_map(V);
json_value(V) when is_list(V) -> [json_value(E) || E <- V];
json_value({fail, Details}) -> #{<<"status">> => <<"fail">>, <<"details">> => json_value(Details)};
json_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
json_value(V) when is_binary(V) -> V;
json_value(V) when is_number(V) -> V.

policy(Info) ->
    case maps:get(policy, Info, <<"unknown">>) of
        P when is_binary(P) -> P;
        P when is_atom(P) -> atom_to_binary(P, utf8);
        _Other -> <<"unknown">>
    end.
commit(Info) -> maps:get(commit, Info, <<"unknown">>).
written_at(Info) -> maps:get(written_at_ms, Info, 0).
fitness_version(Info) ->
    maps:get(version, maps:get(fitness_config, Info, #{}), 0).
