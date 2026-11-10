// Real media DLL, isolated transport stub, no microphone, playback or profile.
// Destroying a module created on the media thread must not uninitialize COM
// on the caller. Run each engine/apartment combination in a fresh process.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cwchar>
#include <stdexcept>
#include <thread>

template <typename T> T Symbol(HMODULE module, const char* name) {
  auto value = reinterpret_cast<T>(GetProcAddress(module, name));
  if (!value) throw std::runtime_error("missing fixture API");
  return value;
}

struct Apartment {
  HRESULT result;
  APTTYPE type = APTTYPE_CURRENT;
  APTTYPEQUALIFIER qualifier = APTTYPEQUALIFIER_NONE;
  ULONG_PTR context = 0;
  HRESULT context_result;
  Apartment() {
    result = CoGetApartmentType(&type, &qualifier);
    context_result = CoGetContextToken(&context);
  }
  bool Same(const Apartment& other) const {
    return result == S_OK && other.result == S_OK && type == other.type &&
           qualifier == other.qualifier && context_result == S_OK &&
           other.context_result == S_OK && context == other.context;
  }
};

int wmain(int argc, wchar_t** argv) {
  if (argc != 5) return 2;
  const bool group = wcscmp(argv[3], L"group") == 0;
  const bool sta = wcscmp(argv[4], L"sta") == 0;
  if ((!group && wcscmp(argv[3], L"unicast") != 0) ||
      (!sta && wcscmp(argv[4], L"mta") != 0)) return 2;
  std::thread([] {
    std::this_thread::sleep_for(std::chrono::seconds(15));
    ExitProcess(98);
  }).detach();
  const HRESULT initialized = CoInitializeEx(
      nullptr, sta ? COINIT_APARTMENTTHREADED : COINIT_MULTITHREADED);
  if (FAILED(initialized)) return 3;
  const Apartment before;
  if (before.result != S_OK || before.context_result != S_OK) return 4;
  try {
    const auto flags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS;
    HMODULE boundary = LoadLibraryExW(argv[1], nullptr, flags);
    HMODULE media = LoadLibraryExW(argv[2], nullptr, flags);
    if (!boundary || !media) throw std::runtime_error("fixture load refused");
    std::array<uint8_t, 32> local{}, peer{};
    local.fill(1); peer.fill(2);
    void* engine = nullptr;
    void (__cdecl* destroy)(void*) = nullptr;
    if (group) {
      const auto create = Symbol<void* (__cdecl*)(const uint8_t*)>(
          media, "veil_media_group_engine_create");
      destroy = Symbol<void (__cdecl*)(void*)>(media, "veil_media_group_engine_destroy");
      engine = create(local.data());
    } else {
      const auto create = Symbol<void* (__cdecl*)(uint64_t, const uint8_t*, const uint8_t*)>(
          media, "veil_media_engine_create");
      destroy = Symbol<void (__cdecl*)(void*)>(media, "veil_media_engine_destroy");
      engine = create(777, local.data(), peer.data());
    }
    if (!engine) throw std::runtime_error("engine creation refused");
    const Apartment after_create;
    destroy(engine);
    const Apartment after_destroy;
    const bool kept_create = before.Same(after_create);
    const bool kept_destroy = before.Same(after_destroy);
    std::printf(
        "{\"engine_created\":true,\"creation_preserved_com\":%s,"
        "\"destruction_preserved_com\":%s,\"before_type\":%d,"
        "\"after_type\":%d,\"after_hresult\":%ld,\"after_qualifier\":%d}\n",
        kept_create ? "true" : "false", kept_destroy ? "true" : "false",
        static_cast<int>(before.type), static_cast<int>(after_destroy.type),
        static_cast<long>(after_destroy.result), static_cast<int>(after_destroy.qualifier));
    // Do not uninitialize a caller apartment the engine already destroyed.
    if (kept_destroy) CoUninitialize();
    return kept_create && kept_destroy ? 0 : 1;
  } catch (...) {
    std::puts("{\"fixture_failed\":true}");
    return 5;
  }
}
