# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(agora LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "agora")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# === Agora native layer ===
# agorad.exe, the shim and the AT DLLs come from the native build (build.sh
# runs it, with MSYS2's UCRT64 toolchain, before `flutter build windows`) and
# go beside agorad.exe and the runner, where Windows looks for a DLL's DLLs; so
# do the MinGW runtime and dependency DLLs they load (libsodium, jansson,
# protobuf, libstdc++, ...), found by walking their imports. The Dart layer
# (native_paths.dart) looks for all of them in the exe's directory.
set(AGORA_NATIVE_BUILD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native/build"
  CACHE PATH "Agora native build output directory")
# Where the UCRT64 DLLs live: build.sh exports AGORA_MINGW_BIN (cygpath -m of
# $MSYSTEM_PREFIX/bin); MSYS2's default install otherwise.
if(DEFINED ENV{AGORA_MINGW_BIN})
  set(_agora_mingw_bin "$ENV{AGORA_MINGW_BIN}")
else()
  set(_agora_mingw_bin "C:/msys64/ucrt64/bin")
endif()
set(_agora_native_exes "${AGORA_NATIVE_BUILD_DIR}/agorad.exe")
set(_agora_native_dlls
  "${AGORA_NATIVE_BUILD_DIR}/libagora_shim.dll"
  "${AGORA_NATIVE_BUILD_DIR}/at_core/libautonomous_trust.dll")
foreach(_layer physics calibration certificates prequential replication social
               rendezvous first_contact)
  list(APPEND _agora_native_dlls
    "${AGORA_NATIVE_BUILD_DIR}/at_core/extensions/${_layer}/libat_${_layer}.dll")
endforeach()
# Ethne's cdylib (businesses) is optional: built only when cargo is present.
if(EXISTS "${AGORA_NATIVE_BUILD_DIR}/ethne_agora.dll")
  list(APPEND _agora_native_dlls "${AGORA_NATIVE_BUILD_DIR}/ethne_agora.dll")
endif()
# Where the DLLs above import each other from.
set(_agora_native_dirs "${AGORA_NATIVE_BUILD_DIR}" "${AGORA_NATIVE_BUILD_DIR}/at_core")
foreach(_layer physics calibration certificates prequential replication social
               rendezvous first_contact)
  list(APPEND _agora_native_dirs "${AGORA_NATIVE_BUILD_DIR}/at_core/extensions/${_layer}")
endforeach()
set(_agora_missing FALSE)
foreach(_agora_art ${_agora_native_exes} ${_agora_native_dlls})
  if(NOT EXISTS "${_agora_art}")
    message(WARNING
      "Agora: native artifact not found, the app will NOT be self-contained:\n"
      "  ${_agora_art}\n"
      "  Build the native layer first (./build.sh windows, from an MSYS2 UCRT64 shell).")
    set(_agora_missing TRUE)
  endif()
endforeach()
if(NOT _agora_missing)
  install(FILES ${_agora_native_exes} ${_agora_native_dlls}
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
  # Their non-system DLLs, resolved at install time.
  install(CODE "
    file(GET_RUNTIME_DEPENDENCIES
      EXECUTABLES ${_agora_native_exes}
      LIBRARIES ${_agora_native_dlls}
      DIRECTORIES \"${_agora_mingw_bin}\" ${_agora_native_dirs}
      PRE_EXCLUDE_REGEXES \"^api-ms-\" \"^ext-ms-\"
      POST_EXCLUDE_REGEXES \".*[Ss]ystem32/.*\" \".*[Ww][Ii][Nn][Dd][Oo][Ww][Ss]/.*\"
      RESOLVED_DEPENDENCIES_VAR _agora_deps
      UNRESOLVED_DEPENDENCIES_VAR _agora_unresolved)
    foreach(_d \${_agora_deps})
      file(INSTALL \"\${_d}\" DESTINATION \"${INSTALL_BUNDLE_LIB_DIR}\")
    endforeach()
    if(_agora_unresolved)
      message(WARNING \"Agora: DLLs not found (is AGORA_MINGW_BIN right?): \${_agora_unresolved}\")
    endif()
    " COMPONENT Runtime)
endif()

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
