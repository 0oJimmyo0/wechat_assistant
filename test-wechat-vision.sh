#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$PROJECT_DIR/.build"
swiftc -target arm64-apple-macos14.0 -O -parse-as-library \
    -framework AppKit -framework ApplicationServices -framework Vision \
    -framework ScreenCaptureKit -framework Combine -framework CryptoKit \
    -o "$PROJECT_DIR/.build/VisionMessageReconstructionTests" \
    "$PROJECT_DIR"/Sources/WeChat/*.swift \
    "$PROJECT_DIR/Tests/VisionMessageReconstructionTests.swift"
"$PROJECT_DIR/.build/VisionMessageReconstructionTests"
