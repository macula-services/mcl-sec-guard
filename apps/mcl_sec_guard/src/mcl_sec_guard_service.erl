%% @doc The mcl_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.
%%
%% IT ANNOUNCES NOTHING AND ASKS FOR NOTHING, on purpose. A service that does
%% nothing yet has no capability to offer and needs no authority from the realm.
%% Advertising a capability before it exists puts a lie on the mesh that another
%% service can find and call. Both lists grow when the thing they name exists,
%% and a generated test fails when they change, so growing them is a deliberate
%% act rather than a comment someone forgot.
-module(mcl_sec_guard_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0,
         subscriptions/0]).

info() ->
    #{name => <<"mcl-sec-guard">>,
      version => <<"0.1.0">>,
      description => <<"The security guardian, P0 shadow: observes denial facts and records proposals; applies nothing">>}.

start(_Opts) -> mcl_sec_guard_sup:start_link().

stop(_State) -> ok.

%% Green once the supervision tree is up. Replace this with a real probe of
%% whatever this service needs in order to do its job. A dark mesh is usually NOT
%% a health failure: decide that deliberately rather than by default.
health() -> ok.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. Other services find this one by these
%% names, so each entry is a promise that something answers.
capabilities() -> [].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"mcl-sec-guard">>,
      actions => [],
      resources => [],
      ttl_days => 30}.

%% P0 SENSING: subscribe to the alert topic every guarded service
%% publishes one `denials_observed' fact on per window with activity
%% (mcl-om#13). One supervised macula_subscriber per declared topic —
%% the subscriber hands each fact to the proposer, the recorder writes
%% the proposal, and nothing is applied. Reading is not an action, so
%% this matches identity_spec/0's empty actions: a popped guardian gains
%% a reader of public denial facts and nothing more.
subscriptions() ->
    [{alert_topic(), mcl_sec_guard_subscriber, []}].

alert_topic() ->
    application:get_env(mcl_sec_guard, alert_topic, <<"denials_observed">>).
