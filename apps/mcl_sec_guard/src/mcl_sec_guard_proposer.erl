%%% @doc The decision seam: propose/1 turns one observed fact into a
%%% proposal, or `none'.
%%%
%%% P0 ships a deterministic placeholder rule behind this behaviour;
%%% the model-backed proposer replaces it when the loop is proven. A
%%% proposal is DATA ONLY — the P0 guardian applies nothing, and even
%%% in P1 the apply path is the service's own gated limits.set, never
%%% anything this module returns.
-module(mcl_sec_guard_proposer).

-export([propose/1]).
-export_type([proposal/0]).

-callback propose(Fact :: map()) -> proposal() | none.

-type proposal() :: #{procedure := binary(),
                      proposed := map(),
                      reason := binary(),
                      envelope := checked | unknown,
                      decided_at_ms := pos_integer()}.

-spec propose(map()) -> proposal() | none.
propose(Fact) ->
    Mod = application:get_env(mcl_sec_guard, proposer, mcl_sec_guard_proposer_rule),
    Mod:propose(Fact).
