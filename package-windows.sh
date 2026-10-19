#!/bin/bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Package Agora for Windows as a .zip, to run on other PCs without installing
# anything (no MSYS2, no Flutter) — the Windows counterpart of
# package-appimage.sh and package-dmg.sh.
#
# What goes in: the Flutter release bundle (build/windows/x64/runner/Release),
# which windows/CMakeLists.txt has already filled: agora.exe and Flutter's
# files, and beside them agorad.exe, the shim, the AT DLLs, Ethne's DLL when it
# was built, and every MinGW (UCRT64) DLL they load.
#
# Target PCs need Windows 10 1803 or newer (agorad reaches the app over an
# AF_UNIX socket) and the Microsoft Visual C++ runtime the Flutter runner
# links (usually present; otherwise vc_redist.x64.exe from Microsoft). Node
# state goes to %LOCALAPPDATA%\Agora. Windows Defender Firewall asks once
# whether agorad.exe may use the network; AT's discovery broadcasts on UDP
# 27787.
#
# SIGNING is not done here: an unsigned agora.exe runs, after SmartScreen's
# "More info > Run anyway". To sign, run signtool on agora.exe, agorad.exe and
# the DLLs before zipping (SIGN_CMD="signtool sign /a /fd SHA256 /tr <url>
# /td SHA256" is applied to each when set).
#
# Usage (from an MSYS2 UCRT64 shell):
#   ./package-windows.sh                  # build (release) + package
#   SKIP_BUILD=1 ./package-windows.sh     # package the release bundle already built
#
# Env:
#   SKIP_BUILD=1    do not run ./build.sh; use the bundle already built
#   BUNDLE=<dir>    package this bundle instead of the release one
#   OUT_DIR=<dir>   where the .zip goes (default build/windows-zip)
#   SIGN_CMD=<cmd>  a signing command run on each .exe and .dll first
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *) die "package-windows.sh runs on Windows, in an MSYS2 UCRT64 shell" ;;
esac
command -v zip >/dev/null 2>&1 || die "zip not found (pacman -S zip)"
command -v objdump >/dev/null 2>&1 || die "objdump not found (pacman -S mingw-w64-ucrt-x86_64-binutils)"

VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
VERSION="${VERSION:-0.0.0}"
OUT_DIR="${OUT_DIR:-$ROOT/build/windows-zip}"
OUTPUT="$OUT_DIR/Agora-$VERSION-windows-x64.zip"

# --- 1. build ---------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ] && [ -z "${BUNDLE:-}" ]; then
  log "Building Agora (release): ./build.sh windows"
  FLUTTER_MODE=--release ./build.sh windows
fi
BUNDLE="${BUNDLE:-$ROOT/build/windows/x64/runner/Release}"
[ -f "$BUNDLE/agora.exe" ] || die "no agora.exe in $BUNDLE (build it, or set BUNDLE=)"

# --- 2. the bundle is self-contained ----------------------------------------
# Every DLL an exe or DLL here imports is either beside it or part of Windows.
log "Checking $BUNDLE is self-contained"
[ -f "$BUNDLE/agorad.exe" ] || die "agorad.exe is not in the bundle (./build.sh windows builds the native layer first)"
[ -f "$BUNDLE/libagora_shim.dll" ] || die "libagora_shim.dll is not in the bundle (./build.sh windows)"
missing=0
for f in "$BUNDLE"/*.exe "$BUNDLE"/*.dll; do
  while IFS= read -r dll; do
    [ -e "$BUNDLE/$dll" ] && continue
    case "$(printf '%s' "$dll" | tr '[:upper:]' '[:lower:]')" in
      api-ms-*|ext-ms-*) continue ;;   # API sets: always Windows'
    esac
    # Part of Windows if the system has it.
    if [ -e "$(cygpath -W)/System32/$dll" ]; then continue; fi
    echo "  $(basename "$f") needs $dll, which is neither in the bundle nor in System32"
    missing=1
  done < <(objdump -p "$f" | sed -n 's/^[[:space:]]*DLL Name: //p')
done
[ "$missing" = 0 ] || die "the bundle is not self-contained (is AGORA_MINGW_BIN right? see windows/CMakeLists.txt)"

# --- 3. sign (optional) -------------------------------------------------------
if [ -n "${SIGN_CMD:-}" ]; then
  log "Signing each .exe and .dll: $SIGN_CMD"
  for f in "$BUNDLE"/*.exe "$BUNDLE"/*.dll; do
    # shellcheck disable=SC2086  # SIGN_CMD is a command line by design
    $SIGN_CMD "$(cygpath -w "$f")"
  done
fi

# --- 4. zip ------------------------------------------------------------------
log "Creating $OUTPUT"
mkdir -p "$OUT_DIR"
rm -f "$OUTPUT"
(cd "$BUNDLE/.." && zip -qr "$OUTPUT" "$(basename "$BUNDLE")")

log "Done: $OUTPUT"
echo "    Unzip anywhere and run agora.exe. Node state goes to %LOCALAPPDATA%\\Agora."
