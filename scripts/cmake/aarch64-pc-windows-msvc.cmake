# BoringSSL has no assembly route on Windows for ARM64. Say so, once, here.
#
# BoringSSL's CMakeLists picks its assembly sources in two branches:
#
#   if(WIN32 AND CMAKE_SYSTEM_PROCESSOR MATCHES "AMD64|x86_64|amd64|x86|i[3-6]86")
#     enable_language(ASM_NASM)          # Windows x64 lands here and is fine
#   else()
#     enable_language(ASM)               # Windows ARM64 lands HERE
#
# On the second branch CMake picks up cl.exe as the assembler and hands it
# BoringSSL's GNU-syntax .S files. cl.exe cannot assemble those, produces no
# objects, and the link fails naming a file it never compiled:
#
#   LNK1181: cannot open input file '...\fipsmodule.dir\Release\
#            aes-gcm-avx2-x86_64-apple.obj'
#
# — an APPLE x86_64 source, demanded by an ARM64 Windows build, which is the
# giveaway that the source list was never filtered for this platform at all.
#
# btls-sys knows the answer and cannot reach it. Its build script sets
# OPENSSL_NO_ASM for windows targets, but only inside a match it returns before
# whenever `config.host == config.target` — that is, on every NATIVE build. On
# x64 that early return is harmless because the NASM branch works. On arm64 it
# is the whole problem, and building arm64 Windows natively is the only way
# Flutter offers.
#
# So the same answer, from the outside, via CMAKE_TOOLCHAIN_FILE.
set(OPENSSL_NO_ASM 1 CACHE BOOL "BoringSSL has no MSVC assembly for ARM64" FORCE)

# btls-sys returns EARLIER still when a toolchain file is set — before it can
# choose the CRT — so this has to be stated here too. Dynamic, matching what
# rustc links against on *-pc-windows-msvc without crt-static; a mismatch here
# is a link error at the far end of a twenty-minute build.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL"
    CACHE STRING "match rustc's dynamic CRT" FORCE)
