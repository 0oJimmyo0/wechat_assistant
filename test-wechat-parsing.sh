#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BINARY="$PROJECT_DIR/.build/WeChatParsingTests"

mkdir -p "$PROJECT_DIR/.build"
swiftc \
    -o "$TEST_BINARY" \
    "$PROJECT_DIR/Sources/WeChat/ChatMessage.swift" \
    "$PROJECT_DIR/Sources/WeChat/WeChatParsing.swift" \
    "$PROJECT_DIR/Sources/WeChat/VisionConversationIdentity.swift" \
    "$PROJECT_DIR/Tests/WeChatParsingTests.swift"

"$TEST_BINARY"
