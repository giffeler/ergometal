#!/bin/zsh
set -euo pipefail

repository=${0:A:h:h}
temporary=$(mktemp -d /tmp/ergometal-benchmark-ab.XXXXXX)
trap 'rm -rf "$temporary"' EXIT

output=$temporary/output
argv_log=$temporary/argv.jsonl
BENCHMARK_ARGV_LOG=$argv_log \
  BINARY=$repository/Tests/benchmark-ab-stub.zsh \
  DURATION=1 \
  $repository/Scripts/benchmark-ab.zsh "$output" 2 \
    'tg64:--threadgroup-size 64' \
    'default:' \
    'flag:--json'

jq -s -e '
  def option_values($option):
    . as $arguments
    | [range(0; length) as $index
       | select($arguments[$index] == $option)
       | $arguments[$index + 1]];
  def option_count($option):
    [.[] | select(. == $option)] | length;
  length == 6
  and all(.[]; .[0] == "benchmark")
  and (.[0] | option_values("--threadgroup-size")) == ["64"]
  and (.[5] | option_values("--threadgroup-size")) == ["64"]
  and all([.[1], .[2], .[3], .[4]][];
    option_values("--threadgroup-size") == ["128"])
  and all(.[]; option_count("--json") == 1)
' "$argv_log" >/dev/null

jq -s -e '
  map(.campaign_variant) == ["tg64", "default", "flag", "flag", "default", "tg64"]
  and map(.campaign_round) == [1, 1, 1, 2, 2, 2]
  and map(.campaign_order) == [1, 2, 3, 4, 5, 6]
' "$output/results.jsonl" >/dev/null

jq -e '
  length == 3
  and all(.[];
    .runs == 2
    and .dataset_wall_median == 10
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
    and .search_non_gpu_seconds_median == 8)
' "$output/summary.json" >/dev/null

print 'benchmark-ab test passed'
