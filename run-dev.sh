#!/bin/sh
# Run Agora from the source tree against the native layer in native/build
# (build it first with ./build.sh). Linux or macOS.

ROOT="$(cd "$(dirname "$0")" && pwd)"
NATIVE="$ROOT/native/build"
FLUTTER_PATH="${FLUTTER_HOME:-/opt/flutter}/bin"

DAEMON="$NATIVE/agorad"
case "$(uname -s)" in
  Darwin) DEVICE=macos; SO=dylib ;;
  MINGW*|MSYS*)
    # Windows (MSYS2 UCRT64 shell): native paths, and the DLLs found on PATH.
    DEVICE=windows; SO=dll
    DAEMON="$(cygpath -m "$NATIVE/agorad.exe")"
    for d in "$NATIVE" "$NATIVE/at_core" "$NATIVE"/at_core/extensions/*; do PATH="$d:$PATH"; done
    NATIVE="$(cygpath -m "$NATIVE")"
    ;;
  *)      DEVICE=linux; SO=so ;;
esac

cd "$ROOT" || exit 1
# LD_LIBRARY_PATH is for Linux; on macOS the build-tree rpath finds the AT libraries.
PATH="$PATH:$FLUTTER_PATH" \
AGORA_DAEMON_PATH="$DAEMON" \
AGORA_SHIM_PATH="$NATIVE/libagora_shim.$SO" \
LD_LIBRARY_PATH="$NATIVE/at_core${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
exec flutter run -d "$DEVICE"
