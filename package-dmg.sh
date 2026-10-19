#!/bin/bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Package Agora for macOS as a .dmg, to run on other Macs without installing
# anything (no Homebrew, no Flutter) — the macOS counterpart of
# package-appimage.sh.
#
# What goes in: the Flutter release app (build/macos/Build/Products/Release/
# agora.app), which the Runner's "Embed Agora Native" build phase
# (macos/embed_native.sh) has already filled: agorad in Contents/MacOS, and in
# Contents/Frameworks the shim, the AT libraries and every Homebrew dylib they
# load, all with @rpath install names.
#
# SIGNING. Without $SIGN_IDENTITY the app keeps the ad-hoc signature Xcode gave
# it: it runs on this Mac, and on another only after the user clears the
# quarantine (right-click > Open, or `xattr -dr com.apple.quarantine`). For
# distribution set SIGN_IDENTITY to a "Developer ID Application: ..." identity
# from your keychain: everything is re-signed inside-out with the hardened
# runtime and a secure timestamp, as notarization requires. Then set
# NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile name and the
# DMG is notarized and stapled, so it opens anywhere without a warning.
#
# ARCHITECTURE. The native layer is built for this Mac's architecture only
# (Homebrew bottles are single-arch), so the app runs on Macs of the same kind:
# built on Apple silicon, it needs Apple silicon. The script prints which.
#
# Needs: Xcode command line tools (codesign, hdiutil, otool, lipo; notarytool
# and stapler for notarization).
#
# Usage:
#   ./package-dmg.sh                    # build (release) + package
#   SKIP_BUILD=1 ./package-dmg.sh       # package the release app already built
#
# Env:
#   SKIP_BUILD=1      do not run ./build.sh; use the app already built
#   APP=<path>        package this .app instead of the release one
#   OUT_DIR=<dir>     where the .dmg goes (default build/dmg)
#   SIGN_IDENTITY=<i> codesign identity (Developer ID Application) to re-sign with
#   NOTARY_PROFILE=<p> notarytool keychain profile; notarize + staple the DMG
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "package-dmg.sh runs on macOS (use package-appimage.sh on Linux)"
for t in codesign hdiutil otool lipo; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found (install the Xcode command line tools: xcode-select --install)"
done

VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
VERSION="${VERSION:-0.0.0}"
ARCH="$(uname -m)"
OUT_DIR="${OUT_DIR:-$ROOT/build/dmg}"
OUTPUT="$OUT_DIR/Agora-$VERSION-macos-$ARCH.dmg"

# --- 1. build ---------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ] && [ -z "${APP:-}" ]; then
  log "Building Agora (release): ./build.sh macos"
  FLUTTER_MODE=--release ./build.sh macos
fi
APP="${APP:-$ROOT/build/macos/Build/Products/Release/agora.app}"
[ -d "$APP" ] || die "no app at $APP (build it, or set APP=)"

# --- 2. the bundle is self-contained ----------------------------------------
# Every library reference resolves inside the app or to the OS; nothing points
# at Homebrew or the build tree.
log "Checking $APP is self-contained"
FW="$APP/Contents/Frameworks"
[ -x "$APP/Contents/MacOS/agorad" ] || die "agorad is not in the app; was the native layer built before flutter build? (./build.sh macos)"
[ -e "$FW/libagora_shim.dylib" ] || die "libagora_shim.dylib is not in the app (./build.sh macos)"
bad=0
while IFS= read -r f; do
  while IFS= read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*) ;;
      @rpath/*) [ -e "$FW/${dep#@rpath/}" ] || { echo "  $(basename "$f") needs $dep, not in Frameworks"; bad=1; } ;;
      @executable_path/*|@loader_path/*) ;;
      *) echo "  $(basename "$f") loads $dep from outside the app"; bad=1 ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done < <(echo "$APP/Contents/MacOS/agorad"; find "$FW" -maxdepth 1 -name '*.dylib')
[ "$bad" = 0 ] || die "the app is not self-contained (re-run ./build.sh macos)"

native_arch="$(lipo -archs "$APP/Contents/MacOS/agorad")"
log "Native layer architecture: $native_arch (the app runs on $native_arch Macs only)"

# --- 3. sign -----------------------------------------------------------------
if [ -n "${SIGN_IDENTITY:-}" ]; then
  log "Signing with \"$SIGN_IDENTITY\" (hardened runtime, timestamp), inside-out"
  sign=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  # Leaves first: the loose dylibs and agorad, then the frameworks, then the app.
  while IFS= read -r f; do "${sign[@]}" "$f"; done \
    < <(find "$FW" -maxdepth 1 -name '*.dylib')
  "${sign[@]}" "$APP/Contents/MacOS/agorad"
  while IFS= read -r f; do "${sign[@]}" "$f"; done \
    < <(find "$FW" -maxdepth 1 -name '*.framework')
  "${sign[@]}" --entitlements "$ROOT/macos/Runner/Release.entitlements" "$APP"
else
  log "SIGN_IDENTITY not set: keeping Xcode's signature (fine for this Mac; see the header for distribution)"
fi
log "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 4. DMG ------------------------------------------------------------------
log "Creating $OUTPUT"
mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/agora-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUTPUT"
hdiutil create -volname "Agora" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT" >/dev/null
[ -n "${SIGN_IDENTITY:-}" ] && codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUTPUT"

# --- 5. notarize -------------------------------------------------------------
if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${SIGN_IDENTITY:-}" ] || die "notarization needs a Developer ID signature: set SIGN_IDENTITY too"
  log "Notarizing (profile $NOTARY_PROFILE); this waits for Apple"
  xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUTPUT"
fi

log "Done: $OUTPUT"
echo "    Copy agora.app to /Applications and open it. Node state goes to"
echo "    ~/Library/Application Support/Agora. AT discovery needs UDP 27787 on the LAN;"
echo "    macOS asks once for local network access."
