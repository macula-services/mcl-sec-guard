#!/usr/bin/env bash
# Runs one learner arm for the autonomous-guardian plan (mcl-sec-guard#20)
# against the same fitness and budget, and writes its result as terms:
#
#   scripts/evolve_guardian.sh <baseline|tweann> [generations] [population] [out dir]
#
#   <out>/baseline.result.term     the evolve result + champion report
#   <out>/tweann.result.term       the evolve result + champion report + DAG
#   <out>/tweann.champion.dag.txt  the champion's DAG, the artifact
#                                  distillation starts from
#
# Budget: both arms default to 200 generations. The baseline's lambda is
# sep_cma_es's own (21 at 339 parameters); the TWEANN population is set to
# match it, so each arm spends 4200 suite evaluations. Seeds: the baseline
# seeds the process generator with {0, 1, 2} before evolve (faber's ES
# optimisers draw from it); the TWEANN arms seeds its own parent draws the
# same way and genotype construction/mutation through genotype_rand:seed/1,
# both from seed 0.
#
# Run from anywhere inside the repository, with an OTP 28.4.x toolchain on
# PATH and the environment prepared as the CI image is: FABER_TWEANN_SKIP_NIF=1
# (the script sets it for the compile and the run).
set -euo pipefail

arm=${1:?usage: evolve_guardian.sh <baseline|tweann> [generations] [population] [out dir]}
generations=${2:-200}
population=${3:-21}
out=${4:-results}

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
libs=$(echo _build/default/lib/*/ebin)

export FABER_TWEANN_SKIP_NIF=1
rebar3 compile >/dev/null

case "$arm" in
  baseline)
    erl -noshell -pa $libs -eval "
      _ = rand:seed(exsss, {0, 1, 2}),
      R = mcl_sec_trainer_learner:evolve(#{max_generations => $generations}),
      Rep = mcl_sec_trainer_genome:champion_report(maps:get(best, R)),
      ok = file:write_file(\"$out/baseline.result.term\", term_to_binary({R, Rep})),
      S = maps:get(summary, Rep),
      io:format(\"baseline: mean=~p gate_failures=~p episodes=~p~n\",
                [maps:get(mean_fitness, S), maps:get(gate_failures, S),
                 maps:get(episodes, S)]),
      halt(0)."
    ;;
  tweann)
    erl -noshell -pa $libs -eval "
      R = mcl_sec_trainer_learner_tweann:evolve(
            #{population => $population, generations => $generations, seed => 0}),
      Rep = maps:get(champion, R),
      {ok, Dag} = mcl_sec_trainer_learner_tweann:dag(maps:get(best_agent, R)),
      ok = file:write_file(\"$out/tweann.result.term\", term_to_binary({R, Rep, Dag})),
      ok = file:write_file(\"$out/tweann.champion.dag.txt\",
                           io_lib:format(\"~p.~n\", [Dag])),
      S = maps:get(summary, Rep),
      io:format(\"tweann: mean=~p gate_failures=~p episodes=~p topology=~p~n\",
                [maps:get(mean_fitness, S), maps:get(gate_failures, S),
                 maps:get(episodes, S), maps:get(topology, Rep)]),
      halt(0)."
    ;;
  *)
    echo "evolve_guardian.sh: unknown arm '$arm' (baseline|tweann)" >&2
    exit 2
    ;;
esac
