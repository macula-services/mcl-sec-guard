%%% @doc The pure simulation world the trainer evolves genomes in (rung 0).
%%%
%%% A seedable, process-free re-implementation of the window arithmetic
%%% mcl_om's inbound guard enforces on every call, held to the real path
%%% by the conformance test (test/mcl_sec_trainer_conformance_tests.erl):
%%% identical traffic replayed through the real mcl_om_guard (short
%%% windows, one pool) and through this module must yield identical
%%% allow/deny verdicts, counters and stats. The SEMANTICS mirrored here,
%%% from mcl_om 0.37.6:
%%%
%%% - size stage first (cheapest refusal): a payload whose
%%%   erlang:external_size/1 exceeds `max_payload_external_size' is denied
%%%   before the rate counter ever sees it;
%%% - rate stage: one fixed-window count per (procedure, caller); the
%%%   `'$global'` bucket takes non-attributed calls, named callers take
%%%   their per-caller budget;
%%% - the distinct-caller bound: once a window has seen
%%%   `max_distinct_callers' distinct callers, a NEW caller is denied
%%%   before its bucket exists — a Sybil flood cannot grow the table
%%%   (the `'$global'` bucket takes no part in the bound, but its first
%%%   count does bump the distinct counter, exactly as the real
%%%   bucket_check does);
%%% - denial counters are PER WINDOW (`denied_rate` / `denied_size` read
%%%   zero in a quiet window) — a cumulative counter would make one
%%%   denial mark every later window denied;
%%% - limits and envelope semantics of mcl_om_guard_limits: declared base
%%%   merged over the framework defaults, runtime overrides at a tier,
%%%   guardian-tier sets clamped by the per-key envelope (never the
%%%   envelope itself), operator-tier sets anything valid;
%%% - the apply path of the set_limits capability: an applied change that
%%%   moved something records one audit entry (tier, caller, before,
%%%   after) on a bounded ring; an unchanged set is a no-op.
%%%
%%% The world is an immutable map threaded through every call — thousands
%%% of independent episodes can run concurrently, each with its own
%%% world. Windows advance by explicit index (advance/2), not by a clock:
%%% the conformance test maps the sim's window index onto the real
%%% guard's wall-clock windows one-for-one. Unlike the real guard, the
%%% sim retains old windows: the sweep the real table runs is unobservable
%%% through stats/2 or call/4 (both read the current window only), so the
%%% pure world keeps the history.
-module(mcl_sec_trainer_sim).

-export([new/0, new/1, defaults/0, declare/3, get/2, apply/4, reset/2,
         call/4, advance/2, stats/2, procedures/1, current_window/2,
         validate_limits/1, validate_envelope/1]).
-export_type([world/0, limits/0, envelope/0, verdict/0]).

-define(KEYS, [max_payload_external_size, window_ms, per_caller_max, global_max,
               max_distinct_callers]).
-define(ENVELOPE_KEY, envelope).
-define(GLOBAL_KEY, '$global').
-define(DISTINCT_KEY, '$distinct').
-define(AUDIT_RING, 32).

-type limits() :: #{max_payload_external_size := pos_integer(),
                    window_ms := pos_integer(),
                    per_caller_max := pos_integer(),
                    global_max := pos_integer(),
                    max_distinct_callers := pos_integer()}.
-type envelope() :: #{atom() => #{min := pos_integer(), max := pos_integer()}}.
-type verdict() :: allow | {deny, payload_too_large} | {deny, rate_limited}.
-type world() :: map().

