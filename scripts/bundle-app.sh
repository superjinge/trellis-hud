#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -n "${TRELLIS_HUD_SDK_PATH:-}" ]]; then
    SDK_PATH="$TRELLIS_HUD_SDK_PATH"
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
else
    SDK_PATH="$(xcrun --show-sdk-path)"
fi
ARCH="$(uname -m)"
TARGET_TRIPLE="${ARCH}-apple-macosx14.0"
DIRECT_DIR="$ROOT_DIR/.build/direct-release"

build_with_direct_swiftc() {
    echo "==> Falling back to direct swiftc (-swift-version 6, target $TARGET_TRIPLE)..."
    rm -rf "$DIRECT_DIR"
    mkdir -p "$DIRECT_DIR/obj"

    CORE_SOURCES=()
    while IFS= read -r f; do CORE_SOURCES+=("$f"); done < <(find "$ROOT_DIR/Sources/TrellisCore" -name '*.swift' | sort)
    HOOK_SOURCES=()
    while IFS= read -r f; do HOOK_SOURCES+=("$f"); done < <(find "$ROOT_DIR/Sources/TrellisHookCLI" -name '*.swift' | sort)
    APP_SOURCES=()
    while IFS= read -r f; do APP_SOURCES+=("$f"); done < <(find "$ROOT_DIR/Sources/TrellisHUDApp" -name '*.swift' | sort)

    echo "    Compiling TrellisCore (${#CORE_SOURCES[@]} files)..."
    swiftc -O -swift-version 6 -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
        -parse-as-library -module-name TrellisCore \
        -emit-module -emit-module-path "$DIRECT_DIR/TrellisCore.swiftmodule" \
        -emit-library -static -o "$DIRECT_DIR/libTrellisCore.a" \
        "${CORE_SOURCES[@]}"

    echo "    Compiling trellis-card-hook (${#HOOK_SOURCES[@]} files)..."
    swiftc -O -swift-version 6 -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
        -I "$DIRECT_DIR" -L "$DIRECT_DIR" -lTrellisCore \
        -o "$DIRECT_DIR/trellis-card-hook" \
        "${HOOK_SOURCES[@]}"

    echo "    Compiling TrellisHUD (${#APP_SOURCES[@]} files)..."
    APP_PARSE_FLAG=()
    if ! grep -q '^@main' "${APP_SOURCES[@]}"; then
        APP_PARSE_FLAG=()
    else
        APP_PARSE_FLAG=(-parse-as-library)
    fi
    swiftc -O -swift-version 6 -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
        ${APP_PARSE_FLAG[@]+"${APP_PARSE_FLAG[@]}"} \
        -I "$DIRECT_DIR" -L "$DIRECT_DIR" -lTrellisCore \
        -framework AppKit -framework SwiftUI -framework Carbon -framework CoreServices -framework UniformTypeIdentifiers -framework UserNotifications \
        -o "$DIRECT_DIR/TrellisHUD" \
        "${APP_SOURCES[@]}"

    BIN_DIR="$DIRECT_DIR"
}

echo "==> Building release binaries..."
BUILD_LOG="$(mktemp)"
trap 'rm -f "${BUILD_LOG:-}"' EXIT
if swift build -c release >"$BUILD_LOG" 2>&1; then
    cat "$BUILD_LOG"
    BIN_DIR="$(swift build -c release --show-bin-path)"
else
    if grep -qE "swiftLanguageVersions|PackageDescription|Invalid manifest|SwiftUIMacros|macro implementation" "$BUILD_LOG"; then
        echo "==> Detected host CLT manifest/macro SDK bug; switching to direct swiftc build."
        build_with_direct_swiftc
    else
        cat "$BUILD_LOG" >&2
        exit 1
    fi
fi

APP_DIR="$ROOT_DIR/build/TrellisHUD.app"
CONTENTS_DIR="$APP_DIR/Contents"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Helpers" "$CONTENTS_DIR/Resources"

echo "==> Assembling $APP_DIR..."
cp "$BIN_DIR/TrellisHUD" "$CONTENTS_DIR/MacOS/TrellisHUD"
cp "$BIN_DIR/trellis-card-hook" "$CONTENTS_DIR/Helpers/trellis-card-hook"
chmod +x "$CONTENTS_DIR/MacOS/TrellisHUD" "$CONTENTS_DIR/Helpers/trellis-card-hook"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ROOT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon.icns" "$CONTENTS_DIR/Resources/AppIcon.icns"
fi
if [[ -d "$ROOT_DIR/Resources/templates" ]]; then
    cp -R "$ROOT_DIR/Resources/templates" "$CONTENTS_DIR/Resources/templates"
fi

shopt -s nullglob
for bundle in "$BIN_DIR"/TrellisHUD_TrellisCore.bundle "$BIN_DIR"/TrellisCore_*.bundle; do
    if [[ -d "$bundle" ]]; then
        cp -R "$bundle" "$CONTENTS_DIR/Resources/"
    fi
done
shopt -u nullglob

echo "==> Ad-hoc signing $APP_DIR..."
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $APP_DIR"
