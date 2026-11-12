#!/bin/zsh
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK_DIR="${LTEWATCH_BUILD_DIR:-$PROJECT_DIR/work}"
mkdir -p "$CHECK_DIR/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$CHECK_DIR/module-cache" \
  "$PROJECT_DIR/Sources/LTEWatch/Models.swift" \
  "$PROJECT_DIR/Sources/LTEWatch/Router.swift" \
  "$PROJECT_DIR/Sources/LTEWatch/Services.swift" \
  "$PROJECT_DIR/Tests/LTEWatchTests/MeasurementTests.swift" \
  "$PROJECT_DIR/Tests/LTEWatchTests/ProtocolChecks.swift" \
  -o "$CHECK_DIR/measurement-checks"
"$CHECK_DIR/measurement-checks"
