#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR=${0:A:h}
readonly REPOSITORY_ROOT=${SCRIPT_DIR:h}
readonly TEMPORARY_ROOT=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/ergometal-air.XXXXXX")
trap '/bin/rm -rf -- "${TEMPORARY_ROOT}"' EXIT INT TERM

readonly DERIVED_DATA="${TEMPORARY_ROOT}/DerivedData"
readonly IR_DUMP="${TEMPORARY_ROOT}/AutolykosKernels.ll"

fail() {
    print -u2 -- "error: $*"
    exit 1
}

command -v xcodebuild >/dev/null || fail "xcodebuild was not found"
command -v xcrun >/dev/null || fail "xcrun was not found"
xcrun --find air-objdump >/dev/null || fail "air-objdump was not found"

xcodebuild \
    -project "${REPOSITORY_ROOT}/MetalErgoMiner.xcodeproj" \
    -scheme MetalErgoMiner \
    -configuration Profile \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO \
    build >/dev/null

air_file=$(find "${DERIVED_DATA}/Build/Intermediates.noindex" \
    -path '*/Metal/AutolykosKernels.air' -type f -print -quit)
[[ -n "${air_file}" ]] || fail "optimized AutolykosKernels.air was not produced"

xcrun air-objdump --disassemble "${air_file}" >"${IR_DUMP}"

search_function="${TEMPORARY_ROOT}/search.ll"
gather_only_function="${TEMPORARY_ROOT}/gather-only.ll"
gather_helper="${TEMPORARY_ROOT}/gather-helper.ll"
/usr/bin/awk '/^define .*@searchNonces\(/,/^}/' "${IR_DUMP}" >"${search_function}"
/usr/bin/awk '/^define .*@gatherOnlyNonces\(/,/^}/' "${IR_DUMP}" >"${gather_only_function}"
/usr/bin/awk '/^define .*@_Z15gatherSearchSum/,/^}/' "${IR_DUMP}" >"${gather_helper}"

search_calls=$(/usr/bin/grep -c 'call.*@_Z15gatherSearchSum' "${search_function}" || true)
gather_only_calls=$(/usr/bin/grep -c 'call.*@_Z15gatherSearchSum' "${gather_only_function}" || true)
device_vector_loads=$(/usr/bin/grep -c 'load <4 x i32>.*addrspace(1)' "${gather_helper}" || true)
loop_bounds=$(/usr/bin/grep -c 'icmp eq i32 .*32' "${gather_helper}" || true)

[[ "${search_calls}" == 1 ]] \
    || fail "searchNonces does not call the shared gather helper exactly once"
[[ "${gather_only_calls}" == 1 ]] \
    || fail "gatherOnlyNonces does not call the shared gather helper exactly once"
[[ "${device_vector_loads}" == 2 ]] \
    || fail "the shared gather helper does not contain exactly two uint4 device-load sites"
(( loop_bounds >= 1 )) \
    || fail "the shared gather helper no longer exposes the 32-iteration loop bound"

print -- "AIR gate passed"
print -- "  searchNonces shared-helper calls: ${search_calls}"
print -- "  gatherOnlyNonces shared-helper calls: ${gather_only_calls}"
print -- "  shared helper uint4 device-load sites: ${device_vector_loads}"
print -- "  shared helper loop bound: 32"
print -- "Family 9+ machine ISA and counter attribution still require Xcode Shader Profiler replay."
