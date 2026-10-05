%%% @doc Episodes and the incumbent baseline: the loop's measurements,
%%% and the properties the plan already predicts for the placeholder
%%% rule — the degenerate policy the recorded probe session exposed at
%%% small scale, now reproduced and scored in the sim.
-module(mcl_sec_trainer_episode_tests).

-include_lib("eunit/include/eunit.hrl").

episodes_are_deterministic_test() ->
    Opts = #{windows => 20, seed => 7,
             policy => fun mcl_sec_trainer_baseline:policy/1,
             policy_name => incumbent},
    ?assertEqual(mcl_sec_trainer_episode:run(uniform_flood, Opts),
                 mcl_sec_trainer_episode:run(uniform_flood, Opts)).

a_quiet_episode_scores_a_perfect_fitness_test() ->
    Report = mcl_sec_trainer_episode:run(calm, #{policy => fun noop/1, policy_name => noop}),
    ?assertEqual(1.0, maps:get(fitness, Report)),
    ?assertEqual(0, maps:get(applies, maps:get(measurements, Report))),
    ?assertEqual(ok, maps:get(runaway, maps:get(gates, Report))),
    ?assertEqual(ok, maps:get(starvation, maps:get(gates, Report))).

the_incumbent_leaves_a_calm_service_alone_test() ->
    Report = incumbent(calm),
    ?assertEqual(0, maps:get(applies, maps:get(measurements, Report))),
    ?assertEqual(1.0, maps:get(fitness, Report)).

the_incumbent_ratchets_on_a_single_probe_and_never_returns_test() ->
    %% The recorded session's exact shape: one probe, then quiet. The
    %% incumbent proposes the floor once and holds it forever — the
    %% runaway gate names it and the episode is rejected, even though
    %% the quiet legit traffic is small enough to survive the floor.
    Report = incumbent(probe_then_quiet),
    Measurements = maps:get(measurements, Report),
    ?assertEqual(1, maps:get(applies, Measurements)),
    ?assertEqual(1.0, maps:get(admission, maps:get(vector, Report))),
    ?assertEqual(1, maps:get(per_caller_max, maps:get(final_limits, Measurements))),
    ?assertMatch({fail, _}, maps:get(runaway, maps:get(gates, Report))),
    ?assertEqual(rejected, maps:get(fitness, Report)).

the_incumbent_oscillates_under_a_steady_flood_test() ->
    %% One attacker at a steady rate: the incumbent proposes the floor,
    %% the flood's own over-limit count proposes it back up, and the
    %% two swing the posture every window — stability collapses, and
    %% every other window admits more of the flood than the one before.
    Report = incumbent(uniform_flood),
    Measurements = maps:get(measurements, Report),
    Vector = maps:get(vector, Report),
    ?assert(maps:get(containment, Vector) > 0.8),
    ?assert(maps:get(admission, Vector) < 0.7),
    ?assertEqual(0.0, maps:get(stability, Vector)),
    ?assert(maps:get(applies, Measurements) > 50),
    ?assert(maps:get(churn, Measurements) > 10),
    ?assertEqual(ok, maps:get(runaway, maps:get(gates, Report))).

the_incumbent_hurts_a_legit_spike_it_mistakes_for_an_attack_test() ->
    %% The false-positive trap: the burst is legitimate, and the floor
    %% proposal cuts its admission — without ever starving it out (each
    %% caller keeps one call per window, so the starvation gate holds).
    Report = incumbent(legit_spike),
    Measurements = maps:get(measurements, Report),
    Vector = maps:get(vector, Report),
    ?assert(maps:get(applies, Measurements) >= 4),
    ?assert(maps:get(admission, Vector) < 0.9),
    ?assertEqual(ok, maps:get(starvation, maps:get(gates, Report))),
    ?assertEqual(ok, maps:get(runaway, maps:get(gates, Report))).

the_incumbent_cannot_contain_a_size_ladder_at_all_test() ->
    %% Every ladder rung is refused by the size stage itself — the
    %% containment is the stage's, not the rule's — and the incumbent
    %% still ratchets on the size noise, swinging 1<->5 through the
    %% ladder.
    Report = incumbent(size_ladder),
    Measurements = maps:get(measurements, Report),
    Vector = maps:get(vector, Report),
    ?assert(abs(maps:get(containment, Vector) - 1.0) < 0.0001),
    ?assert(maps:get(applies, Measurements) > 5),
    ?assert(maps:get(churn, Measurements) > 1.0),
    ?assertEqual(ok, maps:get(runaway, maps:get(gates, Report))).

the_incumbent_reads_a_sybil_flood_as_noise_and_ratchets_test() ->
    %% The diversity bound denies the tail of the flood; the incumbent
    %% cannot tell bound-denials from rate-denials and ratchets on the
    %% noise.
    Report = incumbent(sybil),
    Measurements = maps:get(measurements, Report),
    ?assert(maps:get(containment, maps:get(vector, Report)) < 0.2),
    ?assert(maps:get(applies, Measurements) >= 2),
    ?assert(maps:get(admission, maps:get(vector, Report)) > 0.9).

the_incumbent_never_springs_back_from_a_bursty_flood_test() ->
    %% Between the bursts the floor settles at the legit over-limit
    %% count and never returns to the declared baseline: the recovery
    %% is the windows' doing, not the rule's.
    Report = incumbent(bursty_flood),
    Measurements = maps:get(measurements, Report),
    ?assert(maps:get(applies, Measurements) > 10),
    ?assertEqual(0.0, maps:get(stability, maps:get(vector, Report))),
    ?assert(maps:get(per_caller_max, maps:get(final_limits, Measurements)) < 10).

the_incumbent_cannot_express_a_move_inside_the_envelope_under_a_mix_test() ->
    %% Size + rate at once: the over-limit count of the mixed flood is
    %% fifteen callers, the incumbent proposes per_caller_max 15, and
    %% the envelope refuses it ten windows running — the placeholder
    %% rule literally cannot act inside the envelope, and the attempt
    %% itself disqualifies the episode.
    Report = incumbent(coordinated),
    Measurements = maps:get(measurements, Report),
    ?assert(maps:get(envelope_violations, Measurements) >= 5),
    ?assertMatch({fail, #{envelope_violations := _}},
                 maps:get(envelope, maps:get(gates, Report))),
    ?assertEqual(rejected, maps:get(fitness, Report)).

a_policy_that_refuses_the_envelope_fails_the_envelope_gate_test() ->
    Opts = #{policy => fun out_of_envelope/1, policy_name => bad},
    Report = mcl_sec_trainer_episode:run(calm, Opts),
    ?assertMatch({fail, #{envelope_violations := _}},
                 maps:get(envelope, maps:get(gates, Report))),
    ?assertEqual(rejected, maps:get(fitness, Report)).

incumbent(Scenario) ->
    mcl_sec_trainer_episode:run(Scenario, #{policy => fun mcl_sec_trainer_baseline:policy/1,
                                            policy_name => incumbent}).

noop(_Ctx) ->
    none.

out_of_envelope(_Ctx) ->
    #{per_caller_max => 1000}.
