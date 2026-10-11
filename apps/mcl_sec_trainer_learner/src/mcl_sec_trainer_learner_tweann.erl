%%% @doc The TWEANN arm (mcl-sec-guard#20): topology evolution against
%%% the same fitness and budget as the fixed-shape sep_cma_es arm.
%%%
%%% A genome here is a faber_tweann genotype (sensors -> neurons ->
%%% actuators) evolved by genome_mutator under a feedforward constraint:
%%% mutations add and splice neurons, add links and biases, and adjust
%%% weights and activations. Evaluation decodes the genotype through the
%%% DAG path (genotype_to_dag/tweann_nif, the pure fallback when the NIF
%%% is skipped), so any acyclic feedforward topology flies, skips
%%% included; a genotype the DAG path refuses scores -1.0, the same wall
%%% a gate-failed episode scores. A run seeded the same way reproduces:
%%% genotype_rand:seed/1 governs construction and mutation, rand:seed/2
%%% this module's own parent draws.
%%%
%%% Budget: one generation evaluates `population' individuals on the
%%% whole episode suite, so population 21 over 200 generations is 4200
%%% suite evaluations, the baseline champion's budget (200 generations
%%% of sep_cma_es at its lambda of 21). Evolution per generation:
%%% evaluate all, keep the top `elite' as they are, fill the rest with
%%% clones of the top `parents', each mutated `mutations' times. The
%%% champion is reported on held-out seeds by champion_report/2: the
%%% promotion comparison stays a human read, never the search's own
%%% measure.
%%%
%%% window_ms is human-only and no genome can move it: the policy
%%% returns mcl_sec_trainer_actions moves, which never touch it.
-module(mcl_sec_trainer_learner_tweann).

-include_lib("faber_tweann/include/records.hrl").

-export([register/0, morphology/0, constraint/0]).
-export([agent_fitness/2, dag/1, topology/1]).
-export([evolve/0, evolve/1, champion_report/1, champion_report/2]).

-define(REJECTED, -1.0).

%%==============================================================================
%% Morphology, constraint, DB lifecycle
%%==============================================================================

-spec morphology() -> atom().
morphology() ->
    guardian_posture.

%% @doc Register the morphology and make the genotype ETS tables.
%% Idempotent, and safe to call from every entry point.
-spec register() -> ok.
register() ->
    ok = application:set_env(faber_tweann, nif_impl, fallback),
    {ok, _Started} = application:ensure_all_started(faber_tweann),
    case morphology_registry:is_registered(morphology()) of
        true -> ok;
        false -> ok = morphology_registry:register(morphology(), mcl_sec_trainer_learner_morphology)
    end,
    genotype:init_db(),
    innovation:init().

%% @doc The feedforward constraint the population evolves under: one
%% activation per neuron out of the standard trio, link mutations that
%% only ever connect to a strictly higher layer (feedforward mode).
%% Deliberately absent: the LTC and organelle mutations (a later option
%% to test, not this experiment's variable) and the sensor/actuator
%% mutations (the interface is fixed by the morphology).
-spec constraint() -> #constraint{}.
constraint() ->
    #constraint{
        morphology = morphology(),
        connection_architecture = feedforward,
        neural_afs = [tanh, sigmoid, relu],
        neural_pfns = [none],
        neural_aggr_fs = [dot_product],
        substrate_plasticities = [none],
        substrate_linkforms = [l2l_feedforward],
        agent_encoding_types = [neural],
        heredity_types = [darwinian],
        mutation_operators = [
            {add_neuron, 40},
            {outsplice, 40},
            {add_inlink, 40},
            {add_outlink, 40},
            {add_bias, 10},
            {mutate_weights, 100},
            {mutate_af, 30}
        ],
        tot_topological_mutations_fs = [{ncount_exponential, 0.5}],
        objectives = [main_fitness, inverse_tot_n]
    }.

%%==============================================================================
%% Evaluation
%%==============================================================================

%% @doc The agent's suite fitness: the mean episode fitness over the
%% scenarios, one full episode each, exactly as the baseline arm scores
%% a weight vector. A genotype the DAG path cannot run, and a policy
%% that raises on an odd mutated genome, both score -1.0.
-spec agent_fitness(term(), [atom()]) -> float().
agent_fitness(AgentId, Suite) ->
    try
        case genotype_to_dag:compile(AgentId) of
            {ok, Net} -> suite_fitness(Net, Suite);
            {error, _} -> ?REJECTED
        end
    catch
        _Class:_Reason -> ?REJECTED
    end.

suite_fitness(_Net, []) ->
    ?REJECTED;
suite_fitness(Net, Suite) ->
    Policy = fun(Ctx) -> decide(Net, Ctx) end,
    Values = [episode_value(Name, Policy) || Name <- Suite],
    lists:sum(Values) / length(Suite).

episode_value(Name, Policy) ->
    Report = mcl_sec_trainer_episode:run(Name, #{policy => Policy,
                                                policy_name => tweann,
                                                seed => 0}),
    case maps:get(fitness, Report) of
        rejected -> ?REJECTED;
        Fitness -> Fitness
    end.

