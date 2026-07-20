#include "vpn_helper.h"

#include <dlfcn.h>
#include <limits.h>
#include <unistd.h>

#include <iostream>
#include <string>

namespace {

using LinuxVpnHelperFn = int (*)(const char*);

}  // namespace

int RunVpnHelper(const char* config_path) {
  char executable[PATH_MAX];
  const ssize_t length = readlink("/proc/self/exe", executable,
                                  sizeof(executable) - 1);
  if (length <= 0) {
    std::cerr << "{\"phase\":\"error\",\"detail\":\"cannot resolve xVeil executable\"}\n";
    return 1;
  }
  executable[length] = '\0';
  const std::string executable_path(executable);
  const std::string::size_type separator = executable_path.rfind('/');
  if (separator == std::string::npos) {
    std::cerr << "{\"phase\":\"error\",\"detail\":\"invalid xVeil executable path\"}\n";
    return 1;
  }
  const std::string library = executable_path.substr(0, separator) +
                              "/lib/libveilclient_ffi.so";
  void* handle = dlopen(library.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) {
    std::cerr << "{\"phase\":\"error\",\"detail\":\"packet engine library is unavailable\"}\n";
    return 1;
  }
  auto* helper = reinterpret_cast<LinuxVpnHelperFn>(
      dlsym(handle, "veil_packet_tunnel_run_linux_helper"));
  if (helper == nullptr) {
    std::cerr << "{\"phase\":\"error\",\"detail\":\"Linux VPN helper ABI is unavailable\"}\n";
    dlclose(handle);
    return 1;
  }
  const int result = helper(config_path);
  // The helper may still have a stdin watcher blocked while the process is
  // exiting after a fatal tunnel error. Do not unload Rust code underneath
  // that thread; this hidden helper mode terminates immediately anyway.
  return result == 0 ? 0 : 1;
}
