#!/usr/bin/env bash
# Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors. Apache-2.0.
#
# Build Agora: the native layer (AT C core + libagora_shim + agorad) and the
# Flutter desktop app.
#
# TOOLCHAIN: the ENTIRE build uses the SYSTEM toolchain (system cmake, pkg-config,
# compilers, and the system-installed AT C deps + GTK). conda is NOT required and
# is actively neutralized below, because mixing a conda env with the system GTK
# stack breaks the Flutter build (conda pkg-config's prefix redirection mangles
# /usr/include -> /usr/lib/include, and conda- vs system-configured CMake caches
# poison each other on the shared filesystem). Install the deps with ./setup.sh.
#
# Usage:
#   ./build.sh [linux|macos|windows]  # default: linux
#
# Env:
#   AGORA_STRICT=1   keep AT's hardcoded -Werror (default: strip it via
#                    native/cc-no-werror.sh, so newer-than-AT-tested compilers
#                    like GCC 15 don't fail the build).
#   BUILD_TYPE=...   CMake build type for the native layer (default: Release).
#   FLUTTER_MODE=... --debug | --profile | --release for the app (default: --debug).
#   AGORA_KEEP_CONDA=1  do NOT strip conda from the build environment (escape
#                    hatch; the default is to remove it).
#   MACOSX_DEPLOYMENT_TARGET=...  oldest macOS the native layer targets (default
#                    12.0, the Runner's; Homebrew's own floor wins if newer).
#
# Windows: run from an MSYS2 UCRT64 shell. The native layer is built with its
# MinGW GCC, CMake and Ninja (./setup.sh installs them with pacman); the
# Flutter runner is built by Flutter with Visual Studio, and copies the native
# layer and its MinGW DLLs in beside agora.exe (windows/CMakeLists.txt).
#
# macOS: the AT C deps come from Homebrew (./setup.sh installs them), found via
# $(brew --prefix); the native layer is built for this Mac's architecture only,
# since Homebrew bottles are single-arch. `flutter build macos` then embeds it
# into agora.app (macos/embed_native.sh, a Runner build phase).
set -euo pipefail

PLATFORM="${1:-linux}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
FLUTTER_MODE="${FLUTTER_MODE:---debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

case "$PLATFORM" in
  linux|macos|windows) ;;
  *) echo "error: unsupported platform '$PLATFORM' (want: linux | macos | windows)" >&2; exit 2 ;;
esac

