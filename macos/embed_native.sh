#!/bin/bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Embed Agora's native layer into agora.app — the macOS counterpart of the
# install rules in linux/CMakeLists.txt plus the library half of
# package-appimage.sh.
#
#   Contents/MacOS/agorad                the daemon the app spawns
#   Contents/Frameworks/libagora_shim.dylib, libautonomous_trust.dylib,
#                       libat_<layer>.dylib, libethne_agora.dylib (if built),
#                       and every non-system dylib those load (Homebrew's
#                       libsodium, jansson, protobuf, protobuf-c, abseil, ...)
#
# Every copied dylib gets an @rpath install name and every reference to a
# bundled library is rewritten to @rpath/<name>, so the app needs no Homebrew
# on the machine that runs it. Build-tree rpaths are removed. Each file is then
# signed (inside-out: everything here before Xcode signs the app itself), with
# the hardened runtime when the configuration enables it.
#
# Runs as the Runner target's "Embed Agora Native" build phase, after Flutter's
# own embed, from the environment Xcode provides. It can also be run by hand on
# a built bundle:   macos/embed_native.sh path/to/agora.app
#
# Env:  AGORA_NATIVE_BUILD_DIR  native build output (default: ../native/build)
#       AGORA_SIGN_IDENTITY     identity when run by hand (default: ad-hoc "-")
#       AGORA_HARDENED=1        sign with --options runtime when run by hand
#       AGORA_LIB_SEARCH        extra ':'-separated dirs to find an @rpath
#                               dependency in (default: $(brew --prefix)/lib)
#
# bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NATIVE="${AGORA_NATIVE_BUILD_DIR:-$HERE/../native/build}"

