#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Package Agora as an AppImage, to run on other Linux machines without
# installing anything.
#
# What goes in:
#   - the Flutter release bundle (build/linux/<arch>/release/bundle): the app,
#     its data/, and lib/ with agorad, libagora_shim, libautonomous_trust and the
#     extension libraries (linux/CMakeLists.txt already bundles those);
#   - libethne_agora.so (businesses/polities), when the native build made it;
#   - the system libraries the AT core needs that a target machine may lack or
#     carry at another soname: libsodium, libjansson, libprotobuf-c, libprotobuf,
#     libuuid. Found by walking ldd, not by a fixed list.
# What stays out, on purpose: glibc, libstdc++/libgcc_s, zlib, and the whole
# GTK/graphics stack. Those come from the target, as every AppImage expects;
# bundling GTK or glibc breaks more machines than it fixes.
#
# PORTABILITY FLOOR. An AppImage runs only where glibc is at least as new as
# the newest symbol version anything inside it needs. This script prints that
# floor at the end. Built on Ubuntu 26.04 it is GLIBC_2.38 (from the system
# libprotobuf/libjansson it bundles), i.e. Ubuntu 24.04, Debian 13, Fedora 39
# or newer. To reach older machines, build on the oldest distro you want to
# support; nothing in this script can lower the floor.
#
# Target machines need: a desktop with GTK 3 (any mainstream one), FUSE 2
# (libfuse2) to mount the AppImage, or else run it with
# --appimage-extract-and-run, and UDP port 27787 open on the LAN, which AT's
# discovery broadcasts on. Node state goes to $XDG_STATE_HOME/agora (else
# ~/.local/state/agora), outside the read-only image.
#
# Needs: appimagetool (https://github.com/AppImage/appimagetool/releases),
# either on PATH or named by $APPIMAGETOOL, and the `file` command, which
# appimagetool calls. Without it the script still builds
# the AppDir and says how to finish.
#
# Usage:
#   ./package-appimage.sh                  # build (release) + package
#   SKIP_BUILD=1 ./package-appimage.sh     # package an existing release bundle
#
# Env:
#   SKIP_BUILD=1      do not run ./build.sh; use the bundle already built
#   BUNDLE=<dir>      package this Flutter bundle instead of the release one
#   OUT_DIR=<dir>     where the AppDir and the .AppImage go (default build/appimage)
#   ICON=<png>        app icon, ideally 256x256 (default: assets/icon/agora-256.png)
#   APPIMAGETOOL=<p>  path to appimagetool
#   RUNTIME_FILE=<p>  AppImage runtime stub (default: runtime-<arch> beside appimagetool;
#                     else appimagetool downloads it; get it from
#                     https://github.com/AppImage/type2-runtime/releases)
#   APPDIR_ONLY=1     stop after assembling the AppDir
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$(uname -m)" in
  x86_64)  FLUTTER_ARCH=x64;   APPIMAGE_ARCH=x86_64 ;;
  aarch64) FLUTTER_ARCH=arm64; APPIMAGE_ARCH=aarch64 ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

APP_ID="com.tekfive.agora"          # linux/CMakeLists.txt APPLICATION_ID
VERSION="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)"
VERSION="${VERSION:-0.0.0}"
OUT_DIR="${OUT_DIR:-$ROOT/build/appimage}"
APPDIR="$OUT_DIR/Agora.AppDir"
OUTPUT="$OUT_DIR/Agora-$VERSION-$APPIMAGE_ARCH.AppImage"

# --- 1. build ---------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ] && [ -z "${BUNDLE:-}" ]; then
  log "Building Agora (release): ./build.sh linux"
  FLUTTER_MODE=--release ./build.sh linux
fi
BUNDLE="${BUNDLE:-$ROOT/build/linux/$FLUTTER_ARCH/release/bundle}"
[ -x "$BUNDLE/agora" ] || die "no Flutter bundle at $BUNDLE (run without SKIP_BUILD, or set BUNDLE)"
for f in agorad libagora_shim.so libautonomous_trust.so libat_social.so; do
  [ -e "$BUNDLE/lib/$f" ] || die "$BUNDLE/lib/$f is missing: the bundle is not self-contained (build the native layer first; see linux/CMakeLists.txt)"
