#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Compiler-launcher for building the AutonomousTrust C core from Agora. Does two
# jobs, then execs the compiler:
#
#   1. Strips a bare `-Werror` so the core builds under a newer/stricter compiler
#      than AT was tuned for (e.g. GCC 15's -Wstringop-truncation) WITHOUT
#      editing AT source. Warnings still print; they just aren't fatal.
#
#   2. Chains to AT's own `cc-validate-output` launcher when present, preserving
#      its virtiofs/fuseblk .o-corruption retry. We need this because we install
#      THIS launcher via -DCMAKE_C_COMPILER_LAUNCHER, which requires
#      -DAT_CC_VALIDATE_OUTPUT=OFF (otherwise AT would overwrite our launcher
#      with its own) — and turning that off would otherwise drop the retry.
#
# CMake invokes a launcher as: <launcher> <compiler> <args...>
set -u

compiler="$1"; shift

args=()
for a in "$@"; do
  [ "$a" = "-Werror" ] && continue
  args+=("$a")
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validate="$here/../../../lib/autonomous_trust/src/c/cmake/cc-validate-output"

if [ -x "$validate" ]; then
  exec "$validate" "$compiler" ${args[@]+"${args[@]}"}
fi
exec "$compiler" ${args[@]+"${args[@]}"}
