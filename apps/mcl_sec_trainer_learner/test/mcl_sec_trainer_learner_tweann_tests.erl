%%% @doc The TWEANN arm's tests (mcl-sec-guard#20): the morphology and
%%% constraint construct a runnable agent, the DAG path scores it, a
%%% mutated genome still scores (or scores the -1.0 wall, never a crash),
%%% and a two-generation smoke run returns the arm's contract, with the
%%% same seed reproducing the same numbers.
-module(mcl_sec_trainer_learner_tweann_tests).

-include_lib("eunit/include/eunit.hrl").

tweann_arm_test_() ->
    {setup,
     fun setup/0,
     fun (_) ->
         innovation:reset(),
         genotype:reset_db()
     end,
     fun (_) ->
         [fun a_constructed_agent_scores/0,
          fun a_mutated_genome_still_scores/0,
          fun the_smoke_run_returns_the_contract/0,
          fun the_same_seed_reproduces/0]
     end}.

setup() ->
    ok = mcl_sec_trainer_learner_tweann:register().

construct() ->
    Specie = {genotype_rand:uniform(), specie},
    genotype:construct_Agent(Specie, genotype:generate_id(agent),
                             mcl_sec_trainer_learner_tweann:constraint()).

a_constructed_agent_scores() ->
    Id = construct(),
    ?assertMatch({ok, _}, mcl_sec_trainer_learner_tweann:dag(Id)),
    Fitness = mcl_sec_trainer_learner_tweann:agent_fitness(Id, [calm]),
    ?assert(is_float(Fitness)),
    ?assert(Fitness >= -1.0 andalso Fitness =< 1.0),
    Topology = mcl_sec_trainer_learner_tweann:topology(Id),
    ?assertEqual(24, maps:get(inputs, Topology)),
    ?assertEqual(3, maps:get(outputs, Topology)).

a_mutated_genome_still_scores() ->
    Id = construct(),
    ok = genome_mutator:mutate(Id, 8),
    Fitness = mcl_sec_trainer_learner_tweann:agent_fitness(Id, [calm, uniform_flood]),
    ?assert(is_float(Fitness)),
    ?assert(Fitness >= -1.0 andalso Fitness =< 1.0).

the_smoke_run_returns_the_contract() ->
    Result = mcl_sec_trainer_learner_tweann:evolve(
               #{population => 4, generations => 2, scenarios => [calm],
                 elite => 1, parents => 1, seed => 7}),
    ?assertMatch(#{best_agent := _, best_fitness := _, generations := 2,
                   evaluations := 8, history := _, impl := _}, Result),
    ?assert(is_float(maps:get(best_fitness, Result))),
    case maps:is_key(champion, Result) of
        true ->
            ?assertMatch(#{summary := #{episodes := 32}}, maps:get(champion, Result));
        false ->
            ?assertEqual(undefined, maps:get(best_agent, Result))
    end.

the_same_seed_reproduces() ->
    Opts = #{population => 4, generations => 2, scenarios => [calm],
             elite => 1, parents => 1, seed => 11},
    A = mcl_sec_trainer_learner_tweann:evolve(Opts),
    B = mcl_sec_trainer_learner_tweann:evolve(Opts),
    ?assertEqual(maps:get(best_fitness, A), maps:get(best_fitness, B)),
    ?assertEqual(maps:get(history, A), maps:get(history, B)).