done
case "$BUNDLE" in */debug/*) log "WARNING: $BUNDLE is a DEBUG bundle (JIT, slow, large); ship a release one" ;; esac

# --- 2. AppDir ----------------------------------------------------------------
log "Assembling $APPDIR"
rm -rf "$APPDIR"
APPLIB="$APPDIR/usr/lib/agora"      # the Flutter bundle, laid out as it expects
mkdir -p "$APPLIB" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE/." "$APPLIB/"

ETHNE="$ROOT/native/build/libethne_agora.so"
if [ -f "$ETHNE" ]; then
  cp "$ETHNE" "$APPLIB/lib/"
else
  log "WARNING: $ETHNE not built (no cargo?); the AppImage will have no business/polity support"
fi

# --- 3. system libraries ------------------------------------------------------
# Never bundle these: the target provides them, and a bundled copy fights it.
EXCLUDE='^(ld-linux.*|linux-vdso.*|libc|libm|libdl|libpthread|librt|libresolv|libutil|libstdc\+\+|libgcc_s|libz|libgtk-3|libgdk-3|libgdk_pixbuf-2\.0|libglib-2\.0|libgobject-2\.0|libgio-2\.0|libgmodule-2\.0|libpango.*|libcairo.*|libharfbuzz|libatk.*|libepoxy|libfontconfig|libfreetype|libX.*|libxcb.*|libwayland.*|libGL.*|libEGL|libdrm|libgbm)(\.so.*)?$'

is_elf() { [ -f "$1" ] && [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }

declare -A SEEN=()
bundle_deps() { # elf
  local line name path
  while IFS= read -r line; do
    name="$(awk '{print $1}' <<<"$line")"
    [[ "$name" =~ $EXCLUDE ]] && continue
    [ -e "$APPLIB/lib/$name" ] && continue          # already in the bundle
    [ -n "${SEEN[$name]:-}" ] && continue
    if [[ "$line" == *"not found"* ]]; then
      die "$(basename "$1") needs $name, which is not installed here (install it, e.g. via ./setup.sh)"
    fi
    path="$(awk '{print $3}' <<<"$line")"
    SEEN[$name]=1
    cp -L "$path" "$APPLIB/lib/$name"
    log "  bundled $name  (from $path)"
    bundle_deps "$APPLIB/lib/$name"
  done < <(ldd "$1" 2>/dev/null | grep '=>' | sed 's/^[[:space:]]*//')
}
log "Bundling the system libraries the AT core needs"
while IFS= read -r -d '' f; do
  if is_elf "$f"; then bundle_deps "$f"; fi
done < <(find "$APPLIB" -type f -print0)

# --- 4. launcher, desktop entry, icon -----------------------------------------
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# Agora AppImage launcher. The bundle's own RUNPATHs ($ORIGIN) find Agora's
# libraries; LD_LIBRARY_PATH covers the bundled system ones (libprotobuf and
# friends have no RUNPATH of their own). agorad inherits both.
HERE="$(dirname "$(readlink -f "$0")")"
LIB="$HERE/usr/lib/agora/lib"
export LD_LIBRARY_PATH="$LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [ -z "${AGORA_ETHNE_PATH:-}" ] && [ -f "$LIB/libethne_agora.so" ]; then
  export AGORA_ETHNE_PATH="$LIB/libethne_agora.so"
fi
exec "$HERE/usr/lib/agora/agora" "$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/usr/share/applications/$APP_ID.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Agora
Comment=A decentralized, local-first social network on AutonomousTrust
Exec=agora
Icon=$APP_ID
Categories=Network;Chat;
Terminal=false
EOF
cp "$APPDIR/usr/share/applications/$APP_ID.desktop" "$APPDIR/"

ICON_DST="$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"
[ -z "${ICON:-}" ] && [ -f "$ROOT/assets/icon/agora-256.png" ] && ICON="$ROOT/assets/icon/agora-256.png"
if [ -n "${ICON:-}" ]; then
  [ -f "$ICON" ] || die "ICON=$ICON does not exist"
  cp "$ICON" "$ICON_DST"