%% The DAG evaluator's outputs are raw floats (any activation the search
%% picked); the actions map reads tightness in [0, 1]. Clamp: the net can
%% be wrong outside the range, it just cannot act outside the envelope.
decide(Net, #{stats := Stats, prev_stats := PrevStats}) ->
    Inputs = mcl_sec_trainer_features:vector(Stats, PrevStats),
    [RateT, SizeT, DivT] = tweann_nif:evaluate(Net, Inputs),
    Moved = mcl_sec_trainer_actions:moves(Stats, clamp01(RateT),
                                          clamp01(SizeT), clamp01(DivT)),
    move_or_none(Moved).

move_or_none(Moved) ->
    case map_size(Moved) > 0 of
        true -> Moved;
        false -> none
    end.

clamp01(X) ->
    erlang:min(1.0, erlang:max(0.0, float(X))).

%% @doc The agent's genotype as the flat DAG the evaluator runs (the
%% artifact a champion is persisted as; see scripts/evolve_guardian.sh).
-spec dag(term()) -> {ok, genotype_to_dag:dag()} | {error, genotype_to_dag:reason()}.
dag(AgentId) ->
    genotype_to_dag:nodes(AgentId).

%% @doc The champion's shape: neurons, connections, parameters.
-spec topology(term()) -> map().
topology(AgentId) ->
    case genotype_to_dag:nodes(AgentId) of
        {ok, {Nodes, InputCount, Outputs}} ->
            NeuronNodes = [Node || Node = {I, _, _, _, _} <- Nodes, I >= InputCount],
            Connections = lists:sum([length(Conns) || {_, _, _, _, Conns} <- NeuronNodes]),
            #{inputs => InputCount,
              outputs => length(Outputs),
              neurons => length(NeuronNodes),
              connections => Connections,
              params => Connections + length(NeuronNodes)};
        {error, Reason} ->
            #{error => Reason}
    end.

%%==============================================================================
%% Evolution
%%==============================================================================

-spec evolve() -> map().
evolve() ->
    evolve(#{}).

%% @doc Opts: population (21), generations (200), elite (5), parents
%% (elite), mutations (1), scenarios (the whole table), seed (0).
%% Returns best_agent, best_fitness, generations, evaluations, history
%% (best-so-far per generation), impl, topology and the champion report.
-spec evolve(map()) -> map().
evolve(Opts) ->
    ok = register(),
    Population = maps:get(population, Opts, 21),
    Generations = maps:get(generations, Opts, 200),
    Seed = maps:get(seed, Opts, 0),
    ok = genotype_rand:seed(Seed),
    _ = rand:seed(exsss, {Seed, Seed + 1, Seed + 2}),
    State = #{generations => Generations,
              generation => 0,
              evaluations => 0,
              elite => maps:get(elite, Opts, 5),
              parents => maps:get(parents, Opts, maps:get(elite, Opts, 5)),
              mutations => maps:get(mutations, Opts, 1),
              suite => maps:get(scenarios, Opts, mcl_sec_trainer_scenarios:names()),
              best => {undefined, ?REJECTED},
              history => []},
    finish(loop(seed_population(Population), State)).

seed_population(Size) ->
    Specie = {genotype_rand:uniform(), specie},
    [genotype:construct_Agent(Specie, genotype:generate_id(agent), constraint())
     || _ <- lists:seq(1, Size)].

