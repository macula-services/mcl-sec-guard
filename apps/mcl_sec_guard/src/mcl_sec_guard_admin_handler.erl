%%% @doc The guardian's admin web console, P0 read-only.
%%%
%%% The human review surface for the shadow phase: `/` renders the
%%% proposal log as a page (auto-refreshing, the same ~0p lines the
%%% recorder writes), and `/proposals.ndjson' serves the log raw. It
%%% binds every interface on MCL_SEC_GUARD_ADMIN_PORT, no
%%% authentication — the dev-fleet posture mcl-tube's owner UI and the
%%% bookclub admin UIs already carry. P1 adds approve/reject, which
%%% turns a proposal into a real set_limits call BY THE GUARDIAN (the
%%% UI itself never touches a service).
-module(mcl_sec_guard_admin_handler).

-export([init/2, routes/0, page/1]).

init(Req, State) ->
    case {cowboy_req:method(Req), cowboy_req:path(Req)} of
        {<<"GET">>, <<"/proposals.ndjson">>} -> serve_log(Req, State);
        {<<"GET">>, <<"/">>} -> serve_page(Req, State);
        _Other -> {ok, cowboy_req:reply(404, #{}, <<"not found">>, Req), State}
    end.

%% @doc The routes for this console. `routes/0' is called at boot, so a
%% route change takes a listener restart, not a compile.
routes() ->
    cowboy_router:compile([{'_', [{"/", ?MODULE, #{}},
                                  {"/proposals.ndjson", ?MODULE, #{}}]}]).

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

read_log() ->
    case file:read_file(mcl_sec_guard_recorder:path()) of
        {ok, Bin} -> Bin;
        {error, enoent} -> <<>>;
        {error, Reason} -> iolist_to_binary(io_lib:format("unreadable: ~p~n", [Reason]))
    end.

page(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    Count = length([L || L <- Lines, L =/= <<>>]),
    Body = [<<"<p>">>, integer_to_binary(Count), <<" proposals.</p>\n">>,
            <<"<pre>\n">>, Bin, <<"</pre>\n">>],
    [<<"<!doctype html>\n"
       "<html><head><meta charset=\"utf-8\">\n"
       "<meta http-equiv=\"refresh\" content=\"5\">\n"
       "<title>mcl-sec-guard — proposals</title></head>\n"
       "<body><h1>mcl-sec-guard — proposal log (P0 shadow)</h1>\n">>,
     Body,
     <<"</body></html>\n">>].
