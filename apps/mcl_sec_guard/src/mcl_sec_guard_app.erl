%% @doc OTP application entry.
%%
%% mcl_om:boot/1 wires the mesh, the realm identity and health, then starts
%% this service. It opens NO store and starts no reckon-db or evoq application:
%% persistence is each service's own choice (mcl_om 0.35.0, mcl-om#10).
%%
%% STORELESS as generated. To give this service an event store, scaffold with
%% `store=1' and compare: the service then declares its own store dependencies
%% and this module opens the store before mcl_om:boot/1.
-module(mcl_sec_guard_app).

-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) -> mcl_om:boot(mcl_sec_guard_service).
stop(_State) -> ok.
