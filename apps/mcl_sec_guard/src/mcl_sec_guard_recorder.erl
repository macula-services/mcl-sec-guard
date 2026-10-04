%%% @doc Append-only proposal log for P0: one human-readable line per
%%% proposal, written synchronously through this gen_server so lines
%%% never interleave.
%%%
%%% This is the READABLE trail the P0 phase needs a human to review —
%%% NOT the tamper-evident event stream the register's `Security audit
%%% log' row owes. That stream is the guardian's own store, decided at
%%% P1; P0 deliberately stays storeless.
-module(mcl_sec_guard_recorder).

-behaviour(gen_server).

-export([start_link/0, record/1, path/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {dev}).

%% @doc Where proposals land: `{mcl_sec_guard, proposal_log}' app env,
%% default a relative `proposals.log'.
-spec path() -> file:name_all().
path() ->
    application:get_env(mcl_sec_guard, proposal_log, "proposals.log").

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    %% Crash loud on an unwritable log: a guardian that silently drops
    %% its own proposals would look alive and record nothing.
    {ok, Dev} = file:open(path(), [append]),
    {ok, #state{dev = Dev}}.

-spec record(map()) -> ok.
record(Proposal) ->
    gen_server:call(?MODULE, {record, Proposal}, 5000).

handle_call({record, Proposal}, _From, #state{dev = Dev} = State) ->
    ok = file:write(Dev, io_lib:format("~0p.~n", [Proposal])),
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, #state{dev = Dev}) ->
    _ = file:close(Dev),
    ok.
