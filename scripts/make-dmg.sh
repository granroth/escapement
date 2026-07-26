#!/bin/bash
#
# Packages .build/Escapement.app into a distributable disk image.
#
# The image carries the app and a symlink to /Applications, which is the
# drag-to-install convention every Mac user already knows. It is signed with
# the same identity as the app so that Gatekeeper can check the download
# itself, not just the app inside it.
#
# Usage: scripts/make-dmg.sh [version]
#
# Environment:
#   ESCAPEMENT_SIGN_IDENTITY   codesign identity; "-" or absent means the image
#                              is left unsigned (fine for local testing).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Escapement"
APP="$ROOT/.build/$APP_NAME.app"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)}"
DMG="$ROOT/.build/$APP_NAME-$VERSION.dmg"
IDENTITY="${ESCAPEMENT_SIGN_IDENTITY:-}"

if [ ! -d "$APP" ]; then
	echo "error: $APP not found — run scripts/build-app.sh first." >&2
	exit 1
fi

echo "Staging…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Copy rather than move, and preserve the signature: ditto is signature-aware
# where a plain cp -R can disturb extended attributes.
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "Building image…"
rm -f "$DMG"
# UDZO is the compressed read-only format Gatekeeper expects for a download.
hdiutil create \
	-volname "$APP_NAME" \
	-srcfolder "$STAGE" \
	-fs HFS+ \
	-format UDZO \
	-ov \
	"$DMG" >/dev/null

if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
	echo "Signing image…"
	codesign --force --sign "$IDENTITY" --timestamp "$DMG"
	codesign --verify --strict --verbose=2 "$DMG"
else
	echo "note: no signing identity — image left unsigned."
fi

echo "Built: $DMG"
