%%% @doc The distilled fixed-shape evaluator: a small feedforward over
%%% the observation vector — 24 inputs (two windows x 12 features), one
%%% tanh hidden layer of 12, three sigmoid outputs (the posture
%%% tightness scalars the actions map). The WEIGHTS are a flat vector;
%%% sep_cma_es evolves the vector and nothing else.
%%%
%%% This module is the shape mcl-om's minimal evaluator will run
%%% dependency-free: plain Erlang math and faber's activation functions
%%% (the one faber import), no morphology, no engine. A genome is a
%%% flat vector of length param_count/0; layout: W1 (24x12 row-major),
%%% B1 (12), W2 (12x3), B2 (3).
-module(mcl_sec_trainer_policy_net).

-export([param_count/0, output/2]).

-define(INPUTS, 24).
-define(HIDDEN, 12).
-define(OUTPUTS, 3).
-define(PARAM_COUNT,
        (?INPUTS * ?HIDDEN + ?HIDDEN + ?HIDDEN * ?OUTPUTS + ?OUTPUTS)).

-spec param_count() -> pos_integer().
param_count() ->
    ?PARAM_COUNT.

%% @doc Evaluate the fixed shape. Inputs: the 24-length feature vector;
%% outputs: three floats in (0, 1) — rate, size, diversity tightness.
-spec output([float()], [float()]) -> [float()].
output(Vector, Inputs)
  when length(Vector) =:= ?PARAM_COUNT, length(Inputs) =:= ?INPUTS ->
    {Hidden, Rest} = dense(Vector, ?INPUTS, ?HIDDEN, Inputs, fun functions:tanh/1),
    {Out, _Rest} = dense(Rest, ?HIDDEN, ?OUTPUTS, Hidden, fun functions:sigmoid/1),
    Out.

dense(Vector, In, Out, X, Activation) ->
    WSize = In * Out,
    W = lists:sublist(Vector, WSize),
    B = lists:sublist(lists:nthtail(WSize, Vector), Out),
    Rest = lists:nthtail(WSize + Out, Vector),
    Y = [Activation(dot(In, W, B, I, X)) || I <- lists:seq(1, Out)],
    {Y, Rest}.

dot(In, W, B, I, X) ->
    Sum = lists:sum([lists:nth((I - 1) * In + J, W) * lists:nth(J, X)
                     || J <- lists:seq(1, In)]),
    Sum + lists:nth(I, B).
