#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CORE_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --core-only) CORE_ONLY=true ;;
        -h|--help)
            echo "Usage: ./scripts/build-and-test.sh [--core-only]"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            exit 1
            ;;
    esac
done

if [[ -n "${TRELLIS_HUD_SDK_PATH:-}" ]]; then
    SDK_PATH="$TRELLIS_HUD_SDK_PATH"
elif [[ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]]; then
    SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
else
    SDK_PATH="$(xcrun --show-sdk-path)"
fi
ARCH="$(uname -m)"
TARGET_TRIPLE="${ARCH}-apple-macosx14.0"
DIRECT_DIR="$ROOT_DIR/.build/direct-debug"

run_direct_build_and_test() {
    echo "==> Building via direct swiftc (-swift-version 6, $TARGET_TRIPLE)..."
    rm -rf "$DIRECT_DIR"
    mkdir -p "$DIRECT_DIR"

    CORE_SOURCES=()
    while IFS= read -r f; do CORE_SOURCES+=("$f"); done < <(find "$ROOT_DIR/Sources/TrellisCore" -name '*.swift' | sort)
    HOOK_SOURCES=()
    while IFS= read -r f; do HOOK_SOURCES+=("$f"); done < <(find "$ROOT_DIR/Sources/TrellisHookCLI" -name '*.swift' | sort)
    APP_SOURCES=()
    while IFS= read -r f; do APP_SOURCES+=("$f"); done < <(find "$ROOT_DIR/Sources/TrellisHUDApp" -name '*.swift' | sort)
    TEST_SOURCES=()
    while IFS= read -r f; do TEST_SOURCES+=("$f"); done < <(find "$ROOT_DIR/Tests/TrellisCoreTests" -name '*.swift' | sort)

    echo "    [1/4] TrellisCore (${#CORE_SOURCES[@]} files)..."
    swiftc -Onone -g -enable-testing -swift-version 6 -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
        -parse-as-library -module-name TrellisCore \
        -emit-module -emit-module-path "$DIRECT_DIR/TrellisCore.swiftmodule" \
        -emit-library -static -o "$DIRECT_DIR/libTrellisCore.a" \
        "${CORE_SOURCES[@]}"

    echo "    [2/4] trellis-card-hook (${#HOOK_SOURCES[@]} files)..."
    swiftc -Onone -g -swift-version 6 -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
        -I "$DIRECT_DIR" -L "$DIRECT_DIR" -lTrellisCore \
        -o "$DIRECT_DIR/trellis-card-hook" \
        "${HOOK_SOURCES[@]}"

    if [[ "$CORE_ONLY" == false ]]; then
        echo "    [3/4] TrellisHUD (${#APP_SOURCES[@]} files)..."
        APP_PARSE_FLAG=()
        if grep -q '^@main' "${APP_SOURCES[@]}"; then
            APP_PARSE_FLAG=(-parse-as-library)
        fi
        swiftc -Onone -g -swift-version 6 -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
            ${APP_PARSE_FLAG[@]+"${APP_PARSE_FLAG[@]}"} \
            -I "$DIRECT_DIR" -L "$DIRECT_DIR" -lTrellisCore \
            -framework AppKit -framework SwiftUI -framework Carbon -framework CoreServices -framework UniformTypeIdentifiers -framework UserNotifications \
            -o "$DIRECT_DIR/TrellisHUD" \
            "${APP_SOURCES[@]}"
    else
        echo "    [3/4] Skipping TrellisHUD (--core-only)"
    fi

    if [[ "${#TEST_SOURCES[@]}" -gt 0 ]]; then
        echo "    [4/4] TrellisCoreTests (${#TEST_SOURCES[@]} files)..."
        HARNESS_MAIN="$DIRECT_DIR/main.swift"
        cat > "$HARNESS_MAIN" <<'EOF'
import Foundation

do {
    try TrellisCoreTestRunner.runAll()
    print("PASS: TrellisCoreTestRunner.runAll() succeeded")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
EOF
        swiftc -Onone -g -swift-version 6 -sdk "$SDK_PATH" -target "$TARGET_TRIPLE" \
            -I "$DIRECT_DIR" -L "$DIRECT_DIR" -lTrellisCore \
            -o "$DIRECT_DIR/TrellisCoreTestRunner" \
            "${TEST_SOURCES[@]}" "$HARNESS_MAIN"
        echo "    Executing TrellisCoreTestRunner..."
        "$DIRECT_DIR/TrellisCoreTestRunner"
    fi

    echo "==> Direct swiftc build & tests passed! Binaries in $DIRECT_DIR"
}

TEST_LOG="$(mktemp)"
trap 'rm -f "${TEST_LOG:-}"' EXIT

if [[ "$CORE_ONLY" == true ]]; then
    echo "==> Running swift test --filter TrellisCoreTests (--core-only)..."
    SWIFT_TEST_ARGS=(--filter TrellisCoreTests)
else
    echo "==> Running swift test..."
    SWIFT_TEST_ARGS=()
fi

if swift test ${SWIFT_TEST_ARGS[@]+"${SWIFT_TEST_ARGS[@]}"} >"$TEST_LOG" 2>&1; then
    cat "$TEST_LOG"
    exit 0
fi

if grep -qE "swiftLanguageVersions|PackageDescription|Invalid manifest|SwiftUIMacros|macro implementation" "$TEST_LOG"; then
    echo "==> Detected host CLT manifest/macro SDK bug; running direct swiftc fallback."
    run_direct_build_and_test
else
    cat "$TEST_LOG" >&2
    exit 1
fi