loop(Population, State) ->
    Suite = maps:get(suite, State),
    Evaluated = [{AgentId, agent_fitness(AgentId, Suite)} || AgentId <- Population],
    Ranked = lists:sort(fun({_, A}, {_, B}) -> A >= B end, Evaluated),
    [{BestId, BestF} | _] = Ranked,
    Best = better(maps:get(best, State), {BestId, BestF}),
    State1 = State#{generation := maps:get(generation, State) + 1,
                    evaluations := maps:get(evaluations, State) + length(Population),
                    best := Best,
                    history := [element(2, Best) | maps:get(history, State)]},
    case maps:get(generation, State1) >= maps:get(generations, State1) of
        true -> State1;
        false -> loop(next_population(Ranked, State1), State1)
    end.

better({undefined, _OldF}, NewBest) ->
    NewBest;
better({_OldId, OldF}, Best = {_Id, F}) when F > OldF ->
    Best;
better(OldBest, _NewBest) ->
    OldBest.

next_population(Ranked, State) ->
    {Elites, _Rest} = lists:split(erlang:min(maps:get(elite, State), length(Ranked)), Ranked),
    ParentIds = lists:sublist([Id || {Id, _} <- Ranked], maps:get(parents, State)),
    Offspring = [mutated_clone(ParentIds, maps:get(mutations, State))
                 || _ <- lists:seq(1, length(Ranked) - length(Elites))],
    [Id || {Id, _} <- Elites] ++ Offspring.

mutated_clone(ParentIds, Mutations) ->
    Parent = lists:nth(rand:uniform(length(ParentIds)), ParentIds),
    Clone = genotype:clone_Agent(Parent),
    ok = genome_mutator:mutate(Clone, Mutations),
    Clone.

finish(State) ->
    {BestId, BestF} = maps:get(best, State),
    Base = #{best_agent => BestId,
             best_fitness => BestF,
             generations => maps:get(generation, State),
             evaluations => maps:get(evaluations, State),
             history => lists:reverse(maps:get(history, State)),
             impl => tweann_nif:impl()},
    case BestId of
        undefined -> Base;
        _ -> Base#{topology => topology(BestId), champion => champion_report(BestId)}
    end.

%%==============================================================================
%% The champion's standing
%%==============================================================================

-spec champion_report(term()) -> map().
champion_report(AgentId) ->
    champion_report(AgentId, #{}).

%% @doc The champion's standing: every scenario at seed 0 (train) plus
%% held-out seeds, each the full episode report, plus the summary a
%% human compares against the incumbent - mean fitness over passing
%% episodes, gate-failure count - and the champion's topology. The same
%% shape as mcl_sec_trainer_genome:champion_report/2 for the fixed
%% shape, so the two arms' numbers read side by side.
-spec champion_report(term(), map()) -> map().
champion_report(AgentId, Opts) ->
    case genotype_to_dag:compile(AgentId) of
        {ok, Net} -> report(AgentId, Net, Opts);
        {error, Reason} -> #{agent_id => AgentId, error => Reason}
    end.

report(AgentId, Net, Opts) ->
    Policy = fun(Ctx) -> decide(Net, Ctx) end,
    Train = [episode_report(Name, Policy, 0, Opts)
             || Name <- mcl_sec_trainer_scenarios:names()],
    Seeds = maps:get(held_out_seeds, Opts, [1, 2, 3]),
    HeldOut = [[episode_report(Name, Policy, Seed, Opts)
                || Name <- mcl_sec_trainer_scenarios:names()]
               || Seed <- Seeds],
    #{agent_id => AgentId,
      impl => tweann_nif:impl(),
      topology => topology(AgentId),
      train => Train,
      held_out => HeldOut,
      summary => summary(Train, HeldOut)}.

episode_report(Name, Policy, Seed, Opts) ->
    mcl_sec_trainer_episode:run(Name, #{policy => Policy,
                                        policy_name => tweann,
                                        seed => Seed,
                                        windows => maps:get(windows, Opts, 60)}).

summary(Train, HeldOut) ->
    All = Train ++ lists:append(HeldOut),
    Passing = [maps:get(fitness, R) || R <- All, maps:get(fitness, R) =/= rejected],
    #{episodes => length(All),
      gate_failures => length(All) - length(Passing),
      mean_fitness => case Passing of
                          [] -> undefined;
                          _ -> lists:sum(Passing) / length(Passing)
                      end}.
