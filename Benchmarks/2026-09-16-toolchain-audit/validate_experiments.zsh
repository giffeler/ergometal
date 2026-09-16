#!/bin/zsh
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
repo=/Users/denis/Developer/ergometal
work=$repo/DerivedDataToolchainAudit20260916
audit=$repo/Benchmarks/2026-09-16-toolchain-audit
for config in Debug Release; do
  xcodebuild -project "$work/experiment/MetalErgoMiner.xcodeproj" -scheme MetalErgoMiner -configuration "$config" -derivedDataPath "$work/build-E" -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES test > "$audit/raw/test-E-expanded-$config.log" 2>&1
  print "E $config passed"
done
for config in Debug Release; do
  xcodebuild -project "$work/uniform-hint/MetalErgoMiner.xcodeproj" -scheme MetalErgoMiner -configuration "$config" -derivedDataPath "$work/build-H" -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES test > "$audit/raw/test-H-$config.log" 2>&1
  print "H $config passed"
done
xcodebuild -project "$work/uniform-hint/MetalErgoMiner.xcodeproj" -scheme MetalErgoMiner -configuration Release -derivedDataPath "$work/build-H" -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO build > "$audit/raw/build-H-production-options.log" 2>&1
cp "$work/build-H/Build/Products/Release/ergometal" "$work/artifacts/H-full-simd"
codesign --force --sign - --timestamp=none "$work/artifacts/H-full-simd"
products=$work/build-H/Build/Products/Release
xcrun swiftc -parse-as-library -swift-version 6 -O -whole-module-optimization -target arm64-apple-macos26.5 -I "$products" -L "$products" -lMetalErgoCore "$audit/full-dataset-correctness.swift" -o "$work/artifacts/correctness-H-full-dataset" -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __metallib -Xlinker "$products/default.metallib" > "$audit/raw/compile-H-full-dataset.log" 2>&1
"$work/artifacts/correctness-H-full-dataset" > "$audit/raw/correctness-H-full-dataset.txt" 2>&1
print 'H full-dataset CPU/Metal check passed'
