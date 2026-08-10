# SentencePiece calls set_xcode_property() when it is building for Apple. That
# function is not CMake's — it comes from the community ios-cmake toolchain
# (leetal/ios-cmake), which SentencePiece assumes anybody targeting iOS is
# using. With CMake's own CMAKE_SYSTEM_NAME=iOS the call is simply undefined
# and configuration stops at src/CMakeLists.txt:365.
#
# The properties it sets are Xcode target attributes — bitcode, deployment
# settings for a generated .xcodeproj. We generate Makefiles and link the
# archive ourselves, so there is nothing for them to apply to. A no-op is the
# whole fix, and it is smaller and more honest than pulling a third-party
# toolchain into the build for one missing macro.
#
# Injected with -DCMAKE_PROJECT_INCLUDE_BEFORE so upstream stays unpatched.
function(set_xcode_property)
endfunction()