# --- neutralize conda: build entirely with the system toolchain --------------
# Whether or not the caller has a conda env active, remove conda's influence so
# `cmake`, `pkg-config`, and the compilers resolve to the system ones and find
# the system AT C deps + GTK. This is what makes the native and Flutter builds
# agree (they meet only at runtime via dlopen). Escape hatch: AGORA_KEEP_CONDA=1.
is_conda_path() { case "$1" in
  *conda*|*miniforge*|*miniconda*|*anaconda*|*/envs/*) return 0 ;; *) return 1 ;;
esac }
if [ "${AGORA_KEEP_CONDA:-0}" != "1" ]; then
  if [ -n "${CONDA_PREFIX:-}" ] || printf '%s' "$PATH" | grep -qiE 'conda|miniforge|miniconda|anaconda'; then
    echo "==> conda detected in the environment; stripping it for a clean system build (AGORA_KEEP_CONDA=1 to keep it)"
  fi
  # 1. Drop conda dirs from PATH so system cmake/pkg-config/compilers win.
  _newpath=""; _oldifs="$IFS"; IFS=':'
  for _d in $PATH; do
    [ -n "$_d" ] || continue
    if [ -n "${CONDA_PREFIX:-}" ] && { [ "$_d" = "$CONDA_PREFIX" ] || case "$_d" in "$CONDA_PREFIX"/*) true;; *) false;; esac; }; then continue; fi
    is_conda_path "$_d" && continue
    _newpath="${_newpath:+$_newpath:}$_d"
  done
  IFS="$_oldifs"; export PATH="$_newpath"
  # 2. Unset conda-injected build vars (compilers, prefixes, pkg-config libdir).
  for _v in CC CXX CPP CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CMAKE_C_COMPILER CMAKE_CXX_COMPILER; do
    _val="$(eval "printf '%s' \"\${$_v:-}\"")"
    [ -n "$_val" ] && is_conda_path "$_val" && unset "$_v"
  done
  unset CMAKE_PREFIX_PATH CMAKE_ARGS PKG_CONFIG_LIBDIR CONDA_PREFIX 2>/dev/null || true
  # 3. Force system pkg-config search path (drop any conda entries from an
  #    existing PKG_CONFIG_PATH, then prepend the system dirs).
  if [ "$PLATFORM" = "linux" ]; then
    SYS_PC="/usr/lib/$(uname -m)-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    _cleanpc=""; _oldifs="$IFS"; IFS=':'
    for _d in ${PKG_CONFIG_PATH:-}; do
      [ -n "$_d" ] || continue; is_conda_path "$_d" && continue
      _cleanpc="${_cleanpc:+$_cleanpc:}$_d"
    done
    IFS="$_oldifs"; export PKG_CONFIG_PATH="${SYS_PC}${_cleanpc:+:$_cleanpc}"
  fi
fi

# --- macOS / Windows: platform toolchain ------------------------------------
# Set after the conda strip above, which clears CMAKE_PREFIX_PATH.
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 4)"
PLATFORM_CMAKE_ARGS=()
if [ "$PLATFORM" = "macos" ]; then
  [ "$(uname -s)" = "Darwin" ] || { echo "error: a macOS build runs on macOS (Flutter cannot cross-compile desktop apps)" >&2; exit 2; }
  command -v brew >/dev/null 2>&1 || { echo "error: Homebrew not found; run ./setup.sh first" >&2; exit 1; }
  BREW_PREFIX="$(brew --prefix)"
  PLATFORM_CMAKE_ARGS=(
    "-DCMAKE_PREFIX_PATH=$BREW_PREFIX"
    "-DCMAKE_OSX_ARCHITECTURES=$(uname -m)"
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}"
  )
fi
if [ "$PLATFORM" = "windows" ]; then
  case "${MSYSTEM:-}" in
    UCRT64) ;;
    *) echo "error: a Windows build runs in an MSYS2 UCRT64 shell (MSYSTEM=UCRT64, not '${MSYSTEM:-unset}'); see ./setup.sh" >&2; exit 2 ;;
  esac
  # Where windows/CMakeLists.txt finds the MinGW DLLs to bundle (a Windows
  # path: the runner's CMake is a native Windows program).
  AGORA_MINGW_BIN="$(cygpath -m "$MSYSTEM_PREFIX/bin")"
  export AGORA_MINGW_BIN
  PLATFORM_CMAKE_ARGS=(-G Ninja)
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

# --- ensure the AT C core submodule is present -------------------------------
AT_C_DIR="$ROOT/../../lib/autonomous_trust/src/c"
if [ ! -f "$AT_C_DIR/CMakeLists.txt" ]; then
  echo "==> AT C core missing; initializing submodules"
  git -C "$ROOT/../.." submodule update --init --recursive
fi

# --- 1. native layer ---------------------------------------------------------
# native/build/ lives on the (shared) project filesystem and caches absolute
# find_library() paths + compiler-launcher paths. If it was configured in a
# different environment (another machine, a different conda env), those cached
# paths can be stale — CMake won't re-search, and the build dies with e.g.
# "No rule to make target '.../libprotobuf-c.so'". Wipe on AGORA_CLEAN=1, or
# automatically when the cache references a path that no longer exists.
if [ "${AGORA_CLEAN:-0}" = "1" ]; then
  echo "==> AGORA_CLEAN=1: removing native/build"
  rm -rf native/build
elif [ -f native/build/CMakeCache.txt ]; then
  stale=""
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    [ -e "$p" ] || { stale="missing $p"; break; }
  done < <(grep -oE '(_LIBRARY|_EXECUTABLE|COMPILER(_LAUNCHER)?):(FILE)?PATH=/[^ ]*' \
             native/build/CMakeCache.txt | sed 's/^[^=]*=//')
  # Also wipe a cache configured under conda (even if those paths still exist):
  # we now build with the system toolchain, and a conda-pinned compiler/prefix in
  # the cache would either fail or silently pull conda libs.
  if [ -z "$stale" ] && grep -qiE '^CMAKE_(C|CXX)_COMPILER(_LAUNCHER)?:[^=]*=[^ ]*(miniforge|miniconda|anaconda|/conda|/envs/)' native/build/CMakeCache.txt; then
    stale="conda-configured compiler"
  fi
  if [ -n "$stale" ]; then
    echo "==> Stale native/build cache ($stale); reconfiguring clean"
    rm -rf native/build
  fi
fi

echo "==> Building native layer ($BUILD_TYPE) for $PLATFORM"
NATIVE_CMAKE_ARGS=("-DCMAKE_BUILD_TYPE=$BUILD_TYPE")
if [ "${AGORA_STRICT:-0}" != "1" ]; then
  # Strip AT's hardcoded -Werror via a compiler launcher. AT force-installs its
  # own launcher on fuse/virtio filesystems, so also disable that guard, else it
  # would override ours.
  LAUNCH="$ROOT/native/cc-no-werror.sh"
  chmod +x "$LAUNCH"
  # Ninja on Windows cannot run a .sh itself: launch it through bash.
  if [ "$PLATFORM" = "windows" ]; then
    LAUNCH="$(cygpath -m "$(command -v bash)");$(cygpath -m "$LAUNCH")"
  fi
  NATIVE_CMAKE_ARGS+=(
    "-DAT_CC_VALIDATE_OUTPUT=OFF"
    "-DCMAKE_C_COMPILER_LAUNCHER=$LAUNCH"
    "-DCMAKE_CXX_COMPILER_LAUNCHER=$LAUNCH"
  )
fi

cmake -S native -B native/build "${NATIVE_CMAKE_ARGS[@]}" ${PLATFORM_CMAKE_ARGS[@]+"${PLATFORM_CMAKE_ARGS[@]}"}
# ethne_ffi (businesses = Ethne polities) is built too when cargo is available;
# its CMake target does not exist if Rust is not installed (a warning at
# configure). The core targets build either way; an ethne failure is reported,
# not fatal, since businesses are the only feature it carries.
cmake --build native/build --target agorad agora_shim -j"$JOBS"
if grep -q '^CARGO_EXECUTABLE:FILEPATH=/' native/build/CMakeCache.txt 2>/dev/null; then
  cmake --build native/build --target ethne_ffi -j"$JOBS" \
    || echo "==> WARNING: ethne_ffi (businesses) failed to build; the app runs without it" >&2
fi

# --- 2. Flutter app ----------------------------------------------------------
echo "==> Fetching Dart packages"
flutter pub get

# Ubuntu 25.10+/26.04: GTK's .pc chain references include dirs from static-only
# Requires.private deps (/usr/include/glycin-2, /usr/include/sysprof-6) that may
# not exist, making CMake fail the Flutter runner's generate: PkgConfig::GTK
# "includes non-existent path". Create any such missing dir (empty; the app
# includes nothing from them) right before the build, reading .pc files directly
# so an active conda env can't shadow them.
echo "==> Building Flutter app: flutter build $PLATFORM $FLUTTER_MODE"
if [ "$PLATFORM" = "linux" ]; then
  bash "$ROOT/native/stub-pkgconfig-includes.sh" || true

  # `flutter build` will NOT re-run CMake configure while build/<platform> already
  # holds a CMakeCache.txt — so the system-toolchain env we set below only bites on
  # a FRESH configure. A cache generated by a previous conda-env configure therefore
  # survives and poisons the build: it pins conda's cmake/clang and, worse, conda
  # pkg-config's MANGLED GTK include paths (e.g. -isystem /usr/lib/include/gtk-3.0,
  # the prefix-redirection bug), so gtk/gtk.h and glib-object.h vanish. Detect a
  # cross-toolchain Flutter cache and wipe build/<platform> so this step reconfigures
  # cleanly. (Mirrors the native/build stale-cache guard above; native artifacts live
  # in native/build and are untouched.)
  want_cc=""
  [ -x /usr/bin/clang ] && want_cc="/usr/bin/clang"
  # Flutter's Linux CMake tree is build/<platform>/<arch>/<mode>/ — search at any
  # depth rather than assuming a fixed level.
  fl_cache="$(find "build/$PLATFORM" -name CMakeCache.txt 2>/dev/null | head -1 || true)"
  if [ -n "$fl_cache" ]; then
    have_cc="$(sed -n 's/^CMAKE_C_COMPILER:[^=]*=//p' "$fl_cache" | head -1)"
    if { [ -n "$want_cc" ] && [ "$have_cc" != "$want_cc" ]; } \
       || printf '%s' "$have_cc" | grep -qiE 'miniforge|miniconda|anaconda|/conda|/envs/'; then
      echo "==> Flutter CMake cache compiler is '$have_cc' (not the system toolchain); cleaning build/$PLATFORM"
      rm -rf build/"$PLATFORM"
    fi
  fi

  # The environment is already system-only (conda was stripped at the top), so
  # CMake sees the system pkg-config + GTK. Pin the compiler to system clang for
  # this step (Flutter's Linux default), which the cache guard above also checks.
  flutter_env=()
  if [ -x /usr/bin/clang ] && [ -x /usr/bin/clang++ ]; then
    flutter_env=(env CC=/usr/bin/clang CXX=/usr/bin/clang++)
  fi
  "${flutter_env[@]}" flutter build "$PLATFORM" "$FLUTTER_MODE"
elif [ "$PLATFORM" = "windows" ]; then
  # The runner is Visual Studio's (MSVC); keep MSYS2's GCC out of its CMake.
  env -u CC -u CXX flutter build windows "$FLUTTER_MODE"
else
  flutter build "$PLATFORM" "$FLUTTER_MODE"
fi

echo
echo "==> Build complete."
if [ "$PLATFORM" = "windows" ]; then
  echo "    native : native/build/{agorad.exe,libagora_shim.dll,at_core/libautonomous_trust.dll}"
  echo "             + at_core/extensions/<layer>/libat_<layer>.dll"
  echo "    app    : build/windows/x64/runner/*/agora.exe (native layer and MinGW DLLs beside it)"
  echo
  echo "    To run from the source tree: ./run-dev.sh   (or start agora.exe above)."
  echo "    To package for other PCs:    ./package-windows.sh"
  echo "    agorad keeps its identity/config under %LOCALAPPDATA%\\Agora."
elif [ "$PLATFORM" = "macos" ]; then
  echo "    native : native/build/{agorad,libagora_shim.dylib,at_core/libautonomous_trust.dylib}"
  echo "             + at_core/extensions/<layer>/libat_<layer>.dylib"
  echo "    app    : build/macos/Build/Products/*/agora.app (native layer embedded)"
  echo
  echo "    To run from the source tree: ./run-dev.sh   (or open the .app above)."
  echo "    To package for other Macs:   ./package-dmg.sh"
  echo "    agorad self-bootstraps its identity/config under"
  echo "    ~/Library/Application Support/Agora on first run."
else
  echo "    native : native/build/{agorad,libagora_shim.so,at_core/libautonomous_trust.so}"
  echo "             + at_core/extensions/<layer>/libat_<layer>.so (the verification layers,"
  echo "               social, rendezvous and first contact)"
  echo "    app    : build/$PLATFORM/  (see 'flutter build $PLATFORM' output above)"
  echo
  echo "    To run (needs a display): ./run-dev.sh, or point the app at the native artifacts:"
  echo "      export AGORA_DAEMON_PATH=\"$ROOT/native/build/agorad\""
  echo "      export AGORA_SHIM_PATH=\"$ROOT/native/build/libagora_shim.so\""
  echo "      export LD_LIBRARY_PATH=\"$ROOT/native/build/at_core:\$LD_LIBRARY_PATH\""
  echo "      flutter run -d $PLATFORM"
  echo "    agorad self-bootstraps its identity/config under a short"
  echo "    \$AUTONOMOUS_TRUST_ROOT (default ~/.local/state/agora) on first run."
fi
