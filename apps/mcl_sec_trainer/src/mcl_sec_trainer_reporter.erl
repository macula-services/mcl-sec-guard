%%% @doc The run-set reporter: the trainer's output as a durable file
%%% (PLAN_TRAINER_CONSOLE.md, Phase A).
%%%
%%% A run set is one policy's reports across the scenario table (or one
%%% episode), plus its provenance — written as an Erlang-term file so
%%% the guardian's console can `file:consult/1` it back without any of
%%% the trainer's modules being present in the released image. THE FILE
%%% IS THE CONTRACT between the trainer (writer, on a dev box) and the
%%% console (reader, on the box): the shape below is the whole wire.
%%%
%%% One file per run set, named `runset-<wallclock ms>-<policy>.terms`,
%%% so a lexicographic listing is already newest-first (the faber
%%% runner discipline: a signed insight is always backed by a raw feed
%%% of numbers — this file is that feed, kept, never thrown away):
%%%
%%%     {run_set,
%%%      [{written_at_ms, 1730000000000},
%%%       {commit, <<"abc1234">>},
%%%       {policy, <<"incumbent">>},
%%%       {fitness_config, #{version := 1, ...}},
%%%       {reports, [Report, ...]}]}.
%%%
%%% Each report is the episode report as mcl_sec_trainer_episode:run/2
%%% returns it, enriched with the scenario's envelope (the console
%%% cannot reach mcl_sec_trainer_scenarios, so the artifact carries it).
%%% Kept runs are capped (default 20): the newest survive, the rest are
%%% removed — bounded disk, newest-first reads.
-module(mcl_sec_trainer_reporter).

-export([write_runset/2, write_runset/3, run_sets_dir/1]).

-define(CAP, 20).

%% @doc Where run sets live: `{mcl_sec_guard, trainer_runs}' app env,
%% default a relative `trainer_runs/' — the same convention the
%% recorder's `proposal_log' uses, so on the box both land in the
%% service's persistent working directory.
-spec run_sets_dir(atom()) -> file:name_all().
run_sets_dir(App) ->
    application:get_env(App, trainer_runs, "trainer_runs").

%% @doc Write one run set under Dir. Provenance is taken from the
%% environment (the image's REVISION build arg) and the active fitness
%% config; reports are enriched with their scenario's envelope.
-spec write_runset(file:name_all(), [map()]) -> ok | {error, term()}.
write_runset(Dir, Reports) ->
    write_runset(Dir, Reports, #{}).

%% Meta: `commit' overrides the REVISION env fallback; `policy' names
%% the run set (default: the first report's policy field).
-spec write_runset(file:name_all(), [map()], map()) -> ok | {error, term()}.
write_runset(Dir, Reports, Meta) when is_list(Reports), Reports =/= [] ->
    Policy = maps:get(policy, Meta, policy_of(hd(Reports))),
    RunSet = {run_set,
              [{written_at_ms, erlang:system_time(millisecond)},
               {commit, maps:get(commit, Meta, commit_env())},
               {policy, Policy},
               {fitness_config, mcl_sec_trainer_fitness:config()},
               {reports, [enrich(R) || R <- Reports]}]},
    Path = filename:join(Dir, runset_name(Policy)),
    case write(Path, RunSet) of
        ok -> prune(Dir), ok;
        {error, _} = Error -> Error
    end;
write_runset(_Dir, _EmptyOrBad, _Meta) ->
    {error, no_reports}.

write(Path, Term) ->
    ok = filelib:ensure_dir(filename:join(filename:dirname(Path), "x")),
    case file:write_file(Path, io_lib:format("~p.~n", [Term])) of
        ok -> ok;
        {error, _} = Error -> Error
    end.

runset_name(Policy) ->
    "runset-" ++ integer_to_list(erlang:system_time(millisecond))
        ++ "-" ++ filename_safe(Policy) ++ ".terms".

filename_safe(Policy) when is_binary(Policy) ->
    [C || C <- unicode:characters_to_list(Policy),
          (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z)
              orelse (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_];
filename_safe(Policy) ->
    io_lib:format("~p", [Policy]).

policy_of(#{policy := Policy}) when is_binary(Policy) -> Policy;
policy_of(#{policy := Policy}) when is_atom(Policy) -> atom_to_binary(Policy, utf8);
policy_of(_Report) -> unknown.

commit_env() ->
    case os:getenv("REVISION") of
        false -> <<"unknown">>;
        Commit -> unicode:characters_to_binary(Commit)
    end.

%% The console cannot reach the scenario table, so the artifact carries
%% the envelope each episode was evaluated against.
enrich(#{scenario := Scenario} = Report) ->
    Envelope = maps:get(envelope, mcl_sec_trainer_scenarios:limits(Scenario)),
    Report#{envelope => Envelope};
enrich(Report) ->
    Report.

%% Keep the newest ?CAP run sets; the name's timestamp makes a sorted
%% listing newest-first, so the survivors are a suffix.
prune(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            RunSets = lists:reverse(lists:sort([F || F <- Files, is_runset(F)])),
            Old = lists:sublist(RunSets, ?CAP + 1, length(RunSets)),
            delete_files(Dir, Old);
        {error, _Reason} ->
            ok
    end.

delete_files(_Dir, []) ->
    ok;
delete_files(Dir, [File | Rest]) ->
    _ = file:delete(filename:join(Dir, File)),
    delete_files(Dir, Rest).

is_runset(Name) ->
    lists:prefix("runset-", Name) andalso lists:suffix(".terms", Name).
