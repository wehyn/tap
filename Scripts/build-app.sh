#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
PRODUCT_NAME="Tap"

cd "$PROJECT_ROOT"
swift build --configuration "$CONFIGURATION" --product "$PRODUCT_NAME"

BIN_PATH="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
BINARY_PATH="$BIN_PATH/$PRODUCT_NAME"
APP_PATH="$PROJECT_ROOT/dist/$PRODUCT_NAME.app"

if [[ ! -x "$BINARY_PATH" ]]; then
    print -u2 "Expected executable was not produced: $BINARY_PATH"
    exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/$PRODUCT_NAME"
cp "$PROJECT_ROOT/Resources/Tap/Info.plist" "$APP_PATH/Contents/Info.plist"

# Prefer a stable local development identity so macOS privacy permissions stay
# associated with the bundle across rebuilds. Set TAP_SIGNING_IDENTITY to
# override auto-detection. Fall back to ad-hoc signing on machines without a
# local identity; that mode may require re-adding the app in Privacy & Security
# after the binary changes. Developer ID signing and notarizing remain separate
# distribution steps.
SIGNING_IDENTITY="${TAP_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/^[[:space:]]*[0-9]+\)/ { print $2; exit }')"
fi

if [[ -n "$SIGNING_IDENTITY" ]]; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH" >/dev/null
else
    codesign --force --deep --sign - "$APP_PATH" >/dev/null
fi

print "Built $APP_PATH"
