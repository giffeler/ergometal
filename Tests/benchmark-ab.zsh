#!/bin/zsh
set -euo pipefail

repository=${0:A:h:h}
temporary=$(mktemp -d /tmp/ergometal-benchmark-ab.XXXXXX)
trap 'rm -rf "$temporary"' EXIT

output=$temporary/output
argv_log=$temporary/argv.jsonl
temperature_log=$temporary/temperature.log
BENCHMARK_ARGV_LOG=$argv_log \
  BENCHMARK_TEMPERATURE_LOG=$temperature_log \
  BENCHMARK_STUB_TEMPERATURE_CELSIUS=90 \
  BINARY=$repository/Tests/benchmark-ab-stub.zsh \
  DURATION=1 \
  WARMUP_RUNS=2 \
  START_TEMPERATURE_CELSIUS=50 \
  GATE_TIMEOUT_SECONDS=0 \
  $repository/Scripts/benchmark-ab.zsh "$output" 6 \
    'tg64:--threadgroup-size 64' \
    'default:' \
    'flag:--json' 2> $temporary/stderr.log

grep -q 'warning: temperature gate timed out' $temporary/stderr.log
[[ $(wc -l < $temperature_log) -eq 20 ]]
[[ -f $output/warmup-01-tg64.json && -f $output/warmup-02-tg64.json ]]
[[ -f $output/warmup-01-tg64.jsonl && -f $output/warmup-02-tg64.jsonl ]]
! grep -q 'warmup' $output/results.jsonl

jq -s -e '
  def option_values($option):
    . as $arguments
    | [range(0; length) as $index
       | select($arguments[$index] == $option)
       | $arguments[$index + 1]];
  def option_count($option):
    [.[] | select(. == $option)] | length;
  length == 20
  and all(.[]; .[0] == "benchmark")
  and (.[0] | option_values("--threadgroup-size")) == ["64"]
  and (.[1] | option_values("--threadgroup-size")) == ["64"]
  and all(.[2:20][] | select(option_values("--threadgroup-size") != ["64"]);
    option_values("--threadgroup-size") == ["128"])
  and all(.[]; option_values("--autotune") == ["off"])
  and all(.[]; option_values("--search-pipeline-depth") == ["2"])
  and all(.[]; option_values("--build-pipeline-depth") == ["2"])
  and all(.[]; option_count("--json") == 1)
' "$argv_log" >/dev/null

jq -s -e '
  map(.campaign_variant) == [
    "tg64", "default", "flag",
    "flag", "default", "tg64",
    "default", "flag", "tg64",
    "tg64", "flag", "default",
    "flag", "tg64", "default",
    "default", "tg64", "flag"
  ]
  and map(.campaign_round) == [1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 6]
  and map(.campaign_order) == [range(1; 19)]
' "$output/results.jsonl" >/dev/null

jq -e '
  length == 3
  and all(.[];
    .runs == 6
    and .dataset_wall_median == 10
    and .dataset_wall_minimum == 10
    and .dataset_wall_maximum == 10
    and .dataset_gpu_median == 8
    and .prefetch_wall_median == 6
    and .prefetch_gpu_median == 5
    and .effective_hashrate_median == 90
    and .active_hashrate_median == 100
    and .search_duty_median == 0.5
    and .nonces_median == 6000
    and .peak_temperature_median == 70
    and .dataset_activations_median == 2
    and .prefetch_waits_median == 3
    and .build_non_gpu_seconds_median == 1
    and .search_gpu_seconds_median == 32
    and .search_gpu_busy_ratio_median == 0.8
    and .search_gpu_concurrency_median == (4 / 3)
    and .search_non_gpu_seconds_median == 4
    and ([to_entries[]
      | select(.key | endswith("_median"))
      | .key | sub("_median$"; "")] as $bases
      | . as $summary
      | all($bases[];
          . as $base
          | $summary | (has($base + "_minimum") and has($base + "_maximum")))))
' "$output/summary.json" >/dev/null

print 'benchmark-ab test passed'
