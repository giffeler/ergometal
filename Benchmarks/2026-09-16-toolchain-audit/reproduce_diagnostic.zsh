#!/bin/zsh
# Diagnostic-only target control; these artifacts are not release candidates.
set -euo pipefail
readonly audit_dir=${0:A:h}
readonly repository=${audit_dir:h:h}
(( $# == 1 )) || { print -u2 'Usage: reproduce_diagnostic.zsh NEW_DIRECTORY'; exit 64; }
readonly output=${1:A}
[[ ! -e "$output" ]] || { print -u2 'Output directory must not exist'; exit 64; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p "$output/artifacts" "$output/logs"
git -C "$repository" worktree add --detach "$output/benchmark-control" 28736760cbab5e62c81c2907062c09ad9da4d599
git -C "$output/benchmark-control" apply "$audit_dir/benchmark-zero-target-control.patch"
xcodebuild -project "$output/benchmark-control/MetalErgoMiner.xcodeproj" \
  -scheme MetalErgoMiner -configuration Release -derivedDataPath "$output/build-Q" \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO build \
  > "$output/logs/build-Q.log" 2>&1
cp "$output/build-Q/Build/Products/Release/ergometal" "$output/artifacts/Q-search"
codesign --force --sign - --timestamp=none "$output/artifacts/Q-search"
cp "$output/artifacts/Q-search" "$output/artifacts/Q-gather"
cmp "$output/artifacts/Q-search" "$output/artifacts/Q-gather"
python3 "$audit_dir/inspect_artifacts.py" "$output/artifacts/Q-search" "$output/artifacts/Q-gather" \
  > "$output/diagnostic-identities.json"
print "Diagnostic artifacts: $output/artifacts"
