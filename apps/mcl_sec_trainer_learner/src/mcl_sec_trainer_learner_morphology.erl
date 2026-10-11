%%% @doc The guardian's morphology for the TWEANN arm (mcl-sec-guard#20):
%%% one sensor carrying the 24-length posture vector (two windows of 12
%%% features, the order mcl_sec_trainer_features:vector/2 lays out) and
%%% one actuator carrying the three tightness scalars the action mapping
%%% reads, in the order mcl_sec_trainer_actions:moves/4 takes them.
%%%
%%% Registered by mcl_sec_trainer_learner_tweann:register/0. Nothing here
%%% runs the process-per-neuron phenotype: the arm evaluates genotypes
%%% through the DAG path (genotype_to_dag/tweann_nif), which reads the
%%% sensor and actuator records only for their slot layout.
-module(mcl_sec_trainer_learner_morphology).

-behaviour(morphology_behaviour).

-include_lib("faber_tweann/include/records.hrl").

-export([get_sensors/1, get_actuators/1]).

-define(MORPHOLOGY, guardian_posture).

-spec get_sensors(atom()) -> [#sensor{}].
get_sensors(?MORPHOLOGY) ->
    [#sensor{name = posture,
             type = standard,
             scape = {private, mcl_sec_trainer_sim},
             vl = 24,
             parameters = [],
             fanout_ids = [],
             generation = 0}];
get_sensors(_Other) ->
    error(invalid_morphology).

-spec get_actuators(atom()) -> [#actuator{}].
get_actuators(?MORPHOLOGY) ->
    [#actuator{name = tightness,
               type = standard,
               scape = {private, mcl_sec_trainer_sim},
               vl = 3,
               parameters = [],
               fanin_ids = [],
               generation = 0}];
get_actuators(_Other) ->
    error(invalid_morphology).
