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

handle_event(_Topic, Payload, Meta, State) ->
    Fact = fact_of(Payload),
    case mcl_sec_guard_proposer:propose(Fact) of
        none -> ok;
        Proposal -> ok = mcl_sec_guard_recorder:record(with_provenance(Proposal, Meta))
    end,
    {noreply, State}.

%% The delivery metadata names the verified publisher: which node's
%% pipeline published the fact, when, and its per-publisher sequence.
%% The mesh only delivers verified publications, so this identity rides
%% the signature. P0 records it so a human reviewer (and P1's
%% approve/reject) knows WHO reported the window. Node ids are
%% arbitrary bytes, not valid UTF-8: hex-encode for the wire.
with_provenance(Proposal, Meta) ->
    Proposal#{publisher => publisher_hex(maps:get(publisher, Meta, unknown)),
              published_at_ms => maps:get(published_at, Meta, unknown),
              seq => maps:get(seq, Meta, unknown)}.

publisher_hex(Publisher) when is_binary(Publisher) ->
    binary:encode_hex(Publisher, lowercase);
publisher_hex(_) ->
    unknown.

%% A fact may arrive wrapped in `#{value := V}' (the SDK's example
%% shape) or as the raw payload; accept both, refuse neither. Either
%% way the payload is in WIRE FORM (macula_frame:to_wire/1): map keys
%% are {text, K} tuples, atom values are {text, V}, undefined is null.
%% Normalize to the decoded shape — binary keys, plain values — before
%% the proposer sees it: matching atom keys on the wire form silently
%% discarded every fact live (mcl-sec-guard#2). macula 13.5.0 carries
%% macula_record:decode_payload/1 for exactly this (macula-io/macula#61).
fact_of(#{value := Value}) -> macula_record:decode_payload(Value);
fact_of(Fact) -> macula_record:decode_payload(Fact).
