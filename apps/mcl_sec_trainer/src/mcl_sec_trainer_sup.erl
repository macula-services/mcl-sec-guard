%%% @doc mcl_sec_trainer top level supervisor.
%%%
%%% No children yet: the pure sim, scenarios and fitness modules need no
%%% processes, and the learner arm is gated on `{mcl_sec_trainer, enabled,
%%% true}' (off by default). When the arm lands, its workers start here,
%%% behind that flag.
-module(mcl_sec_trainer_sup).

-behaviour(supervisor).

-export([start_link/0]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
    ChildSpecs = [],
    {ok, {SupFlags, ChildSpecs}}.
