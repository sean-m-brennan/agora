# ******************
#  Copyright 2026 TekFive, Inc., Sean M. Brennan, and contributors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
# ******************
#
# Native layer for Agora (Linux + macOS):
#   - builds the AutonomousTrust C core (libautonomous_trust, SHARED)
#   - libagora_shim : the flat FFI surface Dart binds
#   - agorad        : the standalone AT daemon the GUI spawns
#
# DTN (AT_NET_DTN) and ZTA (AT_ZTA) are left OFF (their defaults) — do not
# enable them here; the heavy third_party DTN stack is not needed for Agora.
# The five verification layers (AT_ORACLE_*) stay ON, their default, and are
# linked below as libat_<layer>.
# Social (libat_social) is Agora's own extension, ../at-social/c/social, built
# inside AT's project through AT_EXTERNAL_EXTENSIONS below.

# The AT C core is project(... C CXX); enable both here so the CXX toolchain is
# configured before the AT subdirectory is added.
cmake_minimum_required(VERSION 3.23)
project(agora_native C CXX)

# Location of the AutonomousTrust C core, inside the autonomous_trust submodule.
# apps/agora/native -> ../../../lib/autonomous_trust/src/c
set(AT_C_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../lib/autonomous_trust/src/c"
    CACHE PATH "AutonomousTrust C core source directory")

if(NOT EXISTS "${AT_C_DIR}/CMakeLists.txt")
    message(FATAL_ERROR
        "AutonomousTrust C core not found at ${AT_C_DIR}. "
        "Run: git submodule update --init --recursive")
endif()

# Don't build AT's own test suite (it needs libcheck/subunit). If the AT core
# does not honor BUILD_TESTING, build it standalone and link it as an IMPORTED
# target instead of add_subdirectory (see .claude/TODO.md).
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)