%% @doc The shipped framework defaults, per procedure — the same numbers
%% mcl_om 0.37.6 ships (deliberately roomy; a capability that needs
%% tighter bounds declares its own `limits').
-spec defaults() -> limits().
defaults() ->
    #{max_payload_external_size => 65536,
      window_ms                 => 10000,
      per_caller_max            => 600,
      global_max                => 6000,
      max_distinct_callers      => 1024}.

-spec new() -> world().
new() ->
    new(#{}).

%% @doc A fresh world. Opts: `seed' (any integer, recorded for
%% reproducibility) and `defaults' (a limits map merged over
%% defaults/0, the sim's counterpart of mcl_om's effective_defaults).
-spec new(map()) -> world().
new(Opts) ->
    #{seed => maps:get(seed, Opts, 0),
      defaults => maps:merge(defaults(), maps:get(defaults, Opts, #{})),
      windows => #{},
      procs => #{},
      buckets => #{},
      distinct => #{},
      denied => #{},
      audit => #{}}.

%% @doc Register (or re-register) a procedure's declared limits and
%% envelope, from a capability map's `limits' key — mcl_om_guard_limits:
%% declare/2 semantics. A redeclare with the same base is a no-op
%% (runtime overrides survive); a different base recomputes the effective
%% limits as merge(declared', overrides). Raises
%% `{mcl_sec_trainer_bad_limits, Proc, Reason}' on a bad map, so a bad
%% declare fails loud and keeps the prior registration.
-spec declare(world(), binary(), map()) -> world().
declare(World, Proc, CapLimits) when is_map(CapLimits) ->
    Envelope = maps:get(?ENVELOPE_KEY, CapLimits, #{}),
    Declared = maps:merge(maps:get(defaults, World),
                          maps:remove(?ENVELOPE_KEY, CapLimits)),
    case {validate_limits(Declared), validate_envelope(Envelope)} of
        {ok, ok} -> declare_validated(World, Proc, Declared, Envelope);
        {{error, _} = Error, _} -> error({mcl_sec_trainer_bad_limits, Proc, Error});
        {_, {error, _} = Error} -> error({mcl_sec_trainer_bad_limits, Proc, Error})
    end;
declare(_World, Proc, NotMap) ->
    error({mcl_sec_trainer_bad_limits, Proc, {not_a_map, NotMap}}).

declare_validated(World, Proc, Declared, Envelope) ->
    Procs = maps:get(procs, World),
    case maps:get(Proc, Procs, undefined) of
        #{declared := Declared, declared_envelope := Envelope} ->
            World;
        undefined ->
            put_proc(World, Proc, new_entry(Declared, Envelope, #{}));
        #{overrides := Overrides} ->
            put_proc(World, Proc, new_entry(Declared, Envelope, Overrides))
    end.

%% @doc The effective limits and envelope of one procedure — the same
%% fallback as the real module: the framework defaults and no envelope
%% before the first declare.
-spec get(world(), binary()) -> #{limits := limits(), envelope := envelope()}.
get(World, Proc) ->
    case maps:get(Proc, maps:get(procs, World), undefined) of
        undefined -> #{limits => maps:get(defaults, World), envelope => #{}};
        #{limits := Limits, envelope := Envelope} ->
            #{limits => Limits, envelope => Envelope}
    end.

%% @doc The apply path of the `set_limits' capability (mcl_om_guard_control:
%% apply_set/4): a tiered set, and when it moved something, one audit
%% entry on the ring. Opts: `tier' (guardian | operator) and `caller'
%% (the acting identity; binaries are hex-encoded like the real ring's
%% wire_caller). Returns `{ok, World}' or the set's validation error —
%% on error nothing changes and nothing is recorded.
-spec apply(world(), binary(), map(), map()) ->
          {ok, world()} | {error, term()}.
apply(World, Proc, Overrides, Opts) ->
    Tier = maps:get(tier, Opts, guardian),
    Caller = maps:get(caller, Opts, unknown),
    Before = get(World, Proc),
    case set(World, Proc, Overrides, Tier) of
        {error, _} = Error ->
            Error;
        {ok, World1} ->
            maybe_record(World1, Proc, Tier, Caller, Before, get(World1, Proc))
    end.

%% An unchanged set is a no-op, not a change: no audit entry.
maybe_record(World, _Proc, _Tier, _Caller, Before, Before) ->
    {ok, World};
maybe_record(World, Proc, Tier, Caller, Before, After) ->
    Change = #{tier => Tier, caller => wire_caller(Caller),
               before => Before, 'after' => After},
    {ok, record(World, Proc, Change)}.

record(World, Proc, Change) ->
    Audit = maps:get(audit, World),
    Ring = maps:get(Proc, Audit, []),
    Audit1 = Audit#{Proc => lists:sublist([Change | Ring], ?AUDIT_RING)},
    World#{audit := Audit1}.

%% @doc Drop all runtime overrides and the runtime envelope: back to the
%% declared base.
-spec reset(world(), binary()) -> {ok, world()}.
reset(World, Proc) ->
    case maps:get(Proc, maps:get(procs, World), undefined) of
        undefined -> {ok, World};
        #{declared := Declared, declared_envelope := Envelope} ->
            {ok, put_proc(World, Proc, new_entry(Declared, Envelope, #{}))}
    end.

%% @doc One inbound call, run through the stages in the real pipeline's
%% order: size first (the cheapest refusal, counted in `denied_size'),
%% then the rate stage (its denials counted in `denied_rate'). The
%% verdict and the denial counters land in the CURRENT window.
-spec call(world(), binary(), binary() | '$global', term()) ->
          {verdict(), world()}.
call(World, Proc, Caller, Payload) ->
    #{limits := Limits} = get(World, Proc),
    case erlang:external_size(Payload) > maps:get(max_payload_external_size, Limits) of
        true ->
            {{deny, payload_too_large}, count_denial(World, Proc, size)};
        false ->
            allow(World, Proc, Caller, Limits)
    end.

%% mcl_om_guard:allow/3, mirrored: a caller is a distinct node id, and the
%% bucket is allocated BEFORE the rate check. Once the window has seen
%% `max_distinct_callers', a NEW caller is denied before its bucket
%% exists; callers the window already knows keep their normal per-caller
%% budget. The global bucket takes no part in the bound — but note the
%% quirk the real bucket_check carries: a '$global' first count bumps the
%% distinct counter too, and this mirrors it exactly.
allow(World, Proc, '$global' = Caller, Limits) ->
    bucket_check(World, Proc, Caller, Limits);
allow(World, Proc, Caller, Limits) ->
    Index = current_window(World, Proc),
    case maps:is_key({Proc, Caller, Index}, maps:get(buckets, World))
         orelse distinct_under_bound(World, Proc, Index, Limits) of
        true ->
            bucket_check(World, Proc, Caller, Limits);
        false ->
            {{deny, rate_limited}, count_denial(World, Proc, rate)}
    end.

distinct_under_bound(World, Proc, Index, Limits) ->
    Bound = maps:get(max_distinct_callers, Limits),
    maps:get({Proc, Index}, maps:get(distinct, World), 0) < Bound.

bucket_check(World, Proc, Caller, Limits) ->
    Index = current_window(World, Proc),
    Buckets = maps:get(buckets, World),
    Count = maps:get({Proc, Caller, Index}, Buckets, 0) + 1,
    World1 = World#{buckets := Buckets#{{Proc, Caller, Index} => Count}},
    World2 = bump_distinct(World1, Count, Proc, Index),
    Max = max_for(Caller, Limits),
    case Count =< Max of
        true ->
            {allow, World2};
        false ->
            {{deny, rate_limited}, count_denial(World2, Proc, rate)}
    end.

%% The real maybe_count_distinct/3: only the count that CREATED the
%% bucket bumps the window's distinct counter — for every caller kind,
%% '$global' included.
bump_distinct(World, 1, Proc, Index) ->
    Distinct = maps:get(distinct, World),
    Count = maps:get({Proc, Index}, Distinct, 0) + 1,
    World#{distinct := Distinct#{{Proc, Index} => Count}};
bump_distinct(World, _Count, _Proc, _Index) ->
    World.

max_for('$global', Limits) -> maps:get(global_max, Limits);
max_for(_Caller, Limits) -> maps:get(per_caller_max, Limits).

%% A per-window denial counter, keyed by the window exactly like the
%% caller buckets — a quiet window reads zero (mcl_om 0.37.6).
count_denial(World, Proc, Kind) ->
    Index = current_window(World, Proc),
    Denied = maps:get(denied, World),
    Count = maps:get({Proc, Kind, Index}, Denied, 0) + 1,
    World#{denied := Denied#{{Proc, Kind, Index} => Count}}.

%% @doc Roll the procedure into its next window: the buckets, distinct
%% count and denial counters of the new window all start empty.
-spec advance(world(), binary()) -> world().
advance(World, Proc) ->
    Windows = maps:get(windows, World),
    Index = maps:get(Proc, Windows, 0) + 1,
    World#{windows := Windows#{Proc => Index}}.

-spec current_window(world(), binary()) -> non_neg_integer().
current_window(World, Proc) ->
    maps:get(Proc, maps:get(windows, World), 0).

%% @doc A guardian-facing view of one procedure's CURRENT window — the
%% same shape mcl_om_guard:stats/1 returns: limits and envelope in
%% effect, global fill, callers over their budget, the heaviest callers
%% (hex-encoded ids, wire-safe), both per-window denial counters, and
%% the recent audit entries (newest first).
-spec stats(world(), binary()) -> map().
stats(World, Proc) ->
    #{limits := Limits, envelope := Envelope} = get(World, Proc),
    maps:merge(counters(World, Proc, Limits),
               #{limits => Limits, envelope => Envelope,
                 global_max => maps:get(global_max, Limits),
                 audit => maps:get(Proc, maps:get(audit, World), [])}).

