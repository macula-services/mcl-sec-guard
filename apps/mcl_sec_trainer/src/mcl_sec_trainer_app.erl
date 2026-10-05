%%% @doc OTP application entry for the trainer.
%%%
%%% The guardian's second OTP application (mcl-sec-guard#20,
%%% the environment): its own start module and supervisor, so it starts
%%% and stops as one unit. It is NOT a service — no release, identity,
%%% container or health of its own — and not a "library app" either: the
%%% executable artifact is the release, and this application ships inside
%%% the guardian's when in-service training is wanted (it is deliberately
%%% absent from the root relx release list until then).
%%%
%%% OFF BY DEFAULT: `{mcl_sec_trainer, enabled, false}'. Offline runs use
%%% the pure world (mcl_sec_trainer_sim) directly; no processes are needed
%%% for that. The supervisor starts no children yet — the learner arm
%%% (faber_tweann, a dependency of this application only) arrives with the
%%% in-service step, gated on `enabled'.
-module(mcl_sec_trainer_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    mcl_sec_trainer_sup:start_link().

stop(_State) ->
    ok.
