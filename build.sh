#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="WeChatReplyCopilot"
BUILD_DIR="$PROJECT_DIR/.build"
MACOS_DIR="$BUILD_DIR/$APP_NAME.app/Contents/MacOS"
RESOURCES_DIR="$BUILD_DIR/$APP_NAME.app/Contents/Resources"
HASH_FILE="$BUILD_DIR/.source_hash"
SIGNING_IDENTITY="${WECHAT_REPLY_SIGNING_IDENTITY:-WeChat Reply Copilot Local Signing}"

echo "=== Building $APP_NAME ==="

# Compute hash of all source files (to detect real code changes)
CURRENT_HASH=$(find "$PROJECT_DIR/Sources" -name "*.swift" -exec cat {} + | shasum -a 256 | cut -d' ' -f1)
PREV_HASH=""
if [ -f "$HASH_FILE" ]; then
    PREV_HASH=$(cat "$HASH_FILE")
fi

# Clean
rm -rf "$BUILD_DIR/$APP_NAME.app"

# Create bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Find all Swift sources
SOURCES=()
while IFS= read -r -d '' file; do
    SOURCES+=("$file")
done < <(find "$PROJECT_DIR/Sources" -name "*.swift" -print0)

echo "Sources: ${#SOURCES[@]} files"
for src in "${SOURCES[@]}"; do
    echo "  - $(basename "$src")"
done

# Compile
echo ""
echo "Compiling..."

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macos14.0"

swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -framework ApplicationServices \
    -framework Vision \
    -framework Combine \
    -framework Network \
    -framework Security \
    -framework CryptoKit \
    -parse-as-library \
    -O \
    -o "$MACOS_DIR/$APP_NAME" \
    "${SOURCES[@]}"

echo "Compilation successful!"

# The bundle manifest belongs directly under Contents; resources such as the icon
# stay under Contents/Resources.
cp "$PROJECT_DIR/Resources/Info.plist" "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist"

# Copy App Icon
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Create PkgInfo
echo "APPL????" > "$BUILD_DIR/$APP_NAME.app/Contents/PkgInfo"

# Use a stable local signing identity when one is available. Ad-hoc signatures
# identify a single binary hash, so Accessibility approval will not carry across rebuilds.
echo ""
SIGNING_IDENTITIES="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ "$SIGNING_IDENTITIES" == *"$SIGNING_IDENTITY"* ]]; then
    echo "Signing with stable identity: $SIGNING_IDENTITY"
    echo "If macOS asks to access this signing key, choose 'Always Allow' once to avoid future prompts."
    codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$BUILD_DIR/$APP_NAME.app"
else
    echo "Stable identity '$SIGNING_IDENTITY' not found; using ad-hoc signing."
    echo "Accessibility consent may need to be granted again after this or any rebuild."
    codesign --force --deep --sign - "$BUILD_DIR/$APP_NAME.app"
fi

# Save hash for next comparison
echo "$CURRENT_HASH" > "$HASH_FILE"

echo ""
echo "=== Build complete ==="
echo "App: $BUILD_DIR/$APP_NAME.app"

# Copy to /Applications if requested
if [[ "${1:-}" == "--install" ]]; then
    echo ""
    echo "Installing to /Applications..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$BUILD_DIR/$APP_NAME.app" "/Applications/"
    echo "Installed to /Applications/$APP_NAME.app"
    
    if [[ "$SIGNING_IDENTITIES" != *"$SIGNING_IDENTITY"* ]]; then
        echo ""
        echo "⚠️  Ad-hoc signature used. Grant Accessibility to this exact installed build."
    fi
fi