counters(World, Proc, Limits) ->
    Index = current_window(World, Proc),
    {GlobalCount, Callers} = current_window_counts(World, Proc, Index),
    PerCallerMax = maps:get(per_caller_max, Limits),
    OverLimit = [Caller || {Caller, Count} <- Callers, Count > PerCallerMax],
    Sorted = lists:reverse(lists:keysort(2, Callers)),
    TopCallers = [#{caller => binary:encode_hex(Caller, lowercase), count => Count}
                  || {Caller, Count} <- lists:sublist(Sorted, 10)],
    #{current_window => Index,
      global_count => GlobalCount,
      distinct_callers => length(Callers),
      callers_over_limit => length(OverLimit),
      top_callers => TopCallers,
      denied_rate => denied(World, Proc, rate, Index),
      denied_size => denied(World, Proc, size, Index)}.

%% The real fold: the '$global' bucket is the global fill; the distinct
%% marker is not a caller; everything else is a caller bucket.
current_window_counts(World, Proc, Index) ->
    maps:fold(
      fun({P, '$global', W}, Count, {Global, Callers}) when P =:= Proc, W =:= Index ->
              {Global + Count, Callers};
         ({P, Caller, W}, Count, {Global, Callers})
           when P =:= Proc, W =:= Index, Caller =/= '$distinct' ->
              {Global, [{Caller, Count} | Callers]};
         (_Entry, _Count, Acc) ->
              Acc
      end, {0, []}, maps:get(buckets, World)).

