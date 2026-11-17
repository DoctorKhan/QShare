#!/bin/bash
# Regenerates Sources/QuickShareKit/Generated from Protos/.
# Requires protoc (brew install protobuf); builds protoc-gen-swift from the SwiftPM checkout.
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve
PLUGIN=".build/checkouts/swift-protobuf/.build/release/protoc-gen-swift"
if [ ! -x "$PLUGIN" ]; then
  (cd .build/checkouts/swift-protobuf && swift build -c release --product protoc-gen-swift)
fi
protoc --plugin="protoc-gen-swift=$PLUGIN" --proto_path=Protos \
  --swift_out=Sources/QuickShareKit/Generated Protos/*.proto