# Agora IS the social-app consumer of the AT core: the shim (at_agora_shim.c) and
# agorad call the social at_app_events_* API (social/at_agora.h) and reference
# event kinds 4-15. Those live in the extension library libat_social, whose
# source is Agora's (../at-social/c/social; it left the AT repo in
# FEATURE_SPLIT_PLAN Phase 5b). AT builds each directory named in
# AT_EXTERNAL_EXTENSIONS inside its own scope, as it would an in-tree extension,
# with its output at at_core/extensions/social/. Name it before AT is added. No
# compile definition is needed: the core's structs are the same in every build.
set(AGORA_SOCIAL_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../at-social/c/social")
set(AT_EXTERNAL_EXTENSIONS "${AGORA_SOCIAL_DIR}" CACHE STRING
    "Agora's AT extensions (libat_social)" FORCE)

add_subdirectory("${AT_C_DIR}" at_core)

# AT marks its library sources PUBLIC (`target_sources(autonomous_trust PUBLIC
# ${libsrc})`), which propagates EVERY AT .c file as an interface source into
# anything that links the target — recompiling the whole core in the consumer's
# object dir, and without AT's directory-scoped include paths. Strip the
# interface sources: we link the built library, not its sources.
set_property(TARGET autonomous_trust PROPERTY INTERFACE_SOURCES "")

# AT exposes its headers via directory-scoped include_directories() (its
# CMakeLists line ~747: src/c and src/c/autonomous_trust), which do NOT
# propagate to this subdirectory. Replicate them, plus AT's generated-header
# binary dir, for our consumers.
set(AT_INCLUDE_DIRS
    "${AT_C_DIR}"
    "${AT_C_DIR}/autonomous_trust"
    # AT's in-tree extension headers, and social's (social/at_agora.h,
    # social/at_social.h)
    "${AT_C_DIR}/extensions"
    "${AGORA_SOCIAL_DIR}/.."
    "${CMAKE_CURRENT_BINARY_DIR}/at_core"
    "${CMAKE_CURRENT_BINARY_DIR}/at_core/autonomous_trust"
    # generated protobuf-c headers (AT's PROTO_BINARY_DIR, its CMake line ~879)
    "${CMAKE_CURRENT_BINARY_DIR}/at_core/protobuf"
    "${CMAKE_CURRENT_BINARY_DIR}/at_core/protobuf/autonomous_trust/core/protobuf")

# libautonomous_trust.so is deliberately underlinked (AT links its deps only
# into final executables, not the shared lib — a .so may carry unresolved
# symbols). So each consumer must resolve AT's own dependencies. It is CXX-
# linked, hence stdc++.
find_library(AT_SODIUM_LIB    sodium     REQUIRED)
find_library(AT_JANSSON_LIB   jansson    REQUIRED)
find_library(AT_UUID_LIB      uuid       REQUIRED)
find_library(AT_PROTOBUFC_LIB protobuf-c REQUIRED)
find_library(AT_PROTOBUF_LIB  protobuf   REQUIRED)  # C++ runtime (ShutdownProtobufLibrary)
# AT's extension libraries this build links: the five verification layers
# (AT_ORACLE_*, ON by default, libat_<layer>, FEATURE_SPLIT_PLAN Phase 3) and
# social (libat_social, Phase 5). They were part of the core before the split,
# so linking them keeps agorad's behaviour unchanged; a node that declares a
# layer ($AT_PHYSICS, ...) or a social default ($AT_OWN_PROFILE, ...) without
# its library refuses to start. Each library registers from a constructor.
# The shim and agorad call at_social_link(), so social is referenced; the
# layers are not, so --as-needed (the Ubuntu/Debian default) would drop their
# DT_NEEDED and the layer with it. --no-as-needed keeps them, and stays on for
# the rest of the line: CMake moves a layer that another layer links
# (certificates, under replication) after its dependent, so switching
# --as-needed back on here would leave that one to chance. macOS ld64 keeps
# every named dylib by default.
set(AT_EXT_LIBS)
set(AT_EXT_RPATH)   # their build-tree dirs, for the dev flow (rpath below)
if(NOT TARGET at_social)
    message(FATAL_ERROR "Agora needs AT's social library (libat_social); "
                        "AT_EXTERNAL_EXTENSIONS names ${AGORA_SOCIAL_DIR} above, "
                        "so this AT tree does not support external extensions")
endif()
# First contact (area hubs, contacts, devices) and the rendezvous relays it
# rides are AT extension libraries since AT's FEATURE_SPLIT_PLAN Phase 7, no
# longer part of the core; Agora cannot run without them.
foreach(_layer rendezvous first_contact)
    if(NOT TARGET at_${_layer})
        message(FATAL_ERROR "Agora needs AT's ${_layer} library (libat_${_layer}); "
                            "configure AT with AT_FIRST_CONTACT_LIB and AT_RENDEZVOUS_LIB ON")
    endif()
endforeach()
foreach(_layer physics calibration certificates prequential replication social
               rendezvous first_contact)
    if(TARGET at_${_layer})
        list(APPEND AT_EXT_LIBS at_${_layer})
        list(APPEND AT_EXT_RPATH "${CMAKE_CURRENT_BINARY_DIR}/at_core/extensions/${_layer}")
    endif()
endforeach()
if(AT_EXT_LIBS AND NOT APPLE)
    set(AT_EXT_LIBS -Wl,--no-as-needed ${AT_EXT_LIBS})
endif()
set(AT_LINK_LIBS
    ${AT_EXT_LIBS}
    autonomous_trust
    ${AT_SODIUM_LIB} ${AT_JANSSON_LIB} ${AT_UUID_LIB}
    ${AT_PROTOBUFC_LIB} ${AT_PROTOBUF_LIB}
    pthread m stdc++)

# AT's public headers embed a typedef'd struct as an UNNAMED member (e.g.
# structures/array.h: `smrt_ptr_t;`), a Microsoft/plan9 anonymous-member
# extension. AT's own build enables -fms-extensions (src/c/CMakeLists.txt), and
# any consumer that includes these headers must do the same or GCC/Clang warns
# "declaration does not declare anything". Applied here, after add_subdirectory
# above, so it covers our own targets (agora_shim, agorad) without touching the
# already-configured AT core, which sets the flag itself.
add_compile_options(-fms-extensions)

# --- Flat FFI shim -----------------------------------------------------------
add_library(agora_shim SHARED at_agora_shim.c)
target_include_directories(agora_shim PRIVATE ${AT_INCLUDE_DIRS})
target_link_libraries(agora_shim PRIVATE ${AT_LINK_LIBS})
set_target_properties(agora_shim PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON)

# --- Standalone daemon -------------------------------------------------------
add_executable(agorad agorad.c)
target_include_directories(agorad PRIVATE ${AT_INCLUDE_DIRS})
target_link_libraries(agorad PRIVATE ${AT_LINK_LIBS})
set_target_properties(agorad PROPERTIES
    C_STANDARD 11
    C_STANDARD_REQUIRED ON)

# --- Relocatable rpath -------------------------------------------------------
# When these artifacts are copied into the Flutter app bundle they sit in the
# bundle's lib/ dir alongside libautonomous_trust.so and the libat_<name>
# extension libraries, so `$ORIGIN` resolves them with no LD_LIBRARY_PATH. The
# build-tree at_core dir and the libraries' at_core/extensions/<name>/ dirs are
# also kept on the rpath so the dev flow (running straight out of native/build/)
# finds them without env setup; those absolute entries are inert in the bundle.
# BUILD_WITH_INSTALL_RPATH bakes this into the build-tree binaries themselves,
# which is required because the Flutter bundle install copies the files verbatim
# (install(FILES ...) does no rpath rewriting).
set_target_properties(agora_shim agorad PROPERTIES
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN;${CMAKE_CURRENT_BINARY_DIR}/at_core;${AT_EXT_RPATH}")

# --- Ethne C-FFI cdylib (Phase 3: businesses = Ethne polities) ---------------
# ethne_ffi/ is a Rust cdylib exposing a C ABI over Ethne's Rust charter engine
# (SOCIAL_APP_PLAN.md §2.2). Built by cargo, not the C toolchain, and dropped
# next to agora_shim so the Flutter app dlopen's it the same way (it is
# self-contained — Rust std is linked in, so no rpath is needed).
#
# The cargo TARGET dir is forced onto a non-virtiofs path: rustc/LLVM's archive
# writes SIGBUS ("Bad address") on the shared fuse filesystem this tree lives on
# (the same corruption AT's C build sidesteps). Override with -DETHNE_FFI_TARGET_DIR.
find_program(CARGO_EXECUTABLE cargo
    HINTS "$ENV{HOME}/.cargo/bin" "$ENV{CARGO_HOME}/bin")
if(NOT CARGO_EXECUTABLE)
    message(WARNING "cargo not found; the ethne_ffi (business/polity) library "
                    "will NOT be built. Install Rust (rustup) and reconfigure.")
else()
    set(ETHNE_FFI_TARGET_DIR "/tmp/agora-ethne-ffi-target"
        CACHE PATH "cargo target dir for ethne_ffi (keep off virtiofs)")
    set(ETHNE_FFI_SO "${CMAKE_CURRENT_BINARY_DIR}/libethne_agora.so")
    add_custom_command(
        OUTPUT "${ETHNE_FFI_SO}"
        COMMAND ${CMAKE_COMMAND} -E env
                "CARGO_TARGET_DIR=${ETHNE_FFI_TARGET_DIR}"
                ${CARGO_EXECUTABLE} build --release
                --manifest-path "${CMAKE_CURRENT_SOURCE_DIR}/ethne_ffi/Cargo.toml"
        COMMAND ${CMAKE_COMMAND} -E copy
                "${ETHNE_FFI_TARGET_DIR}/release/libethne_agora.so" "${ETHNE_FFI_SO}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/ethne_ffi/src/lib.rs"
                "${CMAKE_CURRENT_SOURCE_DIR}/ethne_ffi/Cargo.toml"
        COMMENT "Building ethne_ffi cdylib (cargo, target on ${ETHNE_FFI_TARGET_DIR})"
        VERBATIM)
    add_custom_target(ethne_ffi ALL DEPENDS "${ETHNE_FFI_SO}")
endif()
