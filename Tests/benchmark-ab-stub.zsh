#!/bin/zsh
set -euo pipefail

: ${BENCHMARK_ARGV_LOG:?BENCHMARK_ARGV_LOG must name the argv log}

typeset -A seen_options=()
for token in "$@"; do
  if [[ $token == --* ]]; then
    key=${token#--}
    if (( ${+seen_options[$key]} )); then
      print -u2 "duplicate option --$key"
      exit 2
    fi
    seen_options[$key]=1
  fi
done

jq -cn --args '$ARGS.positional' -- "$@" >> "$BENCHMARK_ARGV_LOG"

stats_file=
for (( position = 1; position <= $#; position++ )); do
  if [[ ${argv[$position]} == --stats-file ]]; then
    if (( position == $# )); then
      print -u2 'missing --stats-file value'
      exit 2
    fi
    stats_file=${argv[$position + 1]}
    break
  fi
done
if [[ -z $stats_file ]]; then
  print -u2 'missing --stats-file'
  exit 2
fi
print -r -- '{"event":"stub"}' > "$stats_file"

print -r -- '{
  "datasetBuildSeconds": 10,
  "datasetBuildGPUSeconds": 8,
  "datasetWork": {
    "prefetchBuildWallSeconds": 6,
    "prefetchBuildGPUSeconds": 5,
    "buildCommandWallSeconds": 7,
    "buildCommandGPUSeconds": 6,
    "searchCommandWallSeconds": 40,
    "searchCommandGPUSeconds": 32
  },
  "effectiveHashrate": 90,
  "averageHashrate": 100,
  "searchSeconds": 30,
  "startedAt": "2026-01-01T00:00:00Z",
  "sampledAt": "2026-01-01T00:01:00Z",
  "nonces": 6000,
  "socTemperatureSessionPeakCelsius": 70,
  "datasetActivations": 2,
  "datasetPrefetchWaits": 3
}'
