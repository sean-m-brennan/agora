#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Install everything needed to build & test Agora on this OS: Linux, macOS, or
# Windows (from an MSYS2 UCRT64 shell) — detected the same way as ./run-dev.sh.
# What can be downloaded is installed; what cannot (Xcode, Visual Studio when
# winget is unavailable, an unknown Linux package manager, ...) is listed at the
# end as manual steps, and the script then exits 1. Re-run it after doing them;
# every step is idempotent.
#
# TOOLCHAIN: Agora builds entirely with the SYSTEM toolchain — conda is NOT used
# for the build (mixing conda with the system GTK stack breaks the Flutter build;
# see build.sh). Every OS gets:
#   - the C/C++ toolchain + CMake/Ninja/pkg-config,
#   - the AT C-core deps (libsodium, jansson, libuuid, protobuf, protobuf-c, ssl),
#   - Rust (builds ethne_ffi, businesses; the app runs without it),
#   - the Flutter SDK (+ Dart) and its desktop engine for this OS.
# (conda is still fine for the AutonomousTrust *Python* inspector/services — it
# is simply not on the Agora build path, and build.sh strips it if active.)
#
# Linux:   apt (Debian/Ubuntu), dnf (Fedora), or pacman (Arch) + GTK.
# macOS:   Homebrew (installed if missing) + Xcode, which `flutter build macos`
#          needs (the command line tools alone are not enough). See setup_macos.
# Windows: run from an MSYS2 UCRT64 shell (https://www.msys2.org; the
#          "MSYS2 UCRT64" start-menu entry). The native layer is built with
#          MSYS2's UCRT64 toolchain and packages (pacman), the Flutter runner
#          with Visual Studio 2022's C++ tools, which `flutter build windows`
#          requires (installed via winget when available). See setup_windows.
#
# Usage:   ./setup.sh
# Env:     FLUTTER_HOME    (default /opt/flutter on Linux; $HOME/flutter on
#                           macOS and Windows)
#          FLUTTER_CHANNEL (default stable)
#          AGORA_NO_RUST=1 (skip Rust; businesses are then not built)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUTTER_CHANNEL="${FLUTTER_CHANNEL:-stable}"

log() { printf '\n==> %s\n' "$*"; }

# Steps this script cannot do itself; printed by finish().
MANUAL=()
manual() { MANUAL+=("$*"); }

# Append a PATH entry to a shell startup file, once.
persist_path() {
  local f="$1" dir="$2" sudo="${3:-}"
  [ -n "$f" ] || return 1
  grep -qF "$dir" "$f" 2>/dev/null && return 0
  echo 'export PATH="$PATH:'"$dir"'"' | $sudo tee -a "$f" >/dev/null
}

# Flutter SDK: a git clone of the channel into $FLUTTER_HOME.
install_flutter() {
  if [ -x "$FLUTTER_HOME/bin/flutter" ]; then
    log "Flutter already present at $FLUTTER_HOME"
  else
    log "Installing Flutter ($FLUTTER_CHANNEL) to $FLUTTER_HOME"
    git clone --branch "$FLUTTER_CHANNEL" --depth 1 \
      https://github.com/flutter/flutter.git "$FLUTTER_HOME"
  fi
  export PATH="$PATH:$FLUTTER_HOME/bin"
}

# Rust via rustup (Linux, macOS); MSYS2 packages its own (setup_windows).
install_rust() {
  if [ "${AGORA_NO_RUST:-0}" = "1" ]; then
    echo "note: AGORA_NO_RUST=1; businesses (ethne_ffi) will not be built."
    return 0
  fi
  if command -v cargo >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/cargo" ]; then
    log "Rust already present ($(PATH="$PATH:$HOME/.cargo/bin" cargo --version))"
  else
    log "Installing Rust (rustup, stable) to ~/.cargo"
    if ! curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
         | sh -s -- -y --profile minimal --no-modify-path; then
      manual "Install Rust (optional; for businesses): https://rustup.rs"
      return 0
    fi
  fi
  export PATH="$PATH:$HOME/.cargo/bin"
}

