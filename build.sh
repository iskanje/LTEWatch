#!/bin/zsh
set -eu
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${LTEWATCH_BUILD_DIR:-$PROJECT_DIR/work}"
OUTPUT_DIR="${LTEWATCH_OUTPUT_DIR:-$PROJECT_DIR/dist}"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/swift-module-cache"
swift build --disable-sandbox --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR/build" \
  --cache-path "$BUILD_DIR/swift-cache" --config-path "$BUILD_DIR/swift-config" --security-path "$BUILD_DIR/swift-security" -c release
APP_DIR="$OUTPUT_DIR/LTEWatch.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/build/release/LTEWatch" "$APP_DIR/Contents/MacOS/LTEWatch"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"
print "Built $APP_DIR"
