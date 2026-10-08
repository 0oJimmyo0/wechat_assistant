#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$PROJECT_DIR/.build"
# Requires a logged-in macOS desktop. Uses public synthetic data only and
# neither reads/scrolls WeChat nor makes network/model requests.
swiftc -target arm64-apple-macos14.0 -O -parse-as-library \
    -framework AppKit -framework SwiftUI \
    -o "$PROJECT_DIR/.build/TranscriptUIIntegrationTests" \
    "$PROJECT_DIR/Sources/WeChat/ChatMessage.swift" \
    "$PROJECT_DIR/Sources/WeChat/TranscriptScrollState.swift" \
    "$PROJECT_DIR/Sources/UI/ChatTranscriptView.swift" \
    "$PROJECT_DIR/Tests/TranscriptUIIntegrationTests.swift"
"$PROJECT_DIR/.build/TranscriptUIIntegrationTests"