else
  log "No icon found; generating a plain placeholder (set ICON=<png> for a real one)"
  python3 - "$ICON_DST" <<'PY'
import struct, sys, zlib
w = h = 256
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
rows = bytearray()
for y in range(h):
    rows.append(0)
    for x in range(w):
        dx, dy = x - 127.5, y - 127.5
        inside = dx * dx + dy * dy <= 118 * 118
        rows += bytes((38, 99, 170, 255) if inside else (0, 0, 0, 0))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) \
    + chunk(b'IDAT', zlib.compress(bytes(rows), 9)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY
fi
cp "$ICON_DST" "$APPDIR/$APP_ID.png"
if [ -f "$ROOT/assets/icon/agora.svg" ]; then
  mkdir -p "$APPDIR/usr/share/icons/hicolor/scalable/apps"
  cp "$ROOT/assets/icon/agora.svg" "$APPDIR/usr/share/icons/hicolor/scalable/apps/$APP_ID.svg"
fi
ln -sf "$APP_ID.png" "$APPDIR/.DirIcon"

# --- 5. report the floor -------------------------------------------------------
if command -v objdump >/dev/null 2>&1; then
  # Every loop body and pipeline here must succeed whatever the file order:
  # under `set -e -o pipefail` a trailing non-ELF, or no match, would end the
  # script silently.
  SYMS="$(find "$APPLIB" -type f -print0 | while IFS= read -r -d '' f; do
            if is_elf "$f"; then objdump -T "$f" 2>/dev/null || true; fi
          done)"
  FLOOR="$(grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' <<<"$SYMS" | sort -Vu | tail -1 || true)"
  CXXFLOOR="$(grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' <<<"$SYMS" | sort -Vu | tail -1 || true)"
  log "Target machines need at least ${FLOOR:-?} (glibc) and ${CXXFLOOR:-?} (libstdc++)"
fi

if [ "${APPDIR_ONLY:-0}" = "1" ]; then
  log "AppDir ready: $APPDIR (APPDIR_ONLY=1, not packaging)"
  exit 0
fi

# --- 6. package ------------------------------------------------------------------
TOOL="${APPIMAGETOOL:-$(command -v appimagetool || command -v "appimagetool-$APPIMAGE_ARCH.AppImage" || true)}"
if [ -z "$TOOL" ] || [ ! -x "$TOOL" ]; then
  log "appimagetool not found. The AppDir is ready at:"
  log "  $APPDIR"
  log "Get appimagetool-$APPIMAGE_ARCH.AppImage from"
  log "  https://github.com/AppImage/appimagetool/releases"
  log "then re-run with APPIMAGETOOL=/path/to/it SKIP_BUILD=1 $0"
  exit 1
fi
command -v file >/dev/null 2>&1 || die "appimagetool needs the 'file' command: sudo apt install file (AppDir left at $APPDIR)"
log "Packaging $OUTPUT"
rm -f "$OUTPUT"
# appimagetool is itself an AppImage; this lets it run without FUSE on the build host.
# appimagetool otherwise downloads the runtime stub from GitHub on every run,
# which fails behind proxies that send no Content-Length. Use a local copy when
# there is one: $RUNTIME_FILE, or runtime-<arch> next to appimagetool.
RUNTIME="${RUNTIME_FILE:-$(dirname "$(readlink -f "$TOOL")")/runtime-$APPIMAGE_ARCH}"
RUNTIME_ARGS=()
if [ -f "$RUNTIME" ]; then
  RUNTIME_ARGS=(--runtime-file "$RUNTIME")
  log "Using runtime $RUNTIME"
fi
APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$APPIMAGE_ARCH" "$TOOL" "${RUNTIME_ARGS[@]}" "$APPDIR" "$OUTPUT"
log "Done: $OUTPUT"
log "On the target: chmod +x $(basename "$OUTPUT") && ./$(basename "$OUTPUT")"
