#!/bin/zsh
# Reproduce the four controlled groups in a NEW directory, without a release.
set -euo pipefail
readonly audit_dir=${0:A:h}
readonly repository=${audit_dir:h:h}
(( $# == 1 )) || { print -u2 'Usage: rebuild.zsh NEW_OUTPUT_DIRECTORY'; exit 64; }
readonly output=${1:A}
[[ ! -e $output ]] || { print -u2 'Output directory must not exist'; exit 64; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p "$output/artifacts" "$output/logs"
git -C "$repository" worktree add --detach "$output/baseline" 3e024cc4da34ac21c178be3256c08195ab436e0c
git -C "$repository" worktree add --detach "$output/candidate" 28736760cbab5e62c81c2907062c09ad9da4d599
unzip -p "$repository/Distribution/ergometal-macos-arm64-2026-09-12-notarized.zip" ergometal > "$output/artifacts/A"
unzip -p "$repository/Distribution/ergometal-macos-arm64-2026-09-15-notarized.zip" ergometal > "$output/artifacts/C-production"
chmod 755 "$output/artifacts/A" "$output/artifacts/C-production"
printf '%s  %s\n' b18ed68823c6f1fe9837b057395d722392deef97b91e31c99b1a286573743b64 "$output/artifacts/A" | shasum -a 256 -c -
printf '%s  %s\n' e318af94fc52c7764c4476e542c24c98ab851a5a004c6658ac6e46552a252f79 "$output/artifacts/C-production" | shasum -a 256 -c -
xcodebuild -version > "$output/logs/toolchain.txt"
xcrun swift --version >> "$output/logs/toolchain.txt" 2>&1
xcrun metal --version >> "$output/logs/toolchain.txt" 2>&1
python3 "$audit_dir/inspect_artifacts.py" --dump "$output/artifacts" "$output/artifacts/A" "$output/artifacts/C-production" > "$output/input-identities.json"

build_group() {
  local group=$1 source=$2 derived=$3
  shift 3
  xcodebuild -project "$source/MetalErgoMiner.xcodeproj" -scheme MetalErgoMiner \
    -configuration Release -derivedDataPath "$derived" -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO "$@" build > "$output/logs/build-$group.log" 2>&1
  cp "$derived/Build/Products/Release/ergometal" "$output/artifacts/$group"
  codesign --force --sign - --timestamp=none "$output/artifacts/$group"
  codesign --verify --strict "$output/artifacts/$group"
}
build_group B "$output/baseline" "$output/build-B"
build_group B0-old-metal "$output/baseline" "$output/build-B" \
  "OTHER_LDFLAGS=-Wl,-sectcreate,__TEXT,__metallib,$output/artifacts/A.__metallib"
build_group C "$output/candidate" "$output/build-C"
build_group D-old-metal "$output/candidate" "$output/build-C" \
  "OTHER_LDFLAGS=-Wl,-sectcreate,__TEXT,__metallib,$output/artifacts/A.__metallib"
python3 "$audit_dir/inspect_artifacts.py" "$output/artifacts/"{A,B0-old-metal,B,C,D-old-metal,C-production} > "$output/comparison-identities.json"
for binary in A B0-old-metal B C D-old-metal; do
  "$output/artifacts/$binary" replay --fixture "$repository/Fixtures/autolykos-v2-small.json" > "$output/logs/replay-$binary.txt"
done
print "Artifacts: $output/artifacts"
