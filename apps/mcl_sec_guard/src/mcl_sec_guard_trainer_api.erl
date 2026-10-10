%%% @doc The trainer run api: the pure half of `POST /api/trainer/run'
%%% (mcl-sec-guard#15, phase B).
%%%
%%% The facade (`mcl_sec_guard_admin_handler') owns the wire; this
%%% module owns the request shape. Three shapes, one entry point:
%%%
%%%   - `#{}' or `#{run => <<"baseline">>}' runs the incumbent's eight
%%%     scenarios at default length and seed
%%%     (`mcl_sec_trainer_baseline:run/0') and names the run set
%%%     `incumbent';
%%%   - `#{genome => [Number]}' validates the vector against
%%%     `mcl_sec_trainer_policy_net:param_count()', evaluates its eight
%%%     scenarios (T=60, seed 0) and names the run set
%%%     `genome-<id>' (`mcl_sec_trainer_genome:policy_name/1');
%%%   - anything else is a typed error the facade turns into a 400.
%%%
%%% Every run set goes through `mcl_sec_trainer_reporter' into the same
%%% `trainer_runs/' directory the console's scoreboard reads: the file
%%% contract is the whole bridge between this service and the trainer
%%% modules (mcl-sec-guard#21, phase A). The console stays an audit
%%% window — a run is an evaluation, nothing is applied.
%%%
%%% One run at a time. Runs are ~1 s and synchronous; a flag around the
%%% run refuses a second concurrent call with `run_in_progress' (the
%%% facade maps that to a 409). A guardrail, not a queue: queues are
%%% phase C.
-module(mcl_sec_guard_trainer_api).

-export([run/1, run_in_progress/0, set_run_in_progress/1]).

-define(FLAG, {?MODULE, run_in_progress}).

-spec run(map()) -> {ok, map()} | {error, term()}.
run(Params) when is_map(Params) ->
    claimed(claim(), Params).

claimed(true, Params) ->
    try execute(Params)
    after set_run_in_progress(false)
    end;
claimed(false, _Params) ->
    {error, run_in_progress}.

%% @doc Whether a run is in flight (the flag `run/1' sets around
%% itself).
-spec run_in_progress() -> boolean().
run_in_progress() ->
    persistent_term:get(?FLAG, false).

%% @doc Set the run flag. Exported for the tests that must fake a run in
%% flight (and for an operator probing what a concurrent POST sees);
%% the run path sets and clears it itself, and nothing else should leave
%% it set.
-spec set_run_in_progress(boolean()) -> ok.
set_run_in_progress(Busy) when is_boolean(Busy) ->
    persistent_term:put(?FLAG, Busy).

claim() ->
    case run_in_progress() of
        true -> false;
        false -> set_run_in_progress(true), true
    end.

%% Exactly the documented shapes; no key may ride along.
execute(#{run := <<"baseline">>} = Params) when map_size(Params) =:= 1 ->
    run_baseline();
execute(#{genome := Genome} = Params) when map_size(Params) =:= 1 ->
    run_genome(Genome);
execute(Params) when map_size(Params) =:= 0 ->
    run_baseline();
execute(Params) ->
    {error, {malformed_params, Params}}.

run_baseline() ->
    write(<<"incumbent">>, fun() -> mcl_sec_trainer_baseline:run() end).

run_genome(Genome) ->
    case vector(Genome) of
        {ok, Vector} -> genome_run(Vector);
        {error, _} = Error -> Error
    end.

genome_run(Vector) ->
    Name = mcl_sec_trainer_genome:policy_name(Vector),
    Policy = mcl_sec_trainer_genome:policy(Vector),
    write(Name, fun() -> episodes(Policy, Name) end).

%% The eight-scenario table at the episode defaults, named so the
%% artifact says whose numbers these are.
episodes(Policy, Name) ->
    Opts = #{policy => Policy, policy_name => Name, windows => 60, seed => 0},
    [mcl_sec_trainer_episode:run(Scenario, Opts)
     || Scenario <- mcl_sec_trainer_scenarios:names()].

write(Name, ReportsFun) ->
    Dir = mcl_sec_trainer_reporter:run_sets_dir(mcl_sec_guard),
    Reports = ReportsFun(),
    Meta = #{policy => Name, commit => <<"console-run">>},
    case mcl_sec_trainer_reporter:write_runset(Dir, Reports, Meta) of
        ok -> {ok, #{policy => Name, reports => length(Reports), dir => Dir}};
        {error, Reason} -> {error, {run_set_not_written, Reason}}
    end.

%% A genome is exactly the policy net's parameter count of numbers;
%% integer JSON numbers are accepted and normalised to floats, so the
%% same genome names the same run set however it was typed.
vector(Genome) when is_list(Genome) ->
    Count = length(Genome),
    Want = param_count(),
    case Count =:= Want of
        true -> numbers(Genome);
        false -> {error, {malformed_genome, {bad_length, Count, Want}}}
    end;
vector(_NotAList) ->
    {error, {malformed_genome, not_a_list}}.

numbers(Genome) ->
    case first_bad_number(Genome) of
        ok -> {ok, [V * 1.0 || V <- Genome]};
        {bad, Bad} -> {error, {malformed_genome, {bad_element, Bad}}}
    end.

first_bad_number([V | Rest]) when is_number(V) -> first_bad_number(Rest);
first_bad_number([Bad | _]) -> {bad, Bad};
first_bad_number([]) -> ok.

param_count() -> mcl_sec_trainer_policy_net:param_count().
