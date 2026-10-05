%%% @doc The guardian's admin web console.
%%%
%%% The human review surface: `/` renders the proposal log as a page
%%% (auto-refreshing, the same ~0p lines the recorder writes), and
%%% `/proposals.ndjson' serves the log raw. The trainer scoreboard
%%% (`/trainer', `/trainer.ndjson', `/trainer/episode') renders the
%%% run-set artifacts mcl_sec_trainer_reporter writes — the console is
%%% an AUDIT WINDOW, in both directions: it observes proposals and it
%%% observes the trainer's numbers, and it applies or decides nothing.
%%% It binds every interface on MCL_SEC_GUARD_ADMIN_PORT, no
%%% authentication — the dev-fleet posture mcl-tube's owner UI and the
%%% bookclub admin UIs already carry.
-module(mcl_sec_guard_admin_handler).

-export([init/2, routes/0, page/1, html_page/2]).

init(Req, State) ->
    case {cowboy_req:method(Req), cowboy_req:path(Req)} of
        {<<"GET">>, <<"/proposals.ndjson">>} -> serve_log(Req, State);
        {<<"GET">>, <<"/trainer.ndjson">>} -> serve_trainer_ndjson(Req, State);
        {<<"GET">>, <<"/trainer/episode">>} -> serve_trainer_episode(Req, State);
        {<<"GET">>, <<"/trainer">>} -> serve_trainer(Req, State);
        {<<"GET">>, <<"/">>} -> serve_page(Req, State);
        _Other -> {ok, cowboy_req:reply(404, #{}, <<"not found">>, Req), State}
    end.

%% @doc The routes for this console. `routes/0' is called at boot, so a
%% route change takes a listener restart, not a compile.
routes() ->
    cowboy_router:compile([{'_', [{"/", ?MODULE, #{}},
                                  {"/proposals.ndjson", ?MODULE, #{}},
                                  {"/trainer", ?MODULE, #{}},
                                  {"/trainer.ndjson", ?MODULE, #{}},
                                  {"/trainer/episode", ?MODULE, #{}}]}]).

serve_log(Req, State) ->
    Body = read_log(),
    Headers = #{<<"content-type">> => <<"application/x-ndjson; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>},
    {ok, cowboy_req:reply(200, Headers, Body, Req), State}.

serve_page(Req, State) ->
    Lines = read_log(),
    Body = page(Lines),
    Headers = #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>},
    {ok, cowboy_req:reply(200, Headers, Body, Req), State}.

serve_trainer(Req, State) ->
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(trainer_runs_dir()),
    Body = html_page("mcl-sec-guard - trainer scoreboard",
                     mcl_sec_guard_trainer_view:scoreboard(RunSets)),
    Headers = #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>},
    {ok, cowboy_req:reply(200, Headers, Body, Req), State}.

serve_trainer_episode(Req, State) ->
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(trainer_runs_dir()),
    Scenario = proplists:get_value(<<"scenario">>, cowboy_req:parse_qs(Req), undefined),
    Body = html_page("mcl-sec-guard - episode",
                     mcl_sec_guard_trainer_view:episode_page(RunSets, Scenario)),
    Headers = #{<<"content-type">> => <<"text/html; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>},
    {ok, cowboy_req:reply(200, Headers, Body, Req), State}.

serve_trainer_ndjson(Req, State) ->
    RunSets = mcl_sec_guard_trainer_view:read_run_sets(trainer_runs_dir()),
    Lines = [jsx:encode(Line)
             || Line <- mcl_sec_guard_trainer_view:ndjson(RunSets)],
    Body = iolist_to_binary([[L, <<"\n">>] || L <- Lines]),
    Headers = #{<<"content-type">> => <<"application/x-ndjson; charset=utf-8">>,
                <<"cache-control">> => <<"no-store">>},
    {ok, cowboy_req:reply(200, Headers, Body, Req), State}.

trainer_runs_dir() ->
    application:get_env(mcl_sec_guard, trainer_runs, "trainer_runs").

read_log() ->
    case file:read_file(mcl_sec_guard_recorder:path()) of
        {ok, Bin} -> Bin;
        {error, enoent} -> <<>>;
        {error, Reason} -> iolist_to_binary(io_lib:format("unreadable: ~p~n", [Reason]))
    end.

html_page(Title, Body) ->
    [<<"<!doctype html>\n"
       "<html><head><meta charset=\"utf-8\">\n"
       "<title>">>, Title, <<"</title></head>\n"
       "<body>\n">>, Body, <<"</body></html>\n">>].

page(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Count = length([L || L <- Lines, L =/= <<>>]),
    Body = [<<"<p>">>, integer_to_binary(Count), <<" proposals.</p>\n">>,
            <<"<pre>\n">>, Bin, <<"</pre>\n">>,
            <<"<p><a href=\"/trainer\">trainer scoreboard</a></p>\n">>],
    html_page("mcl-sec-guard - proposals", Body).
