#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Run Agora's tests: static analysis + the Dart tests. The unit tests need no
# native build (they never load libagora_shim). The integration test under
# test/integration/ DOES drive the real agorad + shim; it self-skips unless the
# native layer is built — this script wires it up when native/build exists.
#
# Usage:
#   ./test.sh                 # analyze + test (+ integration if native built)
#   ./test.sh --no-analyze    # tests only
#   ./test.sh --coverage      # also write coverage/lcov.info (may combine with above)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

RUN_ANALYZE=1
COVERAGE=0
for arg in "$@"; do
  case "$arg" in
    --no-analyze) RUN_ANALYZE=0 ;;
    --coverage)   COVERAGE=1 ;;
  esac
done

# --- wire the native layer for the integration test (if built) --------------
# The integration test loads libagora_shim over ffi (AGORA_SHIM_PATH) and spawns
# agorad (AGORA_DAEMON_PATH); libautonomous_trust resolves via LD_LIBRARY_PATH.
# Absent these (no ./build.sh yet), the integration test self-skips.
NATIVE="$ROOT/native/build"
if [ -x "$NATIVE/agorad" ] && [ -f "$NATIVE/libagora_shim.so" ] \
   && [ -f "$NATIVE/at_core/libautonomous_trust.so" ]; then
  export AGORA_DAEMON_PATH="$NATIVE/agorad"
  export AGORA_SHIM_PATH="$NATIVE/libagora_shim.so"
  export LD_LIBRARY_PATH="$NATIVE/at_core:${LD_LIBRARY_PATH:-}"
  echo "==> Native layer found — integration test ENABLED"
else
  echo "==> Native layer not built (run ./build.sh) — integration test will skip"
fi

# The Ethne polity cdylib (businesses = Ethne polities, Phase 3) is independent
# of the AT native layer; wire it whenever it is built, else that test skips.
if [ -f "$NATIVE/libethne_agora.so" ]; then
  export AGORA_ETHNE_PATH="$NATIVE/libethne_agora.so"
  echo "==> Ethne cdylib found — polity round-trip test ENABLED"
else
  echo "==> Ethne cdylib not built (run ./build.sh) — polity test will skip"
fi

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

echo "==> Tests (flutter test)"
if [ "$COVERAGE" = "1" ]; then
  flutter test --coverage
else
  flutter test
fi

# --- coverage summary --------------------------------------------------------
if [ "$COVERAGE" = "1" ] && [ -f coverage/lcov.info ]; then
  echo
  echo "==> Line coverage (coverage/lcov.info)"
  awk '
    /^SF:/    { f=$0; sub(/^SF:/,"",f); sub(/.*\/lib\//,"lib/",f); lf=0; lh=0 }
    /^LF:/    { lf=substr($0,4)+0 }
    /^LH:/    { lh=substr($0,4)+0 }
    /^end_of_record/ {
                pct = (lf>0)?100*lh/lf:0
                printf "    %-42s %6.1f%%  %d/%d\n", f, pct, lh, lf
                th+=lh; tf+=lf }
    END       { if (tf>0) {
                  printf "    %s\n", "------------------------------------------------------------"
                  printf "    %-42s %6.1f%%  %d/%d\n", "TOTAL", 100*th/tf, th, tf }
                else print "    (no coverage data)" }
  ' coverage/lcov.info
  # If lcov is installed, its own one-line summary is a handy cross-check.
  command -v lcov >/dev/null 2>&1 && lcov --summary coverage/lcov.info 2>/dev/null | sed 's/^/    /'
fi

echo
echo "==> Tests passed."
