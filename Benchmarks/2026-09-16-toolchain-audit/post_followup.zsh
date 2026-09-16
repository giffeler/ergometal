#!/bin/zsh
# Run only after the GPU comparison controller has completed.
set -euo pipefail
readonly audit_dir=${0:A:h}
readonly repository=${audit_dir:h:h}
readonly work=$repository/DerivedDataToolchainAudit20260916
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Restore only the explicitly preserved get-accessor ablation in our worktree.
git -C "$work/candidate" apply --reverse --check "$audit_dir/borrow-accessor-control.patch"
git -C "$work/candidate" apply --reverse "$audit_dir/borrow-accessor-control.patch"
xcodebuild -project "$work/unrolled-core/MetalErgoMiner.xcodeproj" -scheme MetalErgoMiner -configuration Release -derivedDataPath "$work/build-U" -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO build > "$audit_dir/raw/build-U-production-options.log" 2>&1
cp "$work/build-U/Build/Products/Release/ergometal" "$work/artifacts/U-unrolled"
codesign --force --sign - --timestamp=none "$work/artifacts/U-unrolled"
python3 "$audit_dir/cpu_linked.py" --work "$work" --output "$audit_dir/raw/cpu-linked-reproduction-new"
otool -tvV "$work/artifacts/C" > "$work/C-production-core.disassembly"
otool -tvV "$work/artifacts/U-unrolled" > "$work/U-production-core.disassembly"
print 'Linked CPU comparisons and production disassembly complete'
