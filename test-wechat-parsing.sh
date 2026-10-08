#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_BINARY="$PROJECT_DIR/.build/WeChatParsingTests"

mkdir -p "$PROJECT_DIR/.build"
swiftc \
    -o "$TEST_BINARY" \
    "$PROJECT_DIR/Sources/WeChat/ChatMessage.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationCapturePlan.swift" \
    "$PROJECT_DIR/Sources/WeChat/ChatHistoryMerger.swift" \
    "$PROJECT_DIR/Sources/WeChat/WeChatParsing.swift" \
    "$PROJECT_DIR/Sources/WeChat/VisionConversationIdentity.swift" \
    "$PROJECT_DIR/Tests/WeChatParsingTests.swift"

"$TEST_BINARY"

STORE_TEST_BINARY="$PROJECT_DIR/.build/ConversationStoreTests"
swiftc \
    -o "$STORE_TEST_BINARY" \
    "$PROJECT_DIR/Sources/WeChat/ChatMessage.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationCapturePlan.swift" \
    "$PROJECT_DIR/Sources/WeChat/ChatHistoryMerger.swift" \
    "$PROJECT_DIR/Sources/WeChat/WeChatParsing.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationStore.swift" \
    "$PROJECT_DIR/Tests/ConversationStoreTests.swift"

"$STORE_TEST_BINARY"

CAPTURE_TEST_BINARY="$PROJECT_DIR/.build/ConversationCapturePlanTests"
swiftc \
    -o "$CAPTURE_TEST_BINARY" \
    "$PROJECT_DIR/Sources/WeChat/ConversationCapturePlan.swift" \
    "$PROJECT_DIR/Tests/ConversationCapturePlanTests.swift"

"$CAPTURE_TEST_BINARY"

swiftc -o "$PROJECT_DIR/.build/TranscriptScrollStateTests" \
    "$PROJECT_DIR/Sources/WeChat/TranscriptScrollState.swift" \
    "$PROJECT_DIR/Tests/TranscriptScrollStateTests.swift"
"$PROJECT_DIR/.build/TranscriptScrollStateTests"

swiftc -o "$PROJECT_DIR/.build/ConversationMonitoringTests" \
    "$PROJECT_DIR/Sources/WeChat/ChatMessage.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationCapturePlan.swift" \
    "$PROJECT_DIR/Sources/WeChat/WeChatParsing.swift" \
    "$PROJECT_DIR/Sources/WeChat/ChatHistoryMerger.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationStore.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationMonitoringState.swift" \
    "$PROJECT_DIR/Tests/ConversationMonitoringTests.swift"
"$PROJECT_DIR/.build/ConversationMonitoringTests"

swiftc -o "$PROJECT_DIR/.build/AnalysisContextTests" \
    "$PROJECT_DIR/Sources/WeChat/ChatMessage.swift" \
    "$PROJECT_DIR/Sources/WeChat/AnalysisContext.swift" \
    "$PROJECT_DIR/Tests/AnalysisContextTests.swift"
"$PROJECT_DIR/.build/AnalysisContextTests"

swiftc -o "$PROJECT_DIR/.build/HistoryRefinementTests" \
    "$PROJECT_DIR/Sources/WeChat/ChatMessage.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationCapturePlan.swift" \
    "$PROJECT_DIR/Sources/WeChat/WeChatParsing.swift" \
    "$PROJECT_DIR/Sources/WeChat/ChatHistoryMerger.swift" \
    "$PROJECT_DIR/Sources/WeChat/ConversationStore.swift" \
    "$PROJECT_DIR/Tests/HistoryRefinementTests.swift"
"$PROJECT_DIR/.build/HistoryRefinementTests"
