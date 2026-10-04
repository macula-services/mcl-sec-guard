%%% @doc The admin console's HTTP listener, on every interface.
%%%
%%% Deliberately NOT a separate supervisor: one ranch child under
%%% mcl_sec_guard_sup, the same shape mcl_om's own /health listener
%%% uses. No authentication — the dev-fleet posture. The port is
%%% deploy config (MCL_SEC_GUARD_ADMIN_PORT, default 8458).
-module(mcl_sec_guard_admin).

-export([start_link/0, port/0, socket_opts/0]).

start_link() ->
    ranch:start_listener(mcl_sec_guard_admin, ranch_tcp, socket_opts(),
                         cowboy_clear,
                         #{env => #{dispatch => mcl_sec_guard_admin_handler:routes()}}).

%% @doc The admin port, from the deploy environment: 8458 on beam00.
-spec port() -> inet:port_number().
port() ->
    application:get_env(mcl_sec_guard, admin_port, 8458).

%% @doc Bind every interface (0.0.0.0) — the LAN posture the fleet's
%% admin UIs carry; host networking makes a collision a silent bind
%% failure, so the port is claimed in macula-fleet PORTS.md.
-spec socket_opts() -> [{atom(), term()}].
socket_opts() ->
    [{port, port()},
     {ip, {0, 0, 0, 0}}].
