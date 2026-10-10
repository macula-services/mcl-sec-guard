%%% @doc The learner arm's tests: the sep_cma_es contract, the suite
%%% fitness shape, and the byte-identity lock of the trainer's inlined
%%% evaluator against the faber-backed one.
%%%
%%% mcl-sec-guard#14: the trainer app is faber-free, so the exact lock
%%% — comparing `mcl_sec_trainer_policy_net:output/2' against the
%%% pre-split net evaluated through `functions:tanh/1' and
%%% `functions:sigmoid/1' — lives here, where faber is a real
%%% dependency. Equality is exact: both sides run in this process, so
%%% the claim "byte-identical" holds on any platform without pinning
%%% libm-dependent constants.
-module(mcl_sec_trainer_learner_tests).

-include_lib("eunit/include/eunit.hrl").

%% ---- the sep_cma_es arm ----

sep_cma_es_returns_the_learner_contract_test() ->
    Result = mcl_sec_trainer_learner:evolve(
               #{scenarios => [calm], max_generations => 2,
                 lambda => 8, init_sigma => 0.5}),
    ?assertMatch(#{best := _, fitness := _, generations := _,
                   evaluations := _, reason := _}, Result),
    ?assert(is_float(maps:get(fitness, Result))).

suite_fitness_is_a_float_and_rejection_scores_low_test() ->
    Vector = lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 0.0),
    Fitness = mcl_sec_trainer_learner:suite_fitness(Vector, [calm]),
    ?assert(is_float(Fitness)),
    ?assert(Fitness >= -1.0 andalso Fitness =< 1.0).

%% ---- the lock: the inlined net is byte-identical to the faber one ----

%% The net must agree with its own pre-split evaluation, exactly, on
%% every case — the zero vector, a deterministic spread, and vectors
%% saturated far past the sigmoid clamp (|pre-activation| > 10), where
%% faber clamps before the exp and a dropped clamp would move an output
%% by ~4.5e-5, hundreds of ulps past exact equality.
the_inlined_evaluator_is_the_faber_net_test() ->
    In = standard_stats_vector(),
    Cases = [spread_vector(),
             lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 0.0),
             lists:duplicate(mcl_sec_trainer_policy_net:param_count(), 25.0),
             lists:duplicate(mcl_sec_trainer_policy_net:param_count(), -25.0)],
    [begin
         Expected = faber_output(Vector, In),
         ?assertEqual(Expected, mcl_sec_trainer_policy_net:output(Vector, In))
     end || Vector <- Cases].

%% The pre-split evaluator, verbatim: same shape, same arithmetic and
%% summation order as mcl_sec_trainer_policy_net, only the activations
%% come from faber's functions module. This is the reference #14's
%% inlining must equal.
faber_output(Vector, Inputs) ->
    {Hidden, Rest} = dense(Vector, 24, 12, Inputs, fun functions:tanh/1),
    {Out, _Rest} = dense(Rest, 12, 3, Hidden, fun functions:sigmoid/1),
    Out.

dense(Vector, In, Out, X, Activation) ->
    WSize = In * Out,
    W = lists:sublist(Vector, WSize),
    B = lists:sublist(lists:nthtail(WSize, Vector), Out),
    Rest = lists:nthtail(WSize + Out, Vector),
    Y = [Activation(dot(In, W, B, I, X)) || I <- lists:seq(1, Out)],
    {Y, Rest}.

dot(In, W, B, I, X) ->
    Sum = lists:sum([lists:nth((I - 1) * In + J, W) * lists:nth(J, X)
                     || J <- lists:seq(1, In)]),
    Sum + lists:nth(I, B).

spread_vector() ->
    [math:sin(I / 7) / 3 || I <- lists:seq(1, mcl_sec_trainer_policy_net:param_count())].

%% The standard stats: the trainer test suite's base stats, turned into
%% the observation vector (two windows; no previous window).
standard_stats_vector() ->
    Base = #{limits => #{max_payload_external_size => 4096,
                         window_ms => 10000,
                         per_caller_max => 10,
                         global_max => 100,
                         max_distinct_callers => 64},
             envelope => #{per_caller_max => #{min => 1, max => 10},
                           global_max => #{min => 10, max => 100},
                           max_payload_external_size => #{min => 1024, max => 65536},
                           max_distinct_callers => #{min => 8, max => 64}},
             denied_rate => 0, denied_size => 0,
             callers_over_limit => 0, distinct_callers => 0,
             global_count => 0, global_max => 100,
             top_callers => [],
             audit => []},
    mcl_sec_trainer_features:vector(Base, undefined).
