%%% @doc The fitness vector: weights, budgets, thresholds, and the hard
%%% gates that reject an episode whatever its weighted score.
-module(mcl_sec_trainer_fitness_tests).

-include_lib("eunit/include/eunit.hrl").

a_clean_episode_scores_one_test() ->
    Score = mcl_sec_trainer_fitness:score(clean_measurements(), mcl_sec_trainer_fitness:config()),
    ?assertEqual(1.0, maps:get(fitness, Score)),
    ?assertEqual(ok, maps:get(envelope, maps:get(gates, Score))),
    ?assertEqual(ok, maps:get(starvation, maps:get(gates, Score))),
    ?assertEqual(ok, maps:get(runaway, maps:get(gates, Score))),
    ?assertEqual(1, maps:get(fitness_version, Score)).

a_gate_failure_rejects_the_episode_test() ->
    Starved = maps:merge(clean_measurements(), #{starvation_windows => 6}),
    Score = mcl_sec_trainer_fitness:score(Starved, mcl_sec_trainer_fitness:config()),
    ?assertEqual(rejected, maps:get(fitness, Score)),
    ?assertMatch({fail, #{starvation_windows := 6}},
                 maps:get(starvation, maps:get(gates, Score))).

an_envelope_violation_rejects_the_episode_test() ->
    Violated = maps:merge(clean_measurements(), #{envelope_violations => 1}),
    Score = mcl_sec_trainer_fitness:score(Violated, mcl_sec_trainer_fitness:config()),
    ?assertEqual(rejected, maps:get(fitness, Score)),
    ?assertMatch({fail, #{envelope_violations := 1}},
                 maps:get(envelope, maps:get(gates, Score))).

a_pinned_limit_after_the_pressure_rejects_the_episode_test() ->
    Pinned = maps:merge(clean_measurements(), #{runaway_windows => 11}),
    Score = mcl_sec_trainer_fitness:score(Pinned, mcl_sec_trainer_fitness:config()),
    ?assertEqual(rejected, maps:get(fitness, Score)),
    ?assertMatch({fail, #{runaway_windows := 11}},
                 maps:get(runaway, maps:get(gates, Score))).

the_vector_reports_each_concern_test() ->
    Measurements = maps:merge(
                     clean_measurements(),
                     #{attacker_attempted => 100,
                       attacker_admitted => 20,
                       legit_attempted => 50,
                       legit_admitted => 40,
                       quiet_windows => 4,
                       applies => 1,
                       churn => 2.0}),
    Vector = maps:get(vector,
                      mcl_sec_trainer_fitness:score(Measurements,
                                                    mcl_sec_trainer_fitness:config())),
    ?assert(abs(maps:get(containment, Vector) - 0.8) < 0.0001),
    ?assert(abs(maps:get(admission, Vector) - 0.8) < 0.0001),
    ?assert(abs(maps:get(recovery, Vector) - 0.6) < 0.0001),
    ?assert(abs(maps:get(stability, Vector) - 0.7) < 0.0001).

the_defaults_carry_version_one_test() ->
    Config = mcl_sec_trainer_fitness:config(),
    ?assertEqual(1, mcl_sec_trainer_fitness:version(Config)),
    ?assertEqual(4, maps:size(maps:get(weights, Config))).

the_defaults_validate_test() ->
    ?assertEqual(ok, mcl_sec_trainer_fitness:validate(mcl_sec_trainer_fitness:defaults())).

a_bad_config_fails_loud_test() ->
    Bad = fun(Default, Fun) -> mcl_sec_trainer_fitness:validate(Fun(Default)) end,
    D = mcl_sec_trainer_fitness:defaults(),
    ?assertMatch({error, {bad_fitness_config, version_required}},
                 Bad(D, fun(M) -> maps:remove(version, M) end)),
    ?assertMatch({error, {bad_fitness_config, weights_budgets_thresholds_required}},
                 Bad(D, fun(M) -> M#{weights := nope} end)),
    ?assertMatch({error, {bad_weights, _}},
                 Bad(D, fun(M) -> M#{weights := #{containment => 0.5,
                                                  admission => 0.5}} end)),
    ?assertMatch({error, {bad_weights, _}},
                 Bad(D, fun(M) -> M#{weights := #{containment => 1.2,
                                                  admission => -0.2,
                                                  recovery => 0.5,
                                                  stability => 0.5}} end)),
    ?assertMatch({error, {not_positive_integers, _}},
                 Bad(D, fun(M) -> M#{budgets := #{recovery_windows => 0,
                                                  churn => 10}} end)),
    ?assertMatch({error, {bad_fitness_config, {not_a_map, [1]}}},
                 mcl_sec_trainer_fitness:validate([1])).

a_malformed_config_is_an_error_not_a_score_test() ->
    D = mcl_sec_trainer_fitness:defaults(),
    ?assertError({bad_fitness_config, _},
                 mcl_sec_trainer_fitness:score(clean_measurements(),
                                               maps:remove(version, D))).

clean_measurements() ->
    #{attacker_attempted => 0, attacker_admitted => 0,
      legit_attempted => 0, legit_admitted => 0,
      hot_windows => 0, quiet_windows => 0,
      applies => 0, churn => 0.0,
      starvation_windows => 0, runaway_windows => 0,
      envelope_violations => 0}.
