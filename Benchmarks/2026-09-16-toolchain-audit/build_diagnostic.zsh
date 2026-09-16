#!/bin/zsh
# Diagnostic benchmark only. Run after all preceding GPU work has stopped.
set -euo pipefail
readonly audit_dir=${0:A:h}
readonly repository=${audit_dir:h:h}
readonly work=$repository/DerivedDataToolchainAudit20260916
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
[[ ! -e "$work/artifacts/Q-search" && ! -e "$work/artifacts/Q-gather" ]]
git -C "$work/benchmark-control" diff --exit-code -- Sources/MetalErgoCore
xcodebuild -project "$work/benchmark-control/MetalErgoMiner.xcodeproj" \
  -scheme MetalErgoMiner -configuration Release \
  -derivedDataPath "$work/build-Q" -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO build \
  > "$audit_dir/raw/build-Q-production-options.log" 2>&1
cp "$work/build-Q/Build/Products/Release/ergometal" "$work/artifacts/Q-search"
codesign --force --sign - --timestamp=none "$work/artifacts/Q-search"
cp "$work/artifacts/Q-search" "$work/artifacts/Q-gather"
cmp "$work/artifacts/Q-search" "$work/artifacts/Q-gather"
python3 "$audit_dir/inspect_artifacts.py" "$work/artifacts/Q-search" "$work/artifacts/Q-gather" \
  > "$audit_dir/raw/diagnostic-identities.json"
