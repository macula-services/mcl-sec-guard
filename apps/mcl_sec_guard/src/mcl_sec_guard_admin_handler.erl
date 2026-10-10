%%% @doc The guardian's admin web console.
%%%
%%% The human review surface: `/` renders the proposal log as a page
%%% (auto-refreshing, the same ~0p lines the recorder writes), and
%%% `/proposals.ndjson' serves the log raw. The trainer scoreboard
%%% (`/trainer', `/trainer.ndjson', `/trainer/episode') renders the
%%% run-set artifacts mcl_sec_trainer_reporter writes — the console is
%%% an AUDIT WINDOW, in both directions: it observes proposals and it
%%% observes the trainer's numbers, and it applies or decides nothing.
%%%
%%% `POST /api/trainer/run' (mcl-sec-guard#15) is the window's one
%%% write: it runs an evaluation (the baseline suite, or one genome the
%%% body carries) through `mcl_sec_guard_trainer_api' and redirects to
%%% `/trainer' where the new run set is the latest row. It applies
%%% nothing; the wire half (this module) parses the JSON body and maps
%%% the api's typed errors to 400s, a run in flight to 409.
%%%
%%% It binds every interface on MCL_SEC_GUARD_ADMIN_PORT, no
%%% authentication — the dev-fleet posture mcl-tube's owner UI and the
%%% bookclub admin UIs already carry.
-module(mcl_sec_guard_admin_handler).

-export([init/2, routes/0, page/1, html_page/2, trainer_run_response/1]).

init(Req, State) ->
    case {cowboy_req:method(Req), cowboy_req:path(Req)} of
        {<<"POST">>, <<"/api/trainer/run">>} -> serve_trainer_run(Req, State);
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
                                  {"/trainer/episode", ?MODULE, #{}},
                                  {"/api/trainer/run", ?MODULE, #{}}]}]).

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

%% The one write endpoint (mcl-sec-guard#15): run the requested
%% evaluation, then send the browser to the scoreboard. The body is
%% read with a small cap — the largest legitimate body is a 339-float
%% genome (~8 KB); anything bigger is refused unread.
serve_trainer_run(Req, State) ->
    case read_small_body(Req) of
        {ok, Body, Req2} ->
            {Status, Headers, ResponseBody} = trainer_run_response(Body),
            {ok, cowboy_req:reply(Status, Headers, ResponseBody, Req2), State};
        {too_large, Req2} ->
            {ok, cowboy_req:reply(413, text_headers(), <<"body too large\n">>, Req2), State}
    end.

read_small_body(Req) ->
    case cowboy_req:read_body(Req, #{length => 65536}) of
        {ok, Body, Req2} -> {ok, Body, Req2};
        {more, _Partial, Req2} -> {too_large, Req2}
    end.

%% @doc The `POST /api/trainer/run' decision, pure: the body bytes in,
%% the reply out. `serve_trainer_run/2' owns the cowboy side (reading
%% and replying); the console's tests exercise this directly.
-spec trainer_run_response(binary()) -> {integer(), map(), binary()}.
trainer_run_response(<<>>) ->
    respond(mcl_sec_guard_trainer_api:run(#{}));
trainer_run_response(Body) ->
    case decode_params(Body) of
        {ok, Params} -> respond(mcl_sec_guard_trainer_api:run(Params));
        {error, Reason} -> {400, text_headers(), reason_text(Reason)}
    end.

respond({ok, _Meta}) -> {303, #{<<"location">> => <<"/trainer">>}, <<>>};
respond({error, run_in_progress}) -> {409, text_headers(), reason_text(run_in_progress)};
respond({error, Reason}) -> {400, text_headers(), reason_text(Reason)}.

decode_params(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Params when is_map(Params) -> {ok, api_params(Params)};
        _NotAnObject -> {error, {malformed_params, not_an_object}}
    catch
        _:_ -> {error, malformed_json}
    end.

%% JSON object keys are binaries; the api's shapes are atoms. Only the
%% documented shapes are translated, and only when nothing else rides
%% along; anything else keeps its raw keys, so the api refuses it as
%% malformed rather than reading an unexpected shape as a valid one.
api_params(#{<<"run">> := Run} = Params) when map_size(Params) =:= 1 ->
    #{run => Run};
api_params(#{<<"genome">> := Genome} = Params) when map_size(Params) =:= 1 ->
    #{genome => Genome};
api_params(Params) ->
    Params.

text_headers() ->
    #{<<"content-type">> => <<"text/plain; charset=utf-8">>,
      <<"cache-control">> => <<"no-store">>}.

reason_text(run_in_progress) ->
    <<"a run is already in progress\n">>;
reason_text(malformed_json) ->
    <<"malformed JSON body\n">>;
reason_text({malformed_params, not_an_object}) ->
    <<"malformed params: the body must be a JSON object\n">>;
reason_text({malformed_params, _Seen}) ->
    <<"unknown request shape: {}, \"run\":\"baseline\" or \"genome\":[numbers]\n">>;
reason_text({malformed_genome, not_a_list}) ->
    <<"malformed genome: not an array\n">>;
reason_text({malformed_genome, {bad_length, Got, Want}}) ->
    iolist_to_binary(io_lib:format("malformed genome: ~b values, expected ~b\n", [Got, Want]));
reason_text({malformed_genome, {bad_element, Bad}}) ->
    iolist_to_binary(io_lib:format("malformed genome: ~p is not a number\n", [Bad]));
reason_text({run_set_not_written, Reason}) ->
    iolist_to_binary(io_lib:format("the run set was not written: ~p\n", [Reason]));
reason_text(Reason) ->
    iolist_to_binary(io_lib:format("~p\n", [Reason])).

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
