#include "vpn_helper.h"

#include <windows.h>
#include <shellapi.h>

#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>

namespace {

using WindowsVpnHelperFn = int (*)(const wchar_t*);

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
  if (argument_count != 3 || arguments[2][0] == L'\0') {
    ::LocalFree(arguments);
    return EXIT_FAILURE;
  }
  const std::wstring request_path(arguments[2]);
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
  const FARPROC symbol =
      ::GetProcAddress(library, "veil_run_windows_vpn_helper");
  if (symbol == nullptr) {
    ::FreeLibrary(library);
    return EXIT_FAILURE;
  }
  static_assert(sizeof(symbol) == sizeof(WindowsVpnHelperFn));
  WindowsVpnHelperFn helper = nullptr;
  std::memcpy(&helper, &symbol, sizeof(helper));
  const int result = helper(request_path.c_str());
  ::FreeLibrary(library);
  return result == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