# Print the result; exit 1 if anything is left to do by hand.
finish() {
  local next="$1"
  command -v flutter >/dev/null 2>&1 && flutter --version
  if [ "${#MANUAL[@]}" -gt 0 ]; then
    printf '\n==> Setup incomplete. Do these by hand, then re-run ./setup.sh:\n\n'
    local i=1 step
    for step in "${MANUAL[@]}"; do
      printf '  %d. %s\n' "$i" "$step"
      i=$((i + 1))
    done
    exit 1
  fi
  printf '\n==> Setup complete.\n\n%s\n' "$next"
  exit 0
}

# --- macOS -----------------------------------------------------------------
setup_macos() {
  FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"

  # Xcode cannot be downloaded from a script (App Store / Apple ID). If it is
  # installed but the command line tools are selected, select it.
  if xcodebuild -version >/dev/null 2>&1; then
    log "Xcode present ($(xcodebuild -version | head -1))"
  elif [ -d /Applications/Xcode.app ]; then
    log "Selecting /Applications/Xcode.app (sudo)"
    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
  else
    manual "Install Xcode from the App Store (flutter build macos needs it), then:
       sudo xcode-select -s /Applications/Xcode.app && sudo xcodebuild -runFirstLaunch"
  fi

  # Some Flutter tooling is still x86_64 on Apple silicon.
  if [ "$(uname -m)" = "arm64" ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
    log "Installing Rosetta 2 (sudo)"
    sudo softwareupdate --install-rosetta --agree-to-license \
      || manual "Install Rosetta 2: sudo softwareupdate --install-rosetta --agree-to-license"
  fi

  # Homebrew (its installer also fetches the command line tools, for git).
  if ! command -v brew >/dev/null 2>&1; then
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
  fi
  if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew (asks for your password)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$b" ] && eval "$("$b" shellenv)" && break
    done
  fi
  if ! command -v brew >/dev/null 2>&1; then
    manual "Install Homebrew from https://brew.sh"
    finish ""
  fi
  if ! grep -qF 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
    echo 'eval "$('"$(command -v brew)"' shellenv)"' >> "$HOME/.zprofile"
  fi

  log "Installing build tools and AT C-core deps (Homebrew)"
  # libuuid is part of macOS itself. Do NOT install ossp-uuid: its uuid.h is a
  # different API and would shadow the system one.
  brew install cmake ninja pkg-config libsodium jansson protobuf protobuf-c

  install_rust
  install_flutter
  # zsh is the macOS login shell.
  persist_path "$HOME/.zprofile" "$FLUTTER_HOME/bin"
  [ -x "$HOME/.cargo/bin/cargo" ] && persist_path "$HOME/.zprofile" "$HOME/.cargo/bin"
  log "PATH persisted to ~/.zprofile (open a new terminal, or: source ~/.zprofile)"

  log "Enabling Flutter macOS desktop + precaching the macOS engine"
  flutter config --enable-macos-desktop
  flutter precache --macos

  finish "Next:
  1. Build:   ./build.sh macos      # native layer + agora.app ($(uname -m) only)
  2. Test:    ./test.sh
  3. Run:     ./run-dev.sh          # build, then flutter run
  4. Package: ./package-dmg.sh      # a .dmg for other Macs"
}

# --- Windows (MSYS2 UCRT64) ------------------------------------------------
setup_windows() {
  if [ "${MSYSTEM:-}" != "UCRT64" ]; then
    echo "error: run this from an MSYS2 UCRT64 shell (MSYSTEM=UCRT64, not '${MSYSTEM:-unset}'):" >&2
    echo "       Start menu -> 'MSYS2 UCRT64', then cd here and ./setup.sh" >&2
    exit 1
  fi
  FLUTTER_HOME="${FLUTTER_HOME:-$HOME/flutter}"

  log "Installing the UCRT64 toolchain, AT C-core deps and Rust (pacman)"
  local rust=mingw-w64-ucrt-x86_64-rust
  [ "${AGORA_NO_RUST:-0}" = "1" ] && rust=""
  pacman -S --needed --noconfirm git unzip zip \
    mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-cmake \
    mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-pkgconf \
    mingw-w64-ucrt-x86_64-python \
    mingw-w64-ucrt-x86_64-libsodium mingw-w64-ucrt-x86_64-jansson \
    mingw-w64-ucrt-x86_64-protobuf mingw-w64-ucrt-x86_64-protobuf-c \
    mingw-w64-ucrt-x86_64-check $rust

  # flutter build windows needs Visual Studio's C++ tools (any edition, Build
  # Tools included — which vswhere lists only with -products *).
  local vswhere="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
  have_vs() {
    [ -x "$vswhere" ] && [ -n "$("$vswhere" -latest -products '*' \
      -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
      -property installationPath 2>/dev/null | tr -d '\r')" ]
  }
  if have_vs; then
    log "Visual Studio C++ tools present"
  else
    local winget=""
    if command -v winget.exe >/dev/null 2>&1; then
      winget="winget.exe"
    elif [ -n "${LOCALAPPDATA:-}" ] \
         && [ -x "$(cygpath -u "$LOCALAPPDATA")/Microsoft/WindowsApps/winget.exe" ]; then
      winget="$(cygpath -u "$LOCALAPPDATA")/Microsoft/WindowsApps/winget.exe"
    fi
    if [ -n "$winget" ]; then
      log "Installing Visual Studio 2022 Build Tools + C++ workload (winget; approve the UAC prompt)"
      "$winget" install -e --id Microsoft.VisualStudio.2022.BuildTools \
        --accept-package-agreements --accept-source-agreements \
        --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" \
        || true
    fi
    have_vs || manual "Install Visual Studio 2022 (Build Tools is enough) with the
       'Desktop development with C++' workload: https://visualstudio.microsoft.com/downloads/"
  fi

  install_flutter
  persist_path "$HOME/.bashrc" "$FLUTTER_HOME/bin"
  log "PATH persisted to ~/.bashrc (open a new UCRT64 shell, or: source ~/.bashrc)"

  log "Enabling Flutter Windows desktop + precaching the Windows engine"
  flutter config --enable-windows-desktop
  flutter precache --windows

  finish "Next (from this UCRT64 shell):
  1. Build:   ./build.sh windows    # native layer + agora.exe
  2. Test:    ./test.sh
  3. Run:     ./run-dev.sh          # build, then flutter run
  4. Package: ./package-windows.sh  # a zip for other PCs"
}

# --- Linux -----------------------------------------------------------------
setup_linux() {
  FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"

  local SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"

  # 1. System packages: full build toolchain + AT C deps + GTK. Everything the
  # build needs, from the distro — no conda on the build path.
  if command -v apt-get >/dev/null 2>&1; then
    # Tolerate sandbox clock skew (apt "Release file is not valid yet").
    local APT_OPTS=(-o Acquire::Check-Date=false)
    log "Installing build toolchain, AT C-core deps, and GTK (apt)"
    $SUDO apt-get "${APT_OPTS[@]}" update || true
    $SUDO apt-get "${APT_OPTS[@]}" -y install \
      git curl unzip xz-utils zip \
      build-essential clang cmake ninja-build pkg-config \
      libgtk-3-dev \
      libsodium-dev libjansson-dev uuid-dev \
      libprotobuf-c-dev protobuf-c-compiler libprotobuf-dev protobuf-compiler \
      libssl-dev check

    # On Ubuntu 25.10+/26.04, gdk-pixbuf's pkg-config Requires.private pulls in
    # glycin-2, and GTK's pkg-config chain adds -I/usr/include/glycin-2. If that
    # headers dir is missing, the Flutter runner's CMake dies: PkgConfig::GTK
    # "includes non-existent path /usr/include/glycin-2".
    # Prefer installing the real headers (best-effort — the -dev package may be
    # absent from a given distro's sources); --reinstall also heals a partial install.
    $SUDO apt-get "${APT_OPTS[@]}" -y install --reinstall libglycin-2-dev 2>/dev/null \
      || $SUDO apt-get "${APT_OPTS[@]}" -y install libglycin-2-dev 2>/dev/null \
      || echo "note: libglycin-2-dev not installable here; using the dir-stub fallback below"

    # AT's C codegen (preprocess.py) calls `python`. Provide a system shim if
    # there is no `python` on PATH (the build does not rely on conda's).
    if ! command -v python >/dev/null 2>&1; then
      log "No 'python' on PATH; installing python-is-python3 shim"
      $SUDO apt-get "${APT_OPTS[@]}" -y install python-is-python3 || true
    fi
  elif command -v dnf >/dev/null 2>&1; then
    log "Installing build toolchain, AT C-core deps, and GTK (dnf)"
    $SUDO dnf -y install \
      git curl unzip xz zip which \
      gcc gcc-c++ make clang cmake ninja-build pkgconf-pkg-config \
      gtk3-devel \
      libsodium-devel jansson-devel libuuid-devel \
      protobuf-c-devel protobuf-c-compiler protobuf-devel protobuf-compiler \
      openssl-devel check-devel python-unversioned-command
  elif command -v pacman >/dev/null 2>&1; then
    log "Installing build toolchain, AT C-core deps, and GTK (pacman)"
    $SUDO pacman -S --needed --noconfirm \
      git curl unzip xz zip \
      base-devel clang cmake ninja pkgconf \
      gtk3 \
      libsodium jansson util-linux-libs \
      protobuf protobuf-c openssl check python
  else
    manual "Install with your package manager: git curl unzip xz zip, a C/C++
       compiler + clang, cmake, ninja, pkg-config, GTK 3 (dev), libsodium,
       jansson, libuuid, protobuf + protoc, protobuf-c + protoc-c, OpenSSL, check
       (all with headers), and python 3 as \`python\`"
  fi

  # Safety net (package-independent): create any include dir that an installed
  # .pc file references but that does not exist (e.g. /usr/include/glycin-2,
  # /usr/include/sysprof-6 on Ubuntu 26.04) — otherwise CMake fails the Flutter
  # runner's generate. Reads .pc files directly (no pkg-config), so an active
  # conda env can't shadow them. build.sh runs the same helper before each build.
  bash "$ROOT/native/stub-pkgconfig-includes.sh" || true

  if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    manual "Install git and curl, then re-run ./setup.sh (needed for Rust and Flutter)"
    finish ""
  fi

  # 2. Rust + Flutter SDK
  install_rust
  if [ ! -x "$FLUTTER_HOME/bin/flutter" ]; then
    $SUDO mkdir -p "$FLUTTER_HOME"
    $SUDO chown "$(id -u):$(id -g)" "$FLUTTER_HOME"
  fi
  install_flutter
  git config --global --add safe.directory "$FLUTTER_HOME" 2>/dev/null || true

  # 3. Persist PATH
  local rc
  if [ -n "${CLAUDE_ENV_FILE:-}" ] && persist_path "$CLAUDE_ENV_FILE" "$FLUTTER_HOME/bin" "$SUDO"; then
    rc="$CLAUDE_ENV_FILE"
  elif persist_path "$HOME/.bashrc" "$FLUTTER_HOME/bin"; then
    rc="$HOME/.bashrc"
  fi
  if [ -n "${rc:-}" ]; then
    [ -x "$HOME/.cargo/bin/cargo" ] && persist_path "$rc" "$HOME/.cargo/bin" "$SUDO"
    log "PATH persisted to $rc (source it, or open a new shell)"
  fi

  # 4. Flutter desktop config + engine precache
  log "Enabling Flutter desktop + precaching the Linux engine (downloads Dart SDK)"
  flutter config --enable-linux-desktop --enable-macos-desktop
  flutter precache --linux

  finish "Next (no conda needed — the build uses the system toolchain):
  1. Build:   ./build.sh          # native layer + Flutter app (linux/$(uname -m))
  2. Test:    ./test.sh           # flutter analyze + unit tests
  3. Run:     ./run-dev.sh        # build, then flutter run"
}

case "$(uname -s)" in
  Linux)        setup_linux ;;
  Darwin)       setup_macos ;;
  MINGW*|MSYS*) setup_windows ;;
  *)
    echo "setup.sh: unsupported OS '$(uname -s)' (Linux, macOS, or Windows via MSYS2)" >&2
    exit 2
    ;;
esac
