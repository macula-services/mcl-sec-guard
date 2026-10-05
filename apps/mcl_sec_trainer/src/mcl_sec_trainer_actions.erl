%%% @doc The action mapping: three posture scalars to a guardian-tier
%%% move (the plan's §4, first cut).
%%%
%%% Each scalar in [0, 1] maps across its keys' envelope clamps —
%%% 0 = floor (tightest), 1 = ceiling (loosest):
%%%
%%%     rate_tightness       -> per_caller_max, global_max
%%%     size_tightness       -> max_payload_external_size
%%%     diversity_tightness  -> max_distinct_callers
%%%
%%% `window_ms' is human-only (settled 2026-10-06), and a key the
%%% envelope does not cover cannot be moved by the guardian at all —
%%% both are simply never proposed. A move applies only when the mapped
%%% value differs from the effective one by at least one deadband step
%%% (10% of the envelope range) — hysteresis on top of the service-side
%%% anti-thrash. `global_max' never sits below `per_caller_max'. The
%%% resulting map is exactly what the sim's guardian-tier apply accepts:
%%% within envelope by construction, positive integers, valid relation.
-module(mcl_sec_trainer_actions).

-export([moves/4, deadband_fraction/0]).

-spec deadband_fraction() -> float().
deadband_fraction() ->
    0.1.

%% @doc Stats carries the effective limits and envelope in play; the
%% scalars are the net's three outputs. Returns a (possibly empty)
%% overrides map — an empty map means "no move worth making".
-spec moves(map(), float(), float(), float()) -> map().
moves(#{limits := Limits, envelope := Envelope}, RateT, SizeT, DivT) ->
    Candidates = [{per_caller_max, RateT},
                  {global_max, RateT},
                  {max_payload_external_size, SizeT},
                  {max_distinct_callers, DivT}],
    relation(collect_moves(Candidates, Limits, Envelope), Limits).

collect_moves([], _Limits, _Envelope) ->
    #{};
collect_moves([{Key, T} | Rest], Limits, Envelope) ->
    Moved = collect_moves(Rest, Limits, Envelope),
    case map_key(Key, T, Limits, Envelope) of
        skip -> Moved;
        Value -> Moved#{Key => Value}
    end.

map_key(Key, T, Limits, Envelope) ->
    case maps:get(Key, Envelope, undefined) of
        #{min := Min, max := Max} when Max > Min ->
            deadband_verdict(Key, Min, Max, T, Limits);
        _NoClamp ->
            skip
    end.

deadband_verdict(Key, Min, Max, T, Limits) ->
    Value = round(Min + T * (Max - Min)),
    Deadband = erlang:max(1, round((Max - Min) * deadband_fraction())),
    case abs(Value - maps:get(Key, Limits)) >= Deadband of
        true -> Value;
        false -> skip
    end.

%% The shared budget must never sit below the per-caller one; the
%% validation would refuse such a map, and the net has no notion of the
%% relation — enforce it here.
relation(Moved, _Limits) ->
    case {maps:find(per_caller_max, Moved), maps:find(global_max, Moved)} of
        {{ok, PerCaller}, {ok, Global}} when PerCaller > Global ->
            Moved#{per_caller_max := Global};
        _NoConflict ->
            Moved
    end.
