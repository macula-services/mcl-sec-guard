%% @doc Supervises this service's own processes.
%%
%% ONE CHILD IN P0: the proposal recorder. The alert subscription is NOT
%% here — mcl_om_pubsub_sup supervises one macula_subscriber per declared
%% {Topic, HandlerMod, Args}, so a lost subscription is mcl-om's to
%% restart, not ours.
-module(mcl_sec_guard_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => mcl_sec_guard_recorder,
          start => {mcl_sec_guard_recorder, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker}
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
