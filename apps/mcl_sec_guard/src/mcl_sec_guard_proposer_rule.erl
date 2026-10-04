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

propose(Fact) when is_map(Fact) ->
    case {field(Fact, <<"procedure">>),
          field(Fact, <<"callers_over_limit">>),
          field(Fact, <<"denied_rate">>)} of
        {Proc, Over, Denied}
          when is_binary(Proc), is_integer(Over), is_integer(Denied),
               (Over > 0 orelse Denied > 0) ->
            #{procedure => Proc,
              proposed => #{per_caller_max => max(Over, 1)},
              reason =>
                  <<"placeholder rule: window saw denials; propose per_caller_max "
                    "at the over-limit count">>,
              envelope => unknown,
              %% WALL CLOCK, deliberately: OTP 28's monotonic_time is
              %% signed — negative — and the wire codec refuses negative
              %% integers (mcl_om's window starts use system_time for the
              %% same reason). A proposal must stay sendable for P1.
              decided_at_ms => erlang:system_time(millisecond)};
        _ ->
            none
    end;
propose(_Fact) ->
    none.

%% A field, read whatever key form it arrived in: the binary key (the
%% subscriber normalizes to it), the atom key (direct calls), or the
%% wire form's {text, Name}. The rule matched atoms only, and the mesh
%% delivers wire form — every fact fell through to none (mcl-sec-guard#2).
field(Fact, Name) ->
    Atom = try binary_to_existing_atom(Name, utf8)
           catch error:badarg -> nope
           end,
    first_present([Name, Atom, {text, Name}], Fact).

first_present([], _Fact) ->
    undefined;
first_present([Key | Rest], Fact) ->
    case maps:find(Key, Fact) of
        {ok, Value} -> Value;
        error -> first_present(Rest, Fact)
    end.
