%%% @doc The placeholder decision rule for P0 (BUILD, not CLAIM).
%%%
%%% A deterministic, obviously-small shape that exercises the full
%%% sense → propose → record loop until a model-backed proposer
%%% replaces it. The rule is deliberately timid: a window that saw
%%% denials or over-limit callers proposes lowering `per_caller_max'
%%% to the over-limit count (floor 1), and proposes nothing else, ever.
%%% Whether the proposal fits the procedure's envelope is checked at
%%% APPLY time by the service itself, so a proposal records `unknown'
%%% here — the P0 guardian never learns an envelope it does not need.
-module(mcl_sec_guard_proposer_rule).

-behaviour(mcl_sec_guard_proposer).

-export([propose/1]).

propose(#{procedure := Proc, callers_over_limit := Over, denied_rate := Denied})
  when is_binary(Proc), is_integer(Over), is_integer(Denied),
       (Over > 0 orelse Denied > 0) ->
    #{procedure => Proc,
      proposed => #{per_caller_max => max(Over, 1)},
      reason =>
          <<"placeholder rule: window saw denials; propose per_caller_max "
            "at the over-limit count">>,
      envelope => unknown,
      decided_at_ms => erlang:monotonic_time(millisecond)};
propose(_Fact) ->
    none.
