#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 'Usage: benchmark-ab.zsh OUTPUT_DIR RUNS NAME:ARGUMENTS [NAME:ARGUMENTS ...]'
  print -u2 "Example: $0 /tmp/ergometal-ab 3 'overlap:--dataset-scheduling overlap' 'serialized:--dataset-scheduling serialized'"
  print -u2 'Environment: BINARY, DURATION, HEIGHT, HEIGHT_INTERVAL, TABLE_SIZE, COOLDOWN_SECONDS'
}

if (( $# < 4 )); then
  usage
  exit 2
fi

output_dir=$1
runs=$2
shift 2
variants=("$@")

if [[ $runs != <-> ]] || (( runs < 1 )); then
  print -u2 'RUNS must be a positive integer'
  exit 2
fi

binary=${BINARY:-DerivedData/Build/Products/Release/ergometal}
duration=${DURATION:-30}
height=${HEIGHT:-1841500}
height_interval=${HEIGHT_INTERVAL:-0}
table_size=${TABLE_SIZE:-}
cooldown=${COOLDOWN_SECONDS:-0}

typeset -A variant_names
for specification in "${variants[@]}"; do
  name=${specification%%:*}
  arguments=${specification#*:}
  if [[ -z $name || $arguments == $specification ]]; then
    print -u2 "Invalid variant '$specification'; expected NAME:ARGUMENTS"
    exit 2
  fi
  if [[ -n ${name//[A-Za-z0-9._-]/} ]]; then
    print -u2 "Invalid variant name '$name'; use letters, digits, dot, underscore, or hyphen"
    exit 2
  fi
  if (( ${+variant_names[$name]} )); then
    print -u2 "Duplicate variant name '$name'"
    exit 2
  fi
  variant_names[$name]=1
done

for command in "$binary" jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    print -u2 "Required command not found: $command"
    exit 2
  fi
done

mkdir -p "$output_dir"
results="$output_dir/results.jsonl"
: > "$results"

common=(
  benchmark
  --duration "$duration"
  --height "$height"
  --profile peak
  --prebuild on
  --batch-nonces 1048576
  --prebuild-batch-nonces 65536
  --threadgroup-size 128
  --build-chunk-elements 2097152
  --prefetch-chunk-elements 1048576
  --dataset-threadgroup-size 256
  --api-bind 127.0.0.1:0
  --json
)
if (( height_interval > 0 )); then
  common+=(--height-interval "$height_interval")
fi
if [[ -n $table_size ]]; then
  common+=(--table-size "$table_size")
fi

order=0
for (( round = 1; round <= runs; round++ )); do
  indices=()
  if (( round % 2 == 1 )); then
    for (( index = 1; index <= ${#variants}; index++ )); do indices+=("$index"); done
  else
    for (( index = ${#variants}; index >= 1; index-- )); do indices+=("$index"); done
  fi

  for index in "${indices[@]}"; do
    specification=${variants[$index]}
    name=${specification%%:*}
    arguments=${specification#*:}
    variant_arguments=(${(z)arguments})
    (( order += 1 ))
    stem=$(printf '%02d-r%02d-%s' "$order" "$round" "$name")
    json="$output_dir/$stem.json"
    events="$output_dir/$stem.jsonl"
    print -u2 "[$order] round=$round variant=$name"
    "$binary" "${common[@]}" "${variant_arguments[@]}" \
      --stats-file "$events" > "$json"
    jq -c \
      --arg variant "$name" \
      --argjson round "$round" \
      --argjson order "$order" \
      '. + {campaign_variant:$variant, campaign_round:$round, campaign_order:$order}' \
      "$json" >> "$results"
    if (( cooldown > 0 )); then sleep "$cooldown"; fi
  done
done

jq -s '
  def median:
    sort
    | if length % 2 == 1 then
        .[length / 2 | floor]
      else
        (.[length / 2 - 1] + .[length / 2]) / 2
      end;
  group_by(.campaign_variant)
  | map({
      variant: .[0].campaign_variant,
      runs: length,
      dataset_wall_median: (map(.datasetBuildSeconds) | median),
      dataset_gpu_median: (map(.datasetBuildGPUSeconds) | median),
      prefetch_wall_median: (map(.datasetWork.prefetchBuildWallSeconds) | median),
      prefetch_gpu_median: (map(.datasetWork.prefetchBuildGPUSeconds) | median),
      effective_hashrate_median: (map(.effectiveHashrate) | median),
      active_hashrate_median: (map(.averageHashrate) | median),
      search_duty_median: (
        map(.searchSeconds / ((.sampledAt | fromdateiso8601) - (.startedAt | fromdateiso8601)))
        | median),
      nonces_median: (map(.nonces) | median),
      peak_temperature_median: (map(.socTemperatureSessionPeakCelsius) | median),
      dataset_activations_median: (map(.datasetActivations) | median),
      prefetch_waits_median: (map(.datasetPrefetchWaits) | median),
      build_non_gpu_seconds_median: (
        map(.datasetWork.buildCommandWallSeconds - .datasetWork.buildCommandGPUSeconds)
        | median),
      search_non_gpu_seconds_median: (
        map(.datasetWork.searchCommandWallSeconds - .datasetWork.searchCommandGPUSeconds)
        | median)
    })
' "$results" | tee "$output_dir/summary.json"
