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
#
# Environment:
#   ESCAPEMENT_SIGN_IDENTITY   codesign identity; "-" for ad-hoc. Defaults to
#                              the maintainer's Developer ID, and falls back to
#                              ad-hoc if that identity is not in the keychain,
#                              so a clean checkout always builds.
#   ESCAPEMENT_UNIVERSAL       set to 1 to build a universal (arm64 + x86_64)
#                              binary. Release builds should; local iteration
#                              need not, since it roughly doubles build time.

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Escapement"
BUNDLE_ID="com.granroth.Escapement"
APP="$ROOT/.build/$APP_NAME.app"
IDENTITY="${ESCAPEMENT_SIGN_IDENTITY:-Developer ID Application: KURT GRANROTH (9G779AB6US)}"

AGENT_NAME="EscapementAgent"
AGENT_PLIST="com.granroth.Escapement.Agent.plist"

# A universal build puts its products somewhere else entirely: SwiftPM merges
# the per-arch builds into .build/apple/Products/<Config> rather than
# .build/<config>.
if [ "${ESCAPEMENT_UNIVERSAL:-}" = "1" ]; then
	ARCH_FLAGS="--arch arm64 --arch x86_64"
	case "$CONFIG" in
		debug) BUILD_DIR="$ROOT/.build/apple/Products/Debug" ;;
		*)     BUILD_DIR="$ROOT/.build/apple/Products/Release" ;;
	esac
else
	ARCH_FLAGS=""
	BUILD_DIR="$ROOT/.build/$CONFIG"
fi

# Signing an app against an identity the machine does not have fails with a
# confusing codesign error. Ad-hoc instead: the bundle still builds and runs
# locally, which is what CI and contributors need. Ad-hoc signatures cannot
# carry a secure timestamp, and SMAppService will refuse to register one, so
# this is for building and testing — not for distribution.
TIMESTAMP_FLAG="--timestamp"
if [ "$IDENTITY" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
	echo "warning: signing identity not found in the keychain — signing ad-hoc." >&2
	echo "         set ESCAPEMENT_SIGN_IDENTITY to build a distributable app." >&2
	IDENTITY="-"
fi
[ "$IDENTITY" = "-" ] && TIMESTAMP_FLAG="--timestamp=none"

echo "Building $APP_NAME and $AGENT_NAME ($CONFIG${ARCH_FLAGS:+, universal})…"
swift build -c "$CONFIG" $ARCH_FLAGS --product "$APP_NAME"
swift build -c "$CONFIG" $ARCH_FLAGS --product "$AGENT_NAME"

echo "Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
	"$APP/Contents/Library/LaunchAgents" "$APP/Contents/Library/LoginItems"

# The agent is a nested application bundle, not a bare executable, so that it
# has its own bundle identifier. Sharing the app's identifier made
# LaunchServices deliver the app's quit AppleEvents to the agent, and made
# "open the app" activate the agent instead of launching the GUI.
AGENT_APP="$APP/Contents/Library/LoginItems/$AGENT_NAME.app"
mkdir -p "$AGENT_APP/Contents/MacOS" "$AGENT_APP/Contents/Resources" \
	"$AGENT_APP/Contents/Library/LaunchAgents"

cp "$BUILD_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$BUILD_DIR/$AGENT_NAME" "$AGENT_APP/Contents/MacOS/$AGENT_NAME"
cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/App/AgentInfo.plist" "$AGENT_APP/Contents/Info.plist"
cp "$ROOT/App/$AGENT_PLIST" "$APP/Contents/Library/LaunchAgents/$AGENT_PLIST"
# The agent also needs the plist inside its *own* bundle: SMAppService resolves
# `agent(plistName:)` against the calling process's Bundle.main, and the agent's
# menu can turn background backups off.
cp "$ROOT/App/$AGENT_PLIST" "$AGENT_APP/Contents/Library/LaunchAgents/$AGENT_PLIST"
printf 'APPL????' > "$AGENT_APP/Contents/PkgInfo"

# Two icons, both required — see scripts/make-icons.swift for why. Escapement
# .icns is the bundle icon macOS clips to its own rounded-rect; the free-form
# one is installed as the Dock tile at launch, where no clip applies. Missing
# either is a build error rather than a silently plain-looking app.
for icon in Escapement EscapementFreeform; do
	if [ ! -f "$ROOT/App/Icon/$icon.icns" ]; then
		echo "error: App/Icon/$icon.icns is missing — run: swift scripts/make-icons.swift" >&2
		exit 1
	fi
	cp "$ROOT/App/Icon/$icon.icns" "$APP/Contents/Resources/$icon.icns"
done

# The agent draws the menu bar extra, so it needs the free-form mark too.
cp "$ROOT/App/Icon/EscapementFreeform.icns" "$AGENT_APP/Contents/Resources/"

# Bundle EscapementKit's resource bundle (fixtures are test-only, but the
# resource-bundle machinery is copied so Bundle.module resolves if used).
if compgen -G "$BUILD_DIR/"'*.bundle' > /dev/null; then
	cp -R "$BUILD_DIR/"*.bundle "$APP/Contents/Resources/" 2>/dev/null || true
fi

# PkgInfo is a small courtesy for a well-formed bundle.
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "Signing…"
# Sign the nested agent bundle first, then the app bundle around it. Both get
# the Hardened Runtime; neither is sandboxed, because they run tmutil. The
# identifier comes from the nested Info.plist now, so it is not forced here.
codesign --force --options runtime \
	--entitlements "$ROOT/App/Escapement.entitlements" \
	--sign "$IDENTITY" \
	$TIMESTAMP_FLAG \
	"$AGENT_APP"

codesign --force --options runtime \
	--entitlements "$ROOT/App/Escapement.entitlements" \
	--sign "$IDENTITY" \
	--identifier "$BUNDLE_ID" \
	$TIMESTAMP_FLAG \
	"$APP"

echo "Verifying signature…"
codesign --verify --strict --verbose=2 "$APP"
# --deep catches a nested bundle whose own signature is broken, which the
# outer check alone will not.
codesign --verify --deep --strict "$APP"
echo "Agent identifier: $(codesign -dv "$AGENT_APP" 2>&1 | grep '^Identifier=')"
echo "Architectures:    $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"

echo "Built: $APP"
