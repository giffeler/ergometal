#!/bin/zsh
# Build and validate U in a fresh worktree. Run without other benchmark work.
set -euo pipefail
readonly audit_dir=${0:A:h}
readonly repository=${audit_dir:h:h}
(( $# == 1 )) || { print -u2 'Usage: reproduce_unrolled.zsh NEW_DIRECTORY'; exit 64; }
readonly output=${1:A}
[[ ! -e "$output" ]] || { print -u2 'Output directory must not exist'; exit 64; }
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
mkdir -p "$output/logs"
git -C "$repository" worktree add --detach "$output/unrolled-core" 28736760cbab5e62c81c2907062c09ad9da4d599
git -C "$output/unrolled-core" apply "$audit_dir/unrolled-permutations.patch"
for configuration in Debug Release; do
  xcodebuild -project "$output/unrolled-core/MetalErgoMiner.xcodeproj" \
    -scheme MetalErgoMiner -configuration "$configuration" \
    -derivedDataPath "$output/build-U" -destination 'platform=macOS,arch=arm64' \
    CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES test \
    > "$output/logs/test-U-$configuration.log" 2>&1
done
xcodebuild -project "$output/unrolled-core/MetalErgoMiner.xcodeproj" \
  -scheme MetalErgoMiner -configuration Release -derivedDataPath "$output/build-U" \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO build \
  > "$output/logs/build-U-production-options.log" 2>&1
readonly products=$output/build-U/Build/Products/Release
cp "$products/ergometal" "$output/U-unrolled"
codesign --force --sign - --timestamp=none "$output/U-unrolled"
xcrun swiftc -parse-as-library -swift-version 6 -O -whole-module-optimization \
  -target arm64-apple-macos26.5 -I "$products" -L "$products" -lMetalErgoCore \
  "$audit_dir/full-dataset-correctness.swift" -o "$output/correctness-full-dataset" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __metallib -Xlinker "$products/default.metallib" \
  > "$output/logs/compile-full-dataset.log" 2>&1
"$output/correctness-full-dataset" > "$output/logs/correctness-full-dataset.txt" 2>&1
readonly core=$output/unrolled-core/Sources/MetalErgoCore
xcrun swiftc -swift-version 6 -O -whole-module-optimization -target arm64-apple-macos26.5 \
  "$core/Blake2b.swift" "$core/UInt256.swift" "$core/Autolykos.swift" \
  "$audit_dir/correctness-probe.swift" -o "$output/correctness-blake" \
  > "$output/logs/compile-blake.log" 2>&1
"$output/correctness-blake" > "$output/logs/blake-vectors.csv"
python3 - "$output/logs/blake-vectors.csv" <<'PY'
import hashlib
from pathlib import Path
import sys
count = 0
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith('layout,'):
        continue
    length, digest = line.split(',')
    length = int(length)
    data = bytes((i * 17 + length) & 255 for i in range(length))
    assert digest == hashlib.blake2b(data, digest_size=32).hexdigest(), length
    count += 1
assert count == 307, count
print('307 independent BLAKE vectors passed')
PY
print "Validated candidate and logs: $output"
