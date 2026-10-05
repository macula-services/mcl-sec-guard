%%% @doc A genome as an episode policy: the fixed-shape evaluator
%%% plugged into the sense → decide → act loop.
%%%
%%% The genome is the flat weight vector sep_cma_es evolves; the policy
%%% reads the observation vector (two windows of features), runs the
%%% distilled feedforward, maps the three tightness scalars to a
%%% guardian-tier move with deadband, and returns the overrides — or
%%% `none' when the move is not worth making. The episode applies the
%%% move through the same envelope-clamped path every policy uses, so a
%%% genome cannot do what the domain refuses.
-module(mcl_sec_trainer_genome).

-export([policy/1, id/1, policy_name/1, champion_report/1, champion_report/2]).

%% @doc The policy fun for mcl_sec_trainer_episode:run/2.
-spec policy([float()]) -> fun((map()) -> none | map()).
policy(Vector) ->
    fun(Ctx) -> decide_move(Vector, Ctx) end.

decide_move(Vector, #{stats := Stats, prev_stats := PrevStats}) ->
    Inputs = mcl_sec_trainer_features:vector(Stats, PrevStats),
    [RateT, SizeT, DivT] = mcl_sec_trainer_policy_net:output(Vector, Inputs),
    move_or_none(mcl_sec_trainer_actions:moves(Stats, RateT, SizeT, DivT)).

move_or_none(Moved) ->
    case map_size(Moved) > 0 of
        true -> Moved;
        false -> none
    end.

%% @doc A cheap, stable name for audit and reports — the full genome is
%% the weight vector itself, recorded with the run.
-spec id([float()]) -> binary().
id(Vector) ->
    Hash = erlang:phash2(Vector, 16#ffffffff),
    Hex = integer_to_binary(Hash, 16),
    Pad = binary:copy(<<"0">>, 8 - byte_size(Hex)),
    <<Pad/binary, Hex/binary>>.

-spec policy_name([float()]) -> binary().
policy_name(Vector) ->
    <<"genome-", (id(Vector))/binary>>.

%% @doc The champion's standing: every scenario at seed 0 (train) plus
%% held-out seeds, each the full episode report, plus the summary a
%% human compares against the incumbent (mean fitness over passing
%% episodes, gate-failure count, per-scenario vectors).
-spec champion_report([float()]) -> map().
champion_report(Vector) ->
    champion_report(Vector, #{}).

-spec champion_report([float()], map()) -> map().
champion_report(Vector, Opts) ->
    Policy = policy(Vector),
    Suite = mcl_sec_trainer_scenarios:names(),
    Train = [episode_report(Name, Policy, 0, Vector, Opts) || Name <- Suite],
    Seeds = maps:get(held_out_seeds, Opts, [1, 2, 3]),
    HeldOut = [[episode_report(Name, Policy, Seed, Vector, Opts)
                || Name <- Suite] || Seed <- Seeds],
    #{genome_id => id(Vector),
      param_count => length(Vector),
      train => Train,
      held_out => HeldOut,
      summary => summary(Train, HeldOut)}.

episode_report(Name, Policy, Seed, Vector, Opts) ->
    EpisodeOpts = #{policy => Policy,
                    policy_name => policy_name(Vector),
                    seed => Seed,
                    windows => maps:get(windows, Opts, 60)},
    mcl_sec_trainer_episode:run(Name, EpisodeOpts).

%% The standing, in one map: how many episodes pass their gates, the
%% mean fitness over the passing ones, and the worst gate.
summary(Train, HeldOut) ->
    All = Train ++ lists:append(HeldOut),
    Passing = [maps:get(fitness, R) || R <- All, maps:get(fitness, R) =/= rejected],
    #{episodes => length(All),
      gate_failures => length(All) - length(Passing),
      mean_fitness => case Passing of
                          [] -> undefined;
                          _ -> lists:sum(Passing) / length(Passing)
                      end}.
