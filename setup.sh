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
# macOS: the same pieces from Homebrew instead of apt, plus Xcode (which
# `flutter build macos` needs; the command line tools alone are not enough).
# See setup_macos below.
#
# Windows: run from an MSYS2 UCRT64 shell (https://www.msys2.org; the
# "MSYS2 UCRT64" start-menu entry). The native layer is built with MSYS2's
# UCRT64 toolchain and packages (pacman), the Flutter runner with Visual Studio
# 2022's C++ tools, which `flutter build windows` requires. See setup_windows.
#
# Usage:   ./setup.sh
# Env:     FLUTTER_HOME   (default /opt/flutter; $HOME/flutter on macOS)
#          FLUTTER_CHANNEL(default stable)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_CHANNEL="${FLUTTER_CHANNEL:-stable}"

log() { printf '\n==> %s\n' "$*"; }

# --- macOS -----------------------------------------------------------------
setup_macos() {
  FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "error: Xcode is not installed. Install Xcode from the App Store, then run:" >&2
    echo "         sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch" >&2
    exit 1
  fi
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "error: only the command line tools are selected; flutter build macos needs Xcode:" >&2
    echo "         sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
  fi
  if ! command -v brew >/dev/null 2>&1; then
    echo "error: Homebrew not found; install it from https://brew.sh, then re-run." >&2
    exit 1
  fi

  log "Installing build tools and AT C-core deps (Homebrew)"
  # libuuid is part of macOS itself. Do NOT install ossp-uuid: its uuid.h is a
  # different API and would shadow the system one.
  brew install cmake ninja pkg-config libsodium jansson protobuf protobuf-c

  # Rust builds ethne_ffi (businesses); optional, the app runs without it.
  if ! command -v cargo >/dev/null 2>&1; then
    echo "note: Rust not found; businesses (ethne_ffi) will not be built."
    echo "      To add them: brew install rustup && rustup-init -y"
  fi

  if [ -x "$FLUTTER_HOME/bin/flutter" ]; then
    log "Flutter already present at $FLUTTER_HOME"
  else
    log "Installing Flutter ($FLUTTER_CHANNEL) to $FLUTTER_HOME"
    git clone --branch "$FLUTTER_CHANNEL" --depth 1 \
      https://github.com/flutter/flutter.git "$FLUTTER_HOME"
  fi
  export PATH="$PATH:$FLUTTER_HOME/bin"
  # zsh is the macOS login shell.
  if ! grep -qF "$FLUTTER_HOME/bin" "$HOME/.zprofile" 2>/dev/null; then
    echo 'export PATH="$PATH:'"$FLUTTER_HOME"'/bin"' >> "$HOME/.zprofile"
    log "PATH persisted to ~/.zprofile (open a new terminal, or: source ~/.zprofile)"
  fi

  log "Enabling Flutter macOS desktop + precaching the macOS engine"
  flutter config --enable-macos-desktop
  flutter precache --macos
  flutter --version

  cat <<EOF

==> Setup complete.

Next:
  1. Build:   ./build.sh macos      # native layer + agora.app ($(uname -m) only)
  2. Test:    ./test.sh
  3. Package: ./package-dmg.sh      # a .dmg for other Macs

If 'flutter' is not found in a new shell, add: export PATH="\$PATH:$FLUTTER_HOME/bin"
EOF
}

# --- Windows (MSYS2 UCRT64) ------------------------------------------------
setup_windows() {
  if [ "${MSYSTEM:-}" != "UCRT64" ]; then
    echo "error: run this from an MSYS2 UCRT64 shell (MSYSTEM=UCRT64, not '${MSYSTEM:-unset}')." >&2
    exit 1
  fi
  FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"

  log "Installing the UCRT64 toolchain and AT C-core deps (pacman)"
  pacman -S --needed --noconfirm git unzip zip \
    mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-cmake \
    mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-pkgconf \
    mingw-w64-ucrt-x86_64-python \
    mingw-w64-ucrt-x86_64-libsodium mingw-w64-ucrt-x86_64-jansson \
    mingw-w64-ucrt-x86_64-protobuf mingw-w64-ucrt-x86_64-protobuf-c \
    mingw-w64-ucrt-x86_64-check
  # Rust builds ethne_ffi (businesses); optional, the app runs without it.
  if ! command -v cargo >/dev/null 2>&1; then
    echo "note: Rust not found; businesses (ethne_ffi) will not be built."
    echo "      To add them: pacman -S mingw-w64-ucrt-x86_64-rust"
  fi

  # flutter build windows needs Visual Studio's C++ workload.
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  if [ ! -x "$vswhere" ] || [ -z "$("$vswhere" -latest -requires Microsoft.VisualStudio.Workload.VCTools Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath 2>/dev/null)" ]; then
    echo "warning: Visual Studio 2022 with 'Desktop development with C++' was not found;"
    echo "         flutter build windows needs it (the Build Tools edition is enough):"
    echo "         https://visualstudio.microsoft.com/downloads/"
  fi

  if [ -x "$FLUTTER_HOME/bin/flutter" ]; then
    log "Flutter already present at $FLUTTER_HOME"
  else
    log "Installing Flutter ($FLUTTER_CHANNEL) to $FLUTTER_HOME"
    git clone --branch "$FLUTTER_CHANNEL" --depth 1 \
      https://github.com/flutter/flutter.git "$FLUTTER_HOME"
  fi
  export PATH="$PATH:$FLUTTER_HOME/bin"
  if ! grep -qF "$FLUTTER_HOME/bin" "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$PATH:'"$FLUTTER_HOME"'/bin"' >> "$HOME/.bashrc"
    log "PATH persisted to ~/.bashrc (open a new UCRT64 shell, or: source ~/.bashrc)"
  fi

  log "Enabling Flutter Windows desktop + precaching the Windows engine"
  flutter config --enable-windows-desktop
  flutter precache --windows
  flutter --version

  cat <<EOF

==> Setup complete.

Next (from this UCRT64 shell):
  1. Build:   ./build.sh windows    # native layer + agora.exe
  2. Test:    ./test.sh
  3. Package: ./package-windows.sh  # a zip for other PCs

If 'flutter' is not found in a new shell, add: export PATH="\$PATH:$FLUTTER_HOME/bin"
EOF
}

if [ "$(uname -s)" = "Darwin" ]; then
  setup_macos
  exit 0
fi
case "$(uname -s)" in
  MINGW*|MSYS*)
    setup_windows
    exit 0
    ;;
esac

FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"

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
