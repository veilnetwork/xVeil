cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Read-only, bounded helper; called only by opt-in Dart diagnostics. Keeping
# device COM queries out of the Flutter process prevents a bad driver from
# blocking the call/UI thread. No elevation, files or network access.
add_executable(xveil_audio_probe WIN32
  "audio_output_probe.cpp"
  "audio_output_probe_main.cpp"
)
apply_standard_settings(xveil_audio_probe)
target_compile_definitions(xveil_audio_probe PRIVATE "NOMINMAX")
target_link_libraries(xveil_audio_probe PRIVATE "ole32.lib")

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "vpn_helper.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)
add_dependencies(${BINARY_NAME} xveil_audio_probe)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Build and stage the same-process Windows VPN engine plus the official signed
# Wintun DLL. The PowerShell script resolves Wintun from Cargo metadata, so the
# packaged driver always matches the audited Rust dependency lockfile.
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND powershell.exe -NoLogo -NoProfile -NonInteractive
    -ExecutionPolicy Bypass
    -File "${CMAKE_SOURCE_DIR}/../scripts/stage-windows-vpn.ps1"
    -Configuration "$<CONFIG>"
    -OutputDirectory "$<TARGET_FILE_DIR:${BINARY_NAME}>"
  VERBATIM
)
