%%% @doc The `macula_subscriber' for the guardian's alert topic.
%%%
%%% Each `denials_observed' fact becomes a proposal from the configured
%%% proposer (the placeholder rule in P0) and one recorded line. The
%%% subscriber only ever OBSERVES: nothing here can apply a change, and
%%% nothing it reads from the mesh is treated as instruction — a fact's
%%% payload is data into the proposal seam, nothing more.
-module(mcl_sec_guard_subscriber).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

init([]) ->
    {ok, #{}}.

handle_event(_Topic, Payload, _Meta, State) ->
    Fact = fact_of(Payload),
    case mcl_sec_guard_proposer:propose(Fact) of
        none -> ok;
        Proposal -> ok = mcl_sec_guard_recorder:record(Proposal)
    end,
    {noreply, State}.

%% A fact may arrive wrapped in `#{value := V}' (the SDK's example
%% shape) or as the raw payload; accept both, refuse neither.
fact_of(#{value := Value}) -> Value;
fact_of(Fact) -> Fact.
