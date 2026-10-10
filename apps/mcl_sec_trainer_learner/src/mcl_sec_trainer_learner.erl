%%% @doc The baseline learner: sep_cma_es over the distilled fixed
%%% shape (the plan's step 4, "Baseline first").
%%%
%%% Lives in its own app, `mcl_sec_trainer_learner' (mcl-sec-guard#14),
%%% so faber_tweann scopes to this app alone: the trainer app is
%%% faber-free, and the learner never enters the release — evolution
%%% stays a dev-box act.
%%%
%%% sep_cma_es (faber_tweann) evolves flat weight vectors and nothing
%%% else — exactly the shape this fixed feedforward takes. One fitness
%%% evaluation is the mean episode fitness over the scenario table, with
%%% a rejected episode (a hard-gate failure) scoring -1.0: strictly
%%% worse than any passing fitness in [0, 1], so the search learns the
%%% gates are walls, not slopes. The champion is then reported on
%%% held-out seeds — the promotion comparison against the incumbent is
%%% a human read, never the search's own measure.
-module(mcl_sec_trainer_learner).

-export([evolve/0, evolve/1, suite_fitness/1, suite_fitness/2]).

%% @doc Run sep_cma_es with defaults: the whole scenario table, seed 0,
%% no cap beyond the optimizer's own.
-spec evolve() -> map().
evolve() ->
    evolve(#{}).

%% Opts pass to sep_cma_es:evolve/3 (lambda, mu, max_generations,
%% fitness_goal, init_sigma, x0, trace, on_generation) plus `scenarios'
%% (default: the whole table). The faber NIF is optional acceleration;
%% the pure fallback is selected explicitly — sep_cma_es is pure Erlang
%% math and never touches the NIF anyway.
-spec evolve(map()) -> map().
evolve(Opts) ->
    ok = application:set_env(faber_tweann, nif_impl, fallback),
    Suite = maps:get(scenarios, Opts, mcl_sec_trainer_scenarios:names()),
    FitnessFun = fun(Vector) -> suite_fitness(Vector, Suite) end,
    sep_cma_es:evolve(FitnessFun, mcl_sec_trainer_policy_net:param_count(),
                      maps:remove(scenarios, Opts)).

-spec suite_fitness([float()]) -> float().
suite_fitness(Vector) ->
    suite_fitness(Vector, mcl_sec_trainer_scenarios:names()).

-spec suite_fitness([float()], [atom()]) -> float().
suite_fitness(Vector, Suite) ->
    Policy = mcl_sec_trainer_genome:policy(Vector),
    Values = [episode_value(Name, Policy) || Name <- Suite],
    lists:sum(Values) / length(Suite).

episode_value(Name, Policy) ->
    Report = mcl_sec_trainer_episode:run(
               Name, #{policy => Policy, policy_name => genome}),
    case maps:get(fitness, Report) of
        rejected -> -1.0;
        Fitness -> Fitness
    end.