denied(World, Proc, Kind, Index) ->
    maps:get({Proc, Kind, Index}, maps:get(denied, World), 0).

%% @doc Every declared procedure.
-spec procedures(world()) -> [binary()].
procedures(World) ->
    maps:keys(maps:get(procs, World)).

%% ---- the set path: mcl_om_guard_limits:set/3, mirrored ----

set(World, Proc, Overrides, Tier) when is_map(Overrides) ->
    case maps:get(Proc, maps:get(procs, World), undefined) of
        undefined -> {error, {unknown_procedure, Proc}};
        Entry -> do_set(World, Proc, Entry, Overrides, Tier)
    end;
set(_World, _Proc, NotMap, _Tier) ->
    {error, {not_a_map, NotMap}}.

do_set(World, Proc, Entry, Request, guardian) ->
    case maps:is_key(?ENVELOPE_KEY, Request) of
        true ->
            {error, envelope_operator_only};
        false ->
            guardian_set(World, Proc, Entry, Request)
    end;
do_set(World, Proc, Entry, Request, operator) ->
    operator_set(World, Proc, Entry, Request).

guardian_set(World, Proc, #{declared := Declared, declared_envelope := DeclaredEnvelope,
                            overrides := Overrides} = Entry, Request) ->
    case {validate_limits_keys(Request), within_envelope(Request, Entry)} of
        {ok, ok} ->
            apply_and_put(World, Proc, Declared, DeclaredEnvelope,
                          maps:merge(Overrides, Request), DeclaredEnvelope);
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

operator_set(World, Proc, #{declared := Declared, declared_envelope := DeclaredEnvelope,
                            overrides := Overrides}, Request) ->
    LimitsPart = maps:remove(?ENVELOPE_KEY, Request),
    NewEnvelope = maps:get(?ENVELOPE_KEY, Request, undefined),
    case {validate_limits_keys(LimitsPart), validate_new_envelope(NewEnvelope)} of
        {ok, ok} ->
            apply_and_put(World, Proc, Declared, DeclaredEnvelope,
                          maps:merge(Overrides, LimitsPart),
                          envelope_or(NewEnvelope, DeclaredEnvelope));
        {{error, _} = Error, _} -> Error;
        {_, {error, _} = Error} -> Error
    end.

