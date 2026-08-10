# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "xveil")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "network.veil.xveil")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
# Flutter's Linux build is a bundle assembly, never a system-wide install.
# Force the destination on every configure: after a failed first configure,
# CMake no longer reports the default prefix as freshly initialized and would
# otherwise install a later successful retry into /usr/local.
set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH
  "xVeil Linux bundle output" FORCE)

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# The call engine arrives here as a prebuilt the plugin hands over as-is:
# veil_media/linux/CMakeLists.txt checks only that the file EXISTS. So a stale
# copy bundles silently, and every symbol the Dart side has gained since that
# copy was built becomes a dlsym failure at the first call — which is exactly
# what was sitting in the tree until today: 78 exported against 87 looked up.
#
# release.yml already asks this question for the artifact it downloads. A local
# `flutter build linux` asked nobody, so it asks here.
#
# WARNING and not FATAL_ERROR on purpose. The check needs `nm` from binutils,
# and a host that can build Flutter for Linux without it should not lose the
# ability to build over a diagnostic. It reports; it does not gate. The gate
# that must hold lives in release.yml, where the toolchain is known.
set(VEIL_MEDIA_SYMBOL_CHECK "${CMAKE_CURRENT_SOURCE_DIR}/../scripts/check-media-symbols.sh")
foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  get_filename_component(_veil_bl_name "${bundled_library}" NAME)
  if(_veil_bl_name STREQUAL "libveil_media.so"
     AND EXISTS "${VEIL_MEDIA_SYMBOL_CHECK}"
     AND EXISTS "${bundled_library}")
    execute_process(
      COMMAND bash "${VEIL_MEDIA_SYMBOL_CHECK}" "${bundled_library}"
      RESULT_VARIABLE _veil_media_symbols_rc
      OUTPUT_VARIABLE _veil_media_symbols_out
      ERROR_VARIABLE _veil_media_symbols_out)
    if(NOT _veil_media_symbols_rc EQUAL 0)
      message(WARNING
        "veil_media: the engine about to be bundled does not export everything "
        "the Dart side looks up. Calls into the missing entry points will fail "
        "at dlsym, at runtime, in a released bundle. Rebuild it with "
        "veil_media/linux/build_veil_media_so_linux.sh or take a current "
        "artifact from the webrtc-linux workflow.\n"
        "  ${bundled_library}\n"
        "${_veil_media_symbols_out}")
    endif()
  endif()
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# On-device voice transcription (whisper.cpp) — mirrors the macOS bundle step
# (scripts/bundle-macos-dylibs.sh): stage the wrapper .so built by
# native/whisper/build_veil_whisper_linux.sh in native/whisper/linux/ and it
# lands in the bundle's lib/, where the Dart side (whisper_ffi.dart /
# native_libs.dart) resolves it. Absent, the Transcribe affordance stays
# hidden.
set(VEIL_WHISPER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native/whisper/linux")
if(EXISTS "${VEIL_WHISPER_DIR}/libveil_whisper.so")
  install(FILES "${VEIL_WHISPER_DIR}/libveil_whisper.so"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# On-device translation (CTranslate2 + SentencePiece) — same shape as whisper
# above: the wrapper built by native/translate/build_veil_translate_linux.sh
# lands in the bundle's lib/, where native_libs.dart resolves it. Absent, the
# translation affordance never appears.
#
# Written BEFORE that script exists, on purpose. Every other platform learned
# this the expensive way in the same week: the Android library was built into a
# directory the APK never reads, and macOS never copied the dylib at all — both
# produced a library that was verified, correct, and unreachable. The EXISTS
# guard makes this inert until there is something to install, and present the
# moment there is.
set(VEIL_TRANSLATE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native/translate/linux")
if(EXISTS "${VEIL_TRANSLATE_DIR}/libveil_translate.so")
  install(FILES "${VEIL_TRANSLATE_DIR}/libveil_translate.so"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# The 57 MiB ggml model is NOT bundled by default — the app fetches it on
# demand and keeps it once for the whole app. Bundling it stayed possible for
# a build that must install without a network, and needs the same opt-in as
# Android and macOS use, so a model merely left in the staging directory does
# not quietly add 57 MiB to a Linux bundle.
if(EXISTS "${VEIL_WHISPER_DIR}/ggml-base-q5_1.bin"
   AND "$ENV{XVEIL_BUNDLE_WHISPER_MODEL}" STREQUAL "1")
  install(FILES "${VEIL_WHISPER_DIR}/ggml-base-q5_1.bin"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
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

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
