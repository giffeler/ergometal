#!/bin/zsh
set -euo pipefail

usage() {
  print -u2 'Usage: benchmark-ab.zsh OUTPUT_DIR RUNS NAME:ARGUMENTS [NAME:ARGUMENTS ...]'
  print -u2 "Example: $0 /tmp/ergometal-ab 3 'overlap:--dataset-scheduling overlap' 'serialized:--dataset-scheduling serialized'"
  print -u2 'Environment: BINARY, DURATION, HEIGHT, HEIGHT_INTERVAL, TABLE_SIZE, COOLDOWN_SECONDS,'
  print -u2 '             START_TEMPERATURE_CELSIUS, GATE_TIMEOUT_SECONDS, WARMUP_RUNS'
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
start_temperature=${START_TEMPERATURE_CELSIUS:-}
gate_timeout=${GATE_TIMEOUT_SECONDS:-300}
warmup_runs=${WARMUP_RUNS:-0}

if [[ $warmup_runs != <-> ]]; then
  print -u2 'WARMUP_RUNS must be a non-negative integer'
  exit 2
fi
if [[ $gate_timeout != <-> ]]; then
  print -u2 'GATE_TIMEOUT_SECONDS must be a non-negative integer'
  exit 2
fi
if [[ -n $start_temperature ]] && ! jq -en --arg value "$start_temperature" \
    '$value | tonumber | isfinite' >/dev/null 2>&1; then
  print -u2 'START_TEMPERATURE_CELSIUS must be a finite number'
  exit 2
fi

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

wait_for_start_temperature() {
  [[ -z $start_temperature ]] && return
  local started=$SECONDS
  local sample temperature elapsed
  while true; do
    sample=$("$binary" temperature --json)
    temperature=$(jq -r '.maximumCelsius // empty' <<< "$sample")
    if [[ -z $temperature ]]; then
      print -u2 'warning: SoC temperature is unavailable; continuing without temperature gate'
      return
    fi
    if jq -en --argjson temperature "$temperature" --argjson threshold "$start_temperature" \
        '$temperature <= $threshold' >/dev/null; then
      print -u2 "temperature gate passed: ${temperature} C <= ${start_temperature} C"
      return
    fi
    elapsed=$(( SECONDS - started ))
    if (( elapsed >= gate_timeout )); then
      print -u2 "warning: temperature gate timed out after ${elapsed}s at ${temperature} C; continuing"
      return
    fi
    sleep 5
  done
}

run_variant() {
  local specification=$1
  local stem=$2
  local round=${3:-}
  local order=${4:-}
  local name=${specification%%:*}
  local arguments=${specification#*:}
  local -a variant_arguments effective
  variant_arguments=(${(z)arguments})
  # An option named by the variant replaces the campaign default instead of
  # being appended to it; the miner rejects a repeated option outright.
  typeset -A overridden=()
  local token position
  for token in "${variant_arguments[@]}"; do
    if [[ $token == --* ]]; then overridden[${token#--}]=1; fi
  done
  effective=()
  position=1
  while (( position <= ${#common} )); do
    token=${common[$position]}
    if [[ $token == --* ]] && (( ${+overridden[${token#--}]} )); then
      if (( position < ${#common} )) && [[ ${common[$position + 1]} != --* ]]; then
        (( position += 2 ))
      else
        (( position += 1 ))
      fi
      continue
    fi
    effective+=("$token")
    (( position += 1 ))
  done

  local json="$output_dir/$stem.json"
  local events="$output_dir/$stem.jsonl"
  wait_for_start_temperature
  "$binary" "${effective[@]}" "${variant_arguments[@]}" \
    --stats-file "$events" > "$json"
  if [[ -n $round && -n $order ]]; then
    jq -c \
      --arg variant "$name" \
      --argjson round "$round" \
      --argjson order "$order" \
      '. + {campaign_variant:$variant, campaign_round:$round, campaign_order:$order}' \
      "$json" >> "$results"
  fi
  if (( cooldown > 0 )); then sleep "$cooldown"; fi
}

for (( warmup = 1; warmup <= warmup_runs; warmup++ )); do
  specification=${variants[1]}
  name=${specification%%:*}
  stem=$(printf 'warmup-%02d-%s' "$warmup" "$name")
  print -u2 "[warmup $warmup/$warmup_runs] variant=$name"
  run_variant "$specification" "$stem"
done

order=0
for (( round = 1; round <= runs; round++ )); do
  indices=()
  pair=$(( (round - 1) / 2 ))
  rotation=$(( pair % ${#variants} ))
  for (( offset = 0; offset < ${#variants}; offset++ )); do
    indices+=("$(( (rotation + offset) % ${#variants} + 1 ))")
  done
  if (( round % 2 == 0 )); then
    reversed=()
    for (( position = ${#indices}; position >= 1; position-- )); do
      reversed+=("${indices[$position]}")
    done
    indices=("${reversed[@]}")
  fi

  for index in "${indices[@]}"; do
    specification=${variants[$index]}
    name=${specification%%:*}
    (( order += 1 ))
    stem=$(printf '%02d-r%02d-%s' "$order" "$round" "$name")
    print -u2 "[$order] round=$round variant=$name"
    run_variant "$specification" "$stem" "$round" "$order"
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
  def measures($name; $values):
    {
      ($name + "_minimum"): ($values | min),
      ($name + "_median"): ($values | median),
      ($name + "_maximum"): ($values | max)
    };
  group_by(.campaign_variant)
  | map(({
      variant: .[0].campaign_variant,
      runs: length
    }
    + measures("dataset_wall"; map(.datasetBuildSeconds))
    + measures("dataset_gpu"; map(.datasetBuildGPUSeconds))
    + measures("prefetch_wall"; map(.datasetWork.prefetchBuildWallSeconds))
    + measures("prefetch_gpu"; map(.datasetWork.prefetchBuildGPUSeconds))
    + measures("effective_hashrate"; map(.effectiveHashrate))
    + measures("active_hashrate"; map(.averageHashrate))
    + measures("search_duty";
        map(.searchSeconds / ((.sampledAt | fromdateiso8601) - (.startedAt | fromdateiso8601))))
    + measures("nonces"; map(.nonces))
    + measures("peak_temperature"; map(.socTemperatureSessionPeakCelsius))
    + measures("dataset_activations"; map(.datasetActivations))
    + measures("prefetch_waits"; map(.datasetPrefetchWaits))
    + measures("build_non_gpu_seconds";
        map(.datasetWork.buildCommandWallSeconds - .datasetWork.buildCommandGPUSeconds))
    + measures("search_gpu_seconds"; map(.datasetWork.searchCommandGPUSeconds))
    + measures("search_gpu_busy_ratio";
        map(.datasetWork.searchCommandGPUSeconds / .searchSeconds))
    + measures("search_non_gpu_seconds";
        map(.datasetWork.searchCommandWallSeconds - .datasetWork.searchCommandGPUSeconds))))
' "$results" | tee "$output_dir/summary.json"
