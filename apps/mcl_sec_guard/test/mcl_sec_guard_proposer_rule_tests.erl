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
    ?assert(is_integer(maps:get(decided_at_ms, Proposal))).

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
