#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Run Agora's tests: static analysis + the pure-Dart unit tests. These need no
# native build (they never load libagora_shim).
#
# Usage:
#   ./test.sh                 # analyze + test
#   ./test.sh --no-analyze    # tests only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

RUN_ANALYZE=1
[ "${1:-}" = "--no-analyze" ] && RUN_ANALYZE=0

# --- locate flutter ----------------------------------------------------------
if ! command -v flutter >/dev/null 2>&1; then
  if [ -x /opt/flutter/bin/flutter ]; then
    export PATH="$PATH:/opt/flutter/bin"
  else
    echo "error: 'flutter' not found on PATH (and not at /opt/flutter/bin)." >&2
    exit 1
  fi
fi

echo "==> Fetching Dart packages"
flutter pub get

if [ "$RUN_ANALYZE" = "1" ]; then
  echo "==> Static analysis (flutter analyze)"
  flutter analyze
fi

echo "==> Unit tests (flutter test)"
flutter test

echo
echo "==> Tests passed."
