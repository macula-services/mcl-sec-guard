%%% @doc The fixed scenario table (mcl-sec-guard#20, rung 0).
%%%
%%% Each scenario is one deterministic, seedable population script: a
%%% list of T windows, each window a list of calls tagged with the
%%% role that made them (`legit' or `attacker') so the episode runner
%%% can compute containment and admission from ground truth — the one
%%% thing a live guard can never measure itself. The shape of each
%%% script teaches (and punishes) one failure mode:
%%%
%%% - `calm': legit only — a no-op episode; any churn is punished;
%%% - `legit_spike': a legit burst — the false-positive trap, where an
%%%   over-eager policy starves the very traffic it exists to protect;
%%% - `uniform_flood': one attacker, steady rate — the rate posture;
%%% - `bursty_flood': one attacker, on/off — recovery and spring-back;
%%% - `size_ladder': escalating payloads — the size posture;
%%% - `sybil': many ids, few calls each — the diversity bound;
%%% - `coordinated': sybil + rate + size at once — the mixed posture;
%%% - `probe_then_quiet': one probe, then nothing — no ratchet on noise
%%%   (the exact shape of the 2026-10-04/05 recorded probe session).
%%%
%%% The declared limits each scenario teaches against are the same
%%% small numbers (per_caller_max 10, global_max 100, 4 KiB payloads,
%%% 64 distinct callers) so an episode is fast and the envelope covers
%%% every key a policy may move: a guardian-tier move can tighten any
%%% key toward its floor and return it to the declared baseline, but
%%% never loosen beyond it.
-module(mcl_sec_trainer_scenarios).

-export([names/0, windows/1, windows/2, limits/1]).

-export_type([call/0, window/0, role/0]).

-type role() :: legit | attacker.
-type call() :: #{caller := binary(), payload := binary(), role := role()}.
-type window() :: [call()].

-define(T_DEFAULT, 60).
-define(PAYLOAD_LEG, 256).
-define(PAYLOAD_OVERSIZED, 8192).

%% @doc Every scenario name, in the plan's table order.
-spec names() -> [atom()].
names() ->
    [calm, legit_spike, uniform_flood, bursty_flood, size_ladder, sybil,
     coordinated, probe_then_quiet].

%% @doc The declared limits (a declare-able capability `limits' map)
%% each scenario teaches against.
-spec limits(atom()) -> map().
limits(_Name) ->
    #{max_payload_external_size => 4096,
      window_ms                 => 10000,
      per_caller_max            => 10,
      global_max                => 100,
      max_distinct_callers      => 64,
      envelope =>
          #{per_caller_max => #{min => 1, max => 10},
            global_max => #{min => 10, max => 100},
            max_payload_external_size => #{min => 1024, max => 65536},
            max_distinct_callers => #{min => 8, max => 64}}}.

%% @doc The default-length script (60 windows), seed 0.
-spec windows(atom()) -> [window()].
windows(Name) ->
    windows(Name, #{}).

%% @doc The script: `windows' windows (default 60), `seed' any integer.
-spec windows(atom(), map()) -> [window()].
windows(Name, Opts) ->
    T = maps:get(windows, Opts, ?T_DEFAULT),
    Rng = seed(maps:get(seed, Opts, 0)),
    windows_loop(Name, 0, T, Rng, []).

windows_loop(_Name, T, T, _Rng, Acc) ->
    lists:reverse(Acc);
windows_loop(Name, K, T, Rng, Acc) ->
    {Calls, Rng1} = window_calls(Name, K, Rng),
    windows_loop(Name, K + 1, T, Rng1, [Calls | Acc]).

seed(Seed) ->
    rand:seed_s(exsss, {Seed + 1, Seed + 2, Seed + 3}).

%% One window of one scenario. The legit baseline rides every window of
%% every scenario — the constant the attacker populations perturb.
window_calls(Name, K, Rng) ->
    Leg = leg_window(K, Rng),
    case {Name, K} of
        {calm, _} ->
            {Leg, Rng};
        {legit_spike, K1} when K1 >= 10, K1 =< 14 ->
            {leg_burst(12) ++ Leg, Rng};
        {legit_spike, _} ->
            {Leg, Rng};
        {uniform_flood, _} ->
            {attacker_window(<<"att-1">>, 20, leg_payload()) ++ Leg, Rng};
        {bursty_flood, K1} when (K1 >= 5 andalso K1 =< 14);
                                 (K1 >= 30 andalso K1 =< 39) ->
            {attacker_window(<<"att-1">>, 20, leg_payload()) ++ Leg, Rng};
        {bursty_flood, _} ->
            {Leg, Rng};
        {size_ladder, K1} when K1 >= 4, K1 =< 12 ->
            Step = K1 - 4,
            Payload = binary:copy(<<1>>, 1 bsl (12 + Step)),
            {[call(<<"att-1">>, Payload, attacker) | Leg], Rng};
        {size_ladder, _} ->
            {Leg, Rng};
        {sybil, K1} when K1 >= 8, K1 =< 10 ->
            Sybils = [#{caller => sybil_id(I), payload => leg_payload(),
                        role => attacker} || I <- lists:seq(1, 70)],
            {Leg ++ Sybils, Rng};
        {sybil, _} ->
            {Leg, Rng};
        {coordinated, K1} when K1 >= 10, K1 =< 20 ->
            Rate = lists:append([attacker_window(coord_id(I), 6, leg_payload())
                                 || I <- lists:seq(1, 10)]),
            Size = [call(coord_id(I), oversized_payload(), attacker)
                    || I <- [1, 2]],
            {Size ++ Rate ++ Leg, Rng};
        {coordinated, _} ->
            {Leg, Rng};
        {probe_then_quiet, 2} ->
            Probe = [call(<<"probe-1">>, oversized_payload(), attacker),
                     call(<<"probe-1">>, leg_payload(), attacker)],
            {Probe ++ quiet_leg(), Rng};
        {probe_then_quiet, _} ->
            {quiet_leg(), Rng}
    end.

%% The quietest legit presence: one call per caller per window. A probe
%% scenario needs its aftermath quiet — otherwise the legit traffic
%% itself trips the ratchet upward and the floor never shows.
quiet_leg() ->
    lists:append([leg_calls(leg_id(I), 1) || I <- lists:seq(1, 5)]).

%% The legit baseline: five known callers at a low rate. A caller's
%% count jitters by the seed (2..4 per window), so held-out seeds see
%% traffic the fixed table never produced.
leg_window(_K, Rng) ->
    {Calls, _Rng} =
        lists:mapfoldl(
          fun(I, R) ->
              {Count, R1} = rand:uniform_s(3, R),
              {leg_calls(leg_id(I), Count + 1), R1}
          end, Rng, lists:seq(1, 5)),
    lists:append(Calls).

%% The same five callers at a burst rate — a legit spike, not an attack.
leg_burst(Count) ->
    lists:append([leg_calls(leg_id(I), Count) || I <- lists:seq(1, 5)]).

leg_calls(Caller, Count) ->
    [call(Caller, leg_payload(), legit) || _ <- lists:seq(1, Count)].

leg_id(I) ->
    <<"leg-", (integer_to_binary(I))/binary>>.

attacker_window(Caller, Count, Payload) ->
    [call(Caller, Payload, attacker) || _ <- lists:seq(1, Count)].

call(Caller, Payload, Role) ->
    #{caller => Caller, payload => Payload, role => Role}.

sybil_id(I) ->
    <<"syb-", (integer_to_binary(I))/binary>>.

coord_id(I) ->
    <<"coord-", (integer_to_binary(I))/binary>>.

leg_payload() ->
    binary:copy(<<0>>, ?PAYLOAD_LEG).

oversized_payload() ->
    binary:copy(<<1>>, ?PAYLOAD_OVERSIZED).