apply_and_put(World, Proc, Declared, DeclaredEnvelope, Overrides, Envelope) ->
    NewLimits = maps:merge(Declared, Overrides),
    case validate_limits(NewLimits) of
        {error, _} = Error ->
            Error;
        ok ->
            Entry = #{declared => Declared, declared_envelope => DeclaredEnvelope,
                      overrides => Overrides, envelope => Envelope,
                      limits => NewLimits},
            {ok, put_proc(World, Proc, Entry)}
    end.

envelope_or(undefined, DeclaredEnvelope) -> DeclaredEnvelope;
envelope_or(Envelope, _DeclaredEnvelope) -> Envelope.

validate_new_envelope(undefined) -> ok;
validate_new_envelope(Envelope) -> validate_envelope(Envelope).

%% A guardian-tier set: every key it changes must sit inside the
%% envelope's clamp for that key. A key the envelope does not cover
%% cannot be moved by the guardian at all.
within_envelope(Request, #{envelope := Envelope}) ->
    Fold = fun(Key, Value, Acc) -> envelope_verdict(Key, Value, Envelope, Acc) end,
    maps:fold(Fold, ok, Request).

envelope_verdict(_Key, _Value, _Envelope, {error, _} = Error) ->
    Error;
envelope_verdict(Key, Value, Envelope, ok) ->
    case maps:get(Key, Envelope, undefined) of
        #{min := Min, max := Max} when Min =< Value, Value =< Max ->
            ok;
        _ClampOrMissing ->
            {error, {envelope_exceeded, Key, Value}}
    end.

%% @doc Full-map validation: known keys, positive integers, and the
%% per-caller budget at most the shared one — the same rules the real
%% guard boots against.
-spec validate_limits(map()) -> ok | {error, term()}.
validate_limits(Map) when is_map(Map) ->
    case validate_entries(maps:to_list(Map)) of
        ok -> validate_relation(Map);
        {error, _} = Error -> Error
    end;
validate_limits(NotMap) ->
    {error, {not_a_map, NotMap}}.

%% @doc Envelope validation: every clamp names a limit key, and carries
%% positive `min' and `max' integers, min not above max.
-spec validate_envelope(map()) -> ok | {error, term()}.
validate_envelope(Envelope) when is_map(Envelope) ->
    validate_envelope_entries(maps:to_list(Envelope));
validate_envelope(NotMap) ->
    {error, {not_a_map, NotMap}}.

validate_envelope_entries([]) ->
    ok;
validate_envelope_entries([{Key, Clamp} | Rest]) ->
    case lists:member(Key, ?KEYS) of
        false -> {error, {unknown_key, Key}};
        true -> validate_clamp(Key, Clamp, Rest)
    end.

validate_clamp(_Key, #{min := Min, max := Max}, Rest)
  when is_integer(Min), Min > 0, is_integer(Max), Max > 0, Min =< Max ->
    validate_envelope_entries(Rest);
validate_clamp(Key, Clamp, _Rest) ->
    {error, {bad_envelope_clamp, Key, Clamp}}.

validate_limits_keys(Map) ->
    validate_entries(maps:to_list(Map)).

validate_entries([]) ->
    ok;
validate_entries([{Key, Value} | Rest]) ->
    case lists:member(Key, ?KEYS) of
        false -> {error, {unknown_key, Key}};
        true -> validate_entry_value(Key, Value, Rest)
    end.

validate_entry_value(_Key, Value, Rest) when is_integer(Value), Value > 0 ->
    validate_entries(Rest);
validate_entry_value(Key, Value, _Rest) ->
    {error, {not_a_positive_integer, Key, Value}}.

validate_relation(#{per_caller_max := PerCaller, global_max := Global})
  when PerCaller > Global ->
    {error, {per_caller_above_global, PerCaller, Global}};
validate_relation(_Limits) ->
    ok.

new_entry(Declared, Envelope, Overrides) ->
    #{declared => Declared, declared_envelope => Envelope,
      overrides => Overrides, envelope => Envelope,
      limits => maps:merge(Declared, Overrides)}.

put_proc(World, Proc, Entry) ->
    Procs = maps:get(procs, World),
    World#{procs := Procs#{Proc => Entry}}.

%% Caller ids ride the wire as text, which must be valid UTF-8: hex —
%% the same wire_caller the real audit ring applies.
wire_caller(Caller) when is_binary(Caller) ->
    binary:encode_hex(Caller, lowercase);
wire_caller(Other) ->
    Other.
