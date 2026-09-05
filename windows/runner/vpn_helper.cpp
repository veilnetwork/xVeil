#include "vpn_helper.h"

#include <windows.h>
#include <shellapi.h>

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

namespace {

using WindowsVpnHelperFn = int (*)(const wchar_t*, const wchar_t*);

constexpr wchar_t kHelperArgument[] = L"--xveil-vpn-helper";
constexpr wchar_t kHelperLibrary[] = L"veil_vpn_helper.dll";

std::filesystem::path ExecutableDirectory() {
  std::wstring path(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return {};
  }
  path.resize(length);
  return std::filesystem::path(path).parent_path();
}

}  // namespace

std::optional<int> RunWindowsVpnHelperIfRequested() {
  int argument_count = 0;
  wchar_t** arguments =
      ::CommandLineToArgvW(::GetCommandLineW(), &argument_count);
  if (arguments == nullptr) {
    return std::nullopt;
  }
  const bool requested =
      argument_count >= 2 && std::wstring(arguments[1]) == kHelperArgument;
  if (!requested) {
    ::LocalFree(arguments);
    return std::nullopt;
  }
  // THREE operands, not two. The third is the SHA-256 the host computed over
  // the request bytes it wrote. The request itself sits in the user's own
  // %TEMP%, writable by every process of that user for as long as the UAC
  // prompt is on screen; this command line was fixed when that prompt was
  // approved and cannot be changed after it. A missing operand is a refusal,
  // never a run without the check.
  if (argument_count != 4 || arguments[2][0] == L'\0' ||
      arguments[3][0] == L'\0') {
    ::LocalFree(arguments);
    return EXIT_FAILURE;
  }
  const std::wstring request_path(arguments[2]);
  const std::wstring request_digest(arguments[3]);
  ::LocalFree(arguments);

  const std::filesystem::path directory = ExecutableDirectory();
  if (directory.empty()) {
    return EXIT_FAILURE;
  }
  const std::filesystem::path library_path = directory / kHelperLibrary;
  HMODULE library = ::LoadLibraryExW(
      library_path.c_str(), nullptr,
      LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (library == nullptr) {
    return EXIT_FAILURE;
  }
  // _v2 takes the digest. The one-argument entry point it replaces read the
  // request on trust and is gone, so a DLL from another build resolves to
  // nullptr here and this returns failure — a mixed installation must not fall
  // back to the unchecked route.
  const FARPROC symbol =
      ::GetProcAddress(library, "veil_run_windows_vpn_helper_v2");
  if (symbol == nullptr) {
    ::FreeLibrary(library);
    return EXIT_FAILURE;
  }
  static_assert(sizeof(symbol) == sizeof(WindowsVpnHelperFn));
  WindowsVpnHelperFn helper = nullptr;
  std::memcpy(&helper, &symbol, sizeof(helper));
  const int result = helper(request_path.c_str(), request_digest.c_str());
  ::FreeLibrary(library);
  return result == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