if [ $# -ge 1 ]; then
  APP="$(cd "$1" && pwd)"
  FW="$APP/Contents/Frameworks"
  BIN="$APP/Contents/MacOS"
  IDENTITY="${AGORA_SIGN_IDENTITY:--}"
  HARDENED="${AGORA_HARDENED:-0}"
else
  FW="${TARGET_BUILD_DIR:?run from Xcode or pass the .app}/${FRAMEWORKS_FOLDER_PATH:?}"
  BIN="$TARGET_BUILD_DIR/${EXECUTABLE_FOLDER_PATH:?}"
  # Empty when code signing is off; "-" for "Sign to Run Locally".
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
  [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] && IDENTITY=""
  HARDENED=0
  [ "${ENABLE_HARDENED_RUNTIME:-NO}" = "YES" ] && HARDENED=1
fi

# Where an @rpath dependency the binary's own rpaths miss may live: Homebrew
# names its libraries by absolute path, but a library installed with an @rpath
# id (conda-forge's, say) leaves the reference for us to find.
LIB_SEARCH="${AGORA_LIB_SEARCH:-}"
if [ -z "$LIB_SEARCH" ] && command -v brew >/dev/null 2>&1; then
  LIB_SEARCH="$(brew --prefix)/lib"
fi

warn() { echo "warning: Agora: $*" >&2; }
die()  { echo "error: Agora: $*" >&2; exit 1; }

command -v otool >/dev/null 2>&1 || die "otool not found (install the Xcode command line tools)"

mkdir -p "$FW" "$BIN"

# Files this run placed in the bundle, one per line, for the rpath/sign passes.
EMBEDDED="$(mktemp "${TMPDIR:-/tmp}/agora-embed.XXXXXX")"
trap 'rm -f "$EMBEDDED"' EXIT

is_system_lib() {
  case "$1" in
    /usr/lib/*|/System/*) return 0 ;;
    *) return 1 ;;
  esac
}

# The LC_RPATH entries of a Mach-O file, one per line.
rpaths_of() {
  otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; print $2}'
}

# Find what a load command names, as the loader would: an absolute path as is,
# @loader_path / @executable_path against the file's original directory, and
# @rpath against the file's own rpaths.
resolve_dep() {   # <dep> <file> <file's original dir>
  local dep="$1" file="$2" origdir="$3" rp cand
  case "$dep" in
    @rpath/*)
      while IFS= read -r rp; do
        rp="${rp/@loader_path/$origdir}"
        rp="${rp/@executable_path/$origdir}"
        cand="$rp/${dep#@rpath/}"
        if [ -e "$cand" ]; then echo "$cand"; return 0; fi
      done < <(rpaths_of "$file")
      local IFS=':'
      for rp in $LIB_SEARCH; do
        cand="$rp/${dep#@rpath/}"
        if [ -e "$cand" ]; then echo "$cand"; return 0; fi
      done
      return 1 ;;
    @loader_path/*|@executable_path/*)
      cand="$origdir/${dep#*/}"
      [ -e "$cand" ] && { echo "$cand"; return 0; }
      return 1 ;;
    /*)
      [ -e "$dep" ] && { echo "$dep"; return 0; }
      return 1 ;;
  esac
  return 1
}

# Copy one file into the bundle (dereferencing symlinks) and record it.
place() {   # <src> <dest-dir>
  local dest
  dest="$2/$(basename "$1")"
  cp -fL "$1" "$dest"
  chmod u+w "$dest"
  echo "$dest|$(cd "$(dirname "$1")" && pwd -P)" >> "$EMBEDDED"
}

# --- 1. Agora's own artifacts --------------------------------------------------
LAYERS="physics calibration certificates prequential replication social rendezvous first_contact"
missing=0
if [ -x "$NATIVE/agorad" ]; then place "$NATIVE/agorad" "$BIN"; else warn "missing $NATIVE/agorad"; missing=1; fi
for f in "$NATIVE/libagora_shim.dylib" "$NATIVE/at_core/libautonomous_trust.dylib"; do
  if [ -e "$f" ]; then place "$f" "$FW"; else warn "missing $f"; missing=1; fi
done
for l in $LAYERS; do
  f="$NATIVE/at_core/extensions/$l/libat_$l.dylib"
  if [ -e "$f" ]; then place "$f" "$FW"; else warn "missing $f"; missing=1; fi
done
# Optional: built only when cargo is present.
[ -e "$NATIVE/libethne_agora.dylib" ] && place "$NATIVE/libethne_agora.dylib" "$FW"
if [ "$missing" = 1 ]; then
  warn "the app bundle is NOT self-contained; build the native layer first (./build.sh macos)"
fi

# --- 2. Pull in the non-system dylibs they load, transitively ----------------
# A worklist over EMBEDDED: each new dependency is appended and visited in turn.
i=1
while :; do
  entry="$(sed -n "${i}p" "$EMBEDDED")"
  [ -n "$entry" ] || break
  file="${entry%%|*}"; origdir="${entry#*|}"
  # otool -L: line 1 is the file name; for a dylib line 2 is its own id.
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    is_system_lib "$dep" && continue
    name="$(basename "$dep")"
    [ "$name" = "$(basename "$file")" ] && continue    # its own install name
    if [ ! -e "$FW/$name" ]; then
      src="$(resolve_dep "$dep" "$file" "$origdir")" \
        || die "$(basename "$file") needs $dep, which is not on this machine"
      place "$src" "$FW"
    fi
    # Point the reference at the bundled copy.
    [ "$dep" = "@rpath/$name" ] || install_name_tool -change "$dep" "@rpath/$name" "$file"
  done < <(otool -L "$file" | tail -n +2 | awk '{print $1}')
  i=$((i + 1))
done

# --- 3. Install names and rpaths -----------------------------------------------
while IFS='|' read -r file _; do
  case "$file" in
    *.dylib) install_name_tool -id "@rpath/$(basename "$file")" "$file" ;;
  esac
  # Drop absolute rpaths (the native build tree, Homebrew's prefix): inside the
  # bundle only the @-relative ones may resolve anything.
  while IFS= read -r rp; do
    case "$rp" in /*) install_name_tool -delete_rpath "$rp" "$file" ;; esac
  done < <(rpaths_of "$file")
  if [ "$(dirname "$file")" = "$FW" ]; then want="@loader_path"; else want="@executable_path/../Frameworks"; fi
  # A here-string, not a pipe: under pipefail, grep -q exiting on the first
  # match can SIGPIPE the writer, and the 141 would re-add an existing rpath.
  grep -qxF "$want" <<< "$(rpaths_of "$file")" || install_name_tool -add_rpath "$want" "$file"
done < "$EMBEDDED"

# --- 4. Sign, inside-out -----------------------------------------------------
# install_name_tool invalidates any signature, so every embedded file is
# (re)signed. Xcode signs the app bundle itself afterwards.
if [ -n "$IDENTITY" ]; then
  opts=(--force --sign "$IDENTITY")
  [ "$HARDENED" = 1 ] && opts+=(--options runtime)
  [ "$IDENTITY" != "-" ] && opts+=(--timestamp)
  while IFS='|' read -r file _; do
    codesign "${opts[@]}" "$file"
  done < "$EMBEDDED"
fi

echo "Agora: embedded $(wc -l < "$EMBEDDED" | tr -d ' ') native files into $(dirname "$FW")"
