%%% @doc The observation vector the fixed-shape policy reads (the
%%% plan's §3 table, distilled to v1).
%%%
%%% One policy for all procedures: every feature is a ratio against the
%%% procedure's OWN limits and envelope, so the same genome reads any
%%% procedure. The vector is the CURRENT window's twelve features
%%% followed by the PREVIOUS window's twelve (K=1 history, zeros when
%%% there is no previous window): a stateless feedforward gets its
%%% temporal signal from the concatenation — LTC taus are the later
%%% experiment, not an assumption. The contract is versioned
%%% (feature_version = 1): a genome is never run against a different
%%% input shape.
%%%
%%% Features (current window, index 1..12; previous window 13..24):
%%%
%%%   1  rate_pressure   denied_rate / max(1, global_max)
%%%   2  size_pressure   denied_size / max(1, global_max)
%%%   3  over_limit      callers_over_limit / max(1, max_distinct_callers)
%%%   4  diversity       distinct_callers / max(1, max_distinct_callers)
%%%   5  fill            global_count / max(1, global_max)
%%%   6  offenders       top_callers length / 10
%%%   7  offender_max    heaviest caller count / max(1, per_caller_max)
%%%   8  offender_mean   mean caller count / max(1, per_caller_max)
%%%   9  per_caller posture    (value - min) / (max - min); no clamp => 0.5
%%%  10  global posture        (value - min) / (max - min); no clamp => 0.5
%%%  11  size posture          (value - min) / (max - min); no clamp => 0.5
%%%  12  diversity posture     (value - min) / (max - min); no clamp => 0.5
%%%
%%% Ratios may exceed 1 (a caller over budget IS the signal); posture
%%% features are in [0, 1] with 0 = envelope floor (tightest) and
%%% 1 = envelope ceiling (loosest).
-module(mcl_sec_trainer_features).

-export([size/0, version/0, vector/2]).

-define(WINDOW_FEATURES, 12).

%% @doc The flat vector length: 2 windows x 12 features.
-spec size() -> pos_integer().
size() ->
    2 * ?WINDOW_FEATURES.

-spec version() -> pos_integer().
version() ->
    1.

%% @doc Stats is the sim's stats map (or undefined for a missing
%% previous window — encoded as zeros, "no history").
-spec vector(map() | undefined, map() | undefined) -> [float()].
vector(Stats, PrevStats) ->
    window_vector(Stats) ++ window_vector(PrevStats).

window_vector(undefined) ->
    lists:duplicate(?WINDOW_FEATURES, 0.0);
window_vector(Stats) ->
    #{limits := Limits, envelope := Envelope} = Stats,
    PerCaller = maps:get(per_caller_max, Limits),
    Global = maps:get(global_max, Limits),
    Top = maps:get(top_callers, Stats),
    Counts = [maps:get(count, E) || E <- Top],
    MaxOffender = case Counts of [] -> 0; _ -> lists:max(Counts) end,
    MeanOffender = case Counts of
                       [] -> 0.0;
                       _ -> lists:sum(Counts) / length(Counts)
                   end,
    [maps:get(denied_rate, Stats) / erlang:max(Global, 1),
     maps:get(denied_size, Stats) / erlang:max(Global, 1),
     maps:get(callers_over_limit, Stats)
         / erlang:max(maps:get(max_distinct_callers, Limits), 1),
     maps:get(distinct_callers, Stats)
         / erlang:max(maps:get(max_distinct_callers, Limits), 1),
     maps:get(global_count, Stats) / erlang:max(Global, 1),
     length(Top) / 10,
     MaxOffender / erlang:max(PerCaller, 1),
     MeanOffender / erlang:max(PerCaller, 1),
     posture(per_caller_max, Limits, Envelope),
     posture(global_max, Limits, Envelope),
     posture(max_payload_external_size, Limits, Envelope),
     posture(max_distinct_callers, Limits, Envelope)].

%% How tight a key sits inside its envelope clamp: 0 = floor (tightest),
%% 1 = ceiling (loosest). A key the envelope does not cover is
%% human-only: its posture reads the neutral 0.5.
posture(Key, Limits, Envelope) ->
    case maps:get(Key, Envelope, undefined) of
        #{min := Min, max := Max} when Max > Min ->
            (maps:get(Key, Limits) - Min) / (Max - Min);
        _NoClampOrDegenerate ->
            0.5
    end.
