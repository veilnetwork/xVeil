// POSIX host regression probe; no Flutter or GUI. Compile with C++17 (+ -ldl
// on Linux). Arguments: qualified SDK library, test identity TOML, private
// short-path fixture directory, config|deferred. The parent must perform a
// real admin health request after the ready event, then write a line to stdin.
// The public test identity must only be used with this isolated configuration.
#include <dlfcn.h>
#include <signal.h>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <thread>

namespace fs = std::filesystem;
static volatile sig_atomic_t received[32] = {};
static void host_signal(int value) { received[value] = received[value] + 1; }

template <class T> T symbol(void* library, const char* name) {
  auto value = dlsym(library, name);
  if (!value) throw std::runtime_error("required symbol missing");
  return reinterpret_cast<T>(value);
}

static std::string read(const fs::path& path) {
  std::ifstream stream(path);
  if (!stream) throw std::runtime_error("fixture read refused");
  return {std::istreambuf_iterator<char>(stream), {}};
}

static void global_setting(std::string& config, const std::string& key,
                           const std::string& value) {
  auto start = config.find("[global]\n");
  if (start == std::string::npos) throw std::runtime_error("global section missing");
  start += std::string("[global]\n").size();
  auto end = config.find("\n[", start);
  if (end == std::string::npos) end = config.size();
  const auto field = config.find(key + " = ", start);
  if (field < end) {
    const auto newline = config.find('\n', field);
    config.replace(field, (newline == std::string::npos ? end : newline) - field,
                   key + " = " + value);
  } else {
    config.insert(start, key + " = " + value + "\n");
  }
}

int main(int argc, char** argv) {
  try {
    if (argc != 5) throw std::runtime_error("four arguments required");
    const bool deferred = std::string(argv[4]) == "deferred";
    if (!deferred && std::string(argv[4]) != "config")
      throw std::runtime_error("invalid mode");
    const fs::path root = fs::absolute(argv[3]);
    if (!fs::is_directory(root) || fs::is_symlink(root))
      throw std::runtime_error("private fixture directory required");
    const auto identity = read(argv[2]);
    const auto admin = (root / "admin.sock").string();
    const auto ipc = (root / "app.sock").string();
    const auto path = (root / "node.toml").string();
    const std::string listen = "quic://127.0.0.1:0";
    const int signals[] = {SIGINT, SIGTERM, SIGHUP};
    struct sigaction before[3] = {};
    for (int index = 0; index < 3; ++index) {
      struct sigaction action = {};
      action.sa_handler = host_signal;
      sigemptyset(&action.sa_mask);
      if (sigaction(signals[index], &action, nullptr) ||
          sigaction(signals[index], nullptr, &before[index]))
        throw std::runtime_error("host signal setup refused");
    }
    auto library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) throw std::runtime_error("qualified SDK load refused");
    using Compose = char* (*)(const char*, size_t, const char*, size_t,
                             const char*, size_t, const char*, size_t, char**);
    auto compose = symbol<Compose>(library, "veil_config_compose");
    auto free_string = symbol<void (*)(char*)>(library, "veil_free_string");
    auto start = symbol<void* (*)(const char*, size_t, char**)>(library, "veil_node_start");
    auto start_deferred = symbol<void* (*)(const char*, size_t, bool, char**)>(
        library, "veil_node_start_deferred");
    auto apply = symbol<int (*)(void*, const char*, size_t, char**)>(library, "veil_node_apply_config");
    auto stop = symbol<int (*)(void*, uint64_t)>(library, "veil_node_stop_timeout");
    char* error = nullptr;
    auto text = compose(identity.data(), identity.size(), listen.data(), listen.size(),
                        ipc.data(), ipc.size(), admin.data(), admin.size(), &error);
    if (!text) throw std::runtime_error("isolated config composition refused");
    std::string config(text);
    free_string(text);
    global_setting(config, "builtin_seed_policy", "\"never\"");
    global_setting(config, "meeting_points", "\"off\"");
    global_setting(config, "bootstrap", "false");
    std::ofstream(path) << config;
    void* node = deferred ? start_deferred(admin.data(), admin.size(), false, &error)
                          : start(path.data(), path.size(), &error);
    if (!node) throw std::runtime_error("node startup refused");
    if (deferred && apply(node, config.data(), config.size(), &error) != 0) {
      stop(node, 8000);
      throw std::runtime_error("deferred config application refused");
    }
    std::cout << "{\"event\":\"ready\"}" << std::endl;
    std::string barrier;
    if (!std::getline(std::cin, barrier) || barrier != "sample") {
      stop(node, 8000);
      throw std::runtime_error("admin readiness barrier missing");
    }
    bool running[3] = {};
    bool stopped[3] = {};
    for (int index = 0; index < 3; ++index) {
      struct sigaction current = {};
      if (sigaction(signals[index], nullptr, &current))
        throw std::runtime_error("signal inspection refused");
      running[index] = current.sa_handler == before[index].sa_handler;
    }
    const int stopped_result = stop(node, 8000);
    bool preserved = stopped_result == 0;
    for (int index = 0; index < 3; ++index) {
      struct sigaction current = {};
      if (sigaction(signals[index], nullptr, &current))
        throw std::runtime_error("signal inspection refused");
      stopped[index] = current.sa_handler == before[index].sa_handler;
      preserved = preserved && running[index] && stopped[index];
    }
    bool delivered = preserved;
    if (preserved) {
      for (const int value : signals) {
        const auto count = received[value];
        if (raise(value) || received[value] != count + 1) delivered = false;
      }
    }
    std::cout << std::boolalpha << "{\"event\":\"result\",\"stopResult\":"
              << stopped_result << ",\"runningPreserved\":[" << running[0] << ','
              << running[1] << ',' << running[2] << "],\"stoppedPreserved\":["
              << stopped[0] << ',' << stopped[1] << ',' << stopped[2]
              << "],\"hostReceivedAfterStop\":" << delivered << '}' << std::endl;
    // Do not dlclose: asynchronous runtime resources are process-scoped. The
    // test process exits after the SDK's explicit stop has completed.
    return preserved && delivered ? 0 : 2;
  } catch (const std::exception& error) {
    std::cerr << "embedded host probe: " << error.what() << std::endl;
    return 10;
  }
}
