%%% @doc Tests for the placeholder decision rule (P0): the exact
%%% proposal shape the recorder writes, and the quiet-window no-op.
-module(mcl_sec_guard_proposer_rule_tests).

-include_lib("eunit/include/eunit.hrl").

an_active_window_produces_one_timid_proposal_test() ->
    Fact = #{procedure => <<"mcl-echo/echo">>, window_start_ms => 1000,
             denied_rate => 7, denied_size => 0, callers_over_limit => 3,
             global_count => 9, global_max => 6000, per_caller_max => 600},
    Proposal = mcl_sec_guard_proposer_rule:propose(Fact),
    ?assertEqual(<<"mcl-echo/echo">>, maps:get(procedure, Proposal)),
    ?assertEqual(#{per_caller_max => 3}, maps:get(proposed, Proposal)),
    ?assertEqual(unknown, maps:get(envelope, Proposal)),
    ?assert(is_binary(maps:get(reason, Proposal))),
    %% OTP 28's monotonic_time is NEGATIVE, and the wire codec refuses
    %% negative integers: decided_at_ms rides system_time wall clock,
    %% like mcl_om's window starts. A proposal must stay sendable.
    ?assert(maps:get(decided_at_ms, Proposal) >= 0).

a_quiet_window_proposes_nothing_test() ->
    Quiet = #{procedure => <<"mcl-echo/echo">>, window_start_ms => 1000,
              denied_rate => 0, denied_size => 0, callers_over_limit => 0,
              global_count => 0, global_max => 6000, per_caller_max => 600},
    ?assertEqual(none, mcl_sec_guard_proposer_rule:propose(Quiet)),
    ?assertEqual(none, mcl_sec_guard_proposer_rule:propose(#{other => shape})).

a_denied_window_with_no_over_limit_callers_proposes_the_floor_test() ->
    Fact = #{procedure => <<"p">>, window_start_ms => 1, denied_rate => 1,
             denied_size => 0, callers_over_limit => 0,
             global_count => 1, global_max => 10, per_caller_max => 10},
    ?assertEqual(#{per_caller_max => 1},
                 maps:get(proposed, mcl_sec_guard_proposer_rule:propose(Fact))).

%% The rule is the last hop of the sense loop, and the hop that broke it
%% live: the mesh delivers pubsub facts in WIRE FORM (macula_frame:to_wire/1
%% — map keys are {text, K} tuples), and the rule matched atom keys only,
%% so every denials_observed fact fell through to none (mcl-sec-guard#2).
%% The rule must read its fields whatever key form they arrived in.
the_wire_form_fact_proposes_the_same_way_test() ->
    Wire = wire_fact(#{denied_rate => 7, callers_over_limit => 3}),
    Proposal = mcl_sec_guard_proposer_rule:propose(Wire),
    ?assertEqual(<<"mcl-echo/echo">>, maps:get(procedure, Proposal)),
    ?assertEqual(#{per_caller_max => 3}, maps:get(proposed, Proposal)),
    ?assertEqual(unknown, maps:get(envelope, Proposal)).

a_quiet_wire_form_window_proposes_nothing_test() ->
    Wire = wire_fact(#{denied_rate => 0, callers_over_limit => 0}),
    ?assertEqual(none, mcl_sec_guard_proposer_rule:propose(Wire)).

%% Oversized payloads are a typical tactic — the original DoS probe
%% laddered payloads to 8 MiB. A window that saw size denials must
%% trigger the rule exactly like a rate-denied one; before this test
%% the rule watched only rate and over-limit, and a size flood was
%% invisible to the guardian.
a_size_denied_window_proposes_the_floor_test() ->
    Wire = wire_fact(#{denied_rate => 0, callers_over_limit => 0,
                       denied_size => 4}),
    Proposal = mcl_sec_guard_proposer_rule:propose(Wire),
    ?assertEqual(<<"mcl-echo/echo">>, maps:get(procedure, Proposal)),
    ?assertEqual(#{per_caller_max => 1}, maps:get(proposed, Proposal)),
    ?assertEqual(unknown, maps:get(envelope, Proposal)).

%% The exact shape a subscriber receives for one mcl-om alert fact.
wire_fact(#{denied_rate := Rate, callers_over_limit := Over,
            denied_size := Sized}) ->
    #{{text, <<"procedure">>} => <<"mcl-echo/echo">>,
      {text, <<"window_start_ms">>} => 1791148830000,
      {text, <<"denied_rate">>} => Rate,
      {text, <<"denied_size">>} => Sized,
      {text, <<"callers_over_limit">>} => Over,
      {text, <<"global_count">>} => 0,
      {text, <<"global_max">>} => 300,
      {text, <<"per_caller_max">>} => 20};
wire_fact(#{denied_rate := Rate, callers_over_limit := Over}) ->
    wire_fact(#{denied_rate => Rate, callers_over_limit => Over,
                denied_size => 0}).
