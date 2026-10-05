%%% @doc Tests for the admin console's pure pieces: the default port,
%%% the bind posture, and the proposal page rendering.
-module(mcl_sec_guard_admin_tests).

-include_lib("eunit/include/eunit.hrl").

admin_test_() ->
    [fun the_admin_binds_every_interface_by_default/0,
     fun the_page_renders_the_proposal_lines/0].

the_admin_binds_every_interface_by_default() ->
    ?assertEqual(8458, mcl_sec_guard_admin:port()),
    ?assertEqual([{port, 8458}, {ip, {0, 0, 0, 0}}],
                 mcl_sec_guard_admin:socket_opts()),
    [{'_', _Constraints, Routes}] = mcl_sec_guard_admin_handler:routes(),
    Segments = lists:sort([[S || S <- Segs] || {Segs, _C, _H, _O} <- Routes]),
    ?assertEqual(lists:sort([[], [<<"proposals.ndjson">>], [<<"trainer">>],
                             [<<"trainer.ndjson">>], [<<"trainer">>, <<"episode">>]]),
                 Segments).

the_page_renders_the_proposal_lines() ->
    Page = mcl_sec_guard_admin_handler:page(<<"#{a => 1}.\n#{b => 2}.\n">>),
    ?assert(is_list(Page)),
    ?assert(string:find(Page, "2 proposals.") =/= nomatch),
    ?assert(string:find(Page, "#{a => 1}.") =/= nomatch),
    ?assert(string:find(Page, "#{b => 2}.") =/= nomatch).
