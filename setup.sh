#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Install the dependencies needed to build & test Agora on Linux.
#
# TOOLCHAIN: Agora builds entirely with the SYSTEM toolchain — conda is NOT used
# for the build (mixing conda with the system GTK stack breaks the Flutter build;
# see build.sh). So this installs, via apt, EVERYTHING the build needs:
#   - the C/C++ toolchain + CMake/Ninja/pkg-config,
#   - the AT C-core deps (libsodium, jansson, libuuid, protobuf, protobuf-c, ssl),
#   - the Flutter Linux desktop toolchain (GTK), and
#   - the Flutter SDK (+ Dart).
# (conda is still fine for the AutonomousTrust *Python* inspector/services — it
# is simply not on the Agora build path, and build.sh strips it if active.)
#
# Usage:   ./setup.sh
# Env:     FLUTTER_HOME   (default /opt/flutter)
#          FLUTTER_CHANNEL(default stable)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"
FLUTTER_CHANNEL="${FLUTTER_CHANNEL:-stable}"

log() { printf '\n==> %s\n' "$*"; }

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# Tolerate sandbox clock skew (apt "Release file is not valid yet").
APT_OPTS=(-o Acquire::Check-Date=false)

# --- 1. System packages: full build toolchain + AT C deps + GTK --------------
# Everything the build needs, from apt — no conda on the build path.
log "Installing build toolchain, AT C-core deps, and GTK (apt)"
$SUDO apt-get "${APT_OPTS[@]}" update || true
$SUDO apt-get "${APT_OPTS[@]}" -y install \
  git curl unzip xz-utils zip \
  build-essential clang cmake ninja-build pkg-config \
  libgtk-3-dev \
  libsodium-dev libjansson-dev uuid-dev \
  libprotobuf-c-dev protobuf-c-compiler libprotobuf-dev protobuf-compiler \
  libssl-dev

# On Ubuntu 25.10+/26.04, gdk-pixbuf's pkg-config Requires.private pulls in
# glycin-2, and GTK's pkg-config chain adds -I/usr/include/glycin-2. If that
# headers dir is missing, the Flutter runner's CMake dies: PkgConfig::GTK
# "includes non-existent path /usr/include/glycin-2".
# Prefer installing the real headers (best-effort — the -dev package may be
# absent from a given distro's sources); --reinstall also heals a partial install.
$SUDO apt-get "${APT_OPTS[@]}" -y install --reinstall libglycin-2-dev 2>/dev/null \
  || $SUDO apt-get "${APT_OPTS[@]}" -y install libglycin-2-dev 2>/dev/null \
  || echo "note: libglycin-2-dev not installable here; using the dir-stub fallback below"

# Safety net (package-independent): create any include dir that an installed
# .pc file references but that does not exist (e.g. /usr/include/glycin-2,
# /usr/include/sysprof-6 on Ubuntu 26.04) — otherwise CMake fails the Flutter
# runner's generate. Reads .pc files directly (no pkg-config), so an active
# conda env can't shadow them. build.sh runs the same helper before each build.
bash "$ROOT/native/stub-pkgconfig-includes.sh" || true

# AT's C codegen (preprocess.py) calls `python`. Provide a system shim if there
# is no `python` on PATH (the build no longer relies on a conda-provided one).
if ! command -v python >/dev/null 2>&1; then
  log "No 'python' on PATH; installing python-is-python3 shim"
  $SUDO apt-get "${APT_OPTS[@]}" -y install python-is-python3 || true
fi

# --- 2. Flutter SDK ----------------------------------------------------------
if [ -x "$FLUTTER_HOME/bin/flutter" ]; then
  log "Flutter already present at $FLUTTER_HOME"
else
  log "Installing Flutter ($FLUTTER_CHANNEL) to $FLUTTER_HOME"
  $SUDO mkdir -p "$FLUTTER_HOME"
  $SUDO chown "$(id -u):$(id -g)" "$FLUTTER_HOME"
  git clone --branch "$FLUTTER_CHANNEL" --depth 1 \
    https://github.com/flutter/flutter.git "$FLUTTER_HOME"
fi
export PATH="$PATH:$FLUTTER_HOME/bin"
git config --global --add safe.directory "$FLUTTER_HOME" 2>/dev/null || true

# --- 3. Persist PATH ---------------------------------------------------------
persist_path() {
  local f="$1"
  [ -n "$f" ] || return 1
  grep -qF "$FLUTTER_HOME/bin" "$f" 2>/dev/null && return 0
  echo 'export PATH="$PATH:'"$FLUTTER_HOME"'/bin"' | $SUDO tee -a "$f" >/dev/null
}
if [ -n "${CLAUDE_ENV_FILE:-}" ] && persist_path "$CLAUDE_ENV_FILE"; then
  log "PATH persisted to $CLAUDE_ENV_FILE"
elif persist_path "$HOME/.bashrc"; then
  log "PATH persisted to ~/.bashrc (run: source ~/.bashrc, or open a new shell)"
fi

# --- 4. Flutter desktop config + engine precache -----------------------------
log "Enabling Flutter desktop + precaching the Linux engine (downloads Dart SDK)"
flutter config --enable-linux-desktop --enable-macos-desktop
flutter precache --linux
flutter --version

# --- 5. Done -----------------------------------------------------------------
cat <<EOF

==> Setup complete.

Next (no conda needed — the build uses the system toolchain):
  1. Build:   ./build.sh          # native layer + Flutter app (linux/x86_64)
  2. Test:    ./test.sh           # flutter analyze + unit tests

If 'flutter' is not found in a new shell, add: export PATH="\$PATH:$FLUTTER_HOME/bin"
EOF
