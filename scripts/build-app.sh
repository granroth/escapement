#!/bin/bash
#
# Builds Escapement.app from the SwiftPM `Escapement` executable target and
# signs it with the Developer ID + Hardened Runtime.
#
# There is no Xcode project on purpose: the whole app builds from `swift build`
# plus this script, so it is reproducible from a clean checkout with no GUI and
# no generated project to drift out of sync.
#
# Usage: scripts/build-app.sh [debug|release]   (default: release)

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Escapement"
BUNDLE_ID="com.granroth.Escapement"
BUILD_DIR="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/$APP_NAME.app"
IDENTITY="Developer ID Application: KURT GRANROTH (9G779AB6US)"

AGENT_NAME="EscapementAgent"
AGENT_PLIST="com.granroth.Escapement.Agent.plist"

echo "Building $APP_NAME and $AGENT_NAME ($CONFIG)…"
swift build -c "$CONFIG" --product "$APP_NAME"
swift build -c "$CONFIG" --product "$AGENT_NAME"

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"

cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/$AGENT_NAME" "$APP/Contents/MacOS/$AGENT_NAME"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/App/$AGENT_PLIST" "$APP/Contents/Library/LaunchAgents/$AGENT_PLIST"

# Bundle EscapementKit's resource bundle (fixtures are test-only, but the
# resource-bundle machinery is copied so Bundle.module resolves if used).
if compgen -G "$BUILD_DIR/"'*.bundle' > /dev/null; then
	cp -R "$BUILD_DIR/"*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
fi

# PkgInfo is a small courtesy for a well-formed bundle.
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Signing…"
# Sign the nested agent executable first, then the app bundle around it. Both
# get the Hardened Runtime; the agent is not sandboxed because it runs tmutil.
codesign --force --options runtime \
	--entitlements "$ROOT/App/Escapement.entitlements" \
	--sign "$IDENTITY" \
	--identifier "com.granroth.Escapement.Agent" \
	--timestamp \
	"$APP/Contents/MacOS/$AGENT_NAME"

codesign --force --options runtime \
	--entitlements "$ROOT/App/Escapement.entitlements" \
	--sign "$IDENTITY" \
	--identifier "$BUNDLE_ID" \
	--timestamp \
	"$APP"

echo "Verifying signature…"
codesign --verify --strict --verbose=2 "$APP"

echo "Built: $APP"
