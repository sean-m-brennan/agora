#!/bin/sh
# Build Agora's native layer for this OS and run the app from the source tree
# against it (`flutter run`, with hot reload). Linux, macOS, or Windows (from an
# MSYS2 UCRT64 shell). The build is incremental, so a rerun with nothing
# changed goes straight to the app.
#
# Env: as ./build.sh (FLUTTER_MODE, BUILD_TYPE, AGORA_STRICT, ...).

ROOT="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)" in
  Linux)        PLATFORM=linux ;;
  Darwin)       PLATFORM=macos ;;
  MINGW*|MSYS*) PLATFORM=windows ;;
  *)
    echo "run-dev.sh: unsupported OS '$(uname -s)' (Linux, macOS, or Windows via MSYS2)" >&2
    exit 2
    ;;
esac

exec "$ROOT/build.sh" "$PLATFORM" --run
