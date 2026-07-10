/* SPDX-License-Identifier: MIT
 *
 * veil_whisper.cc — implementation of the on-device STT ABI (whisper.cpp).
 */

#include "veil_whisper.h"

#include <cstdlib>
#include <cstring>
#include <string>

#include "whisper.h"

extern "C" {

char* veil_whisper_transcribe(const char* model_path, const float* pcm16k,
                              int n_samples, const char* lang) {
  if (model_path == nullptr || pcm16k == nullptr || n_samples <= 0) {
    return nullptr;
  }
  whisper_context_params cparams = whisper_context_default_params();
  // CPU build — no GPU. Keep it explicit so a GPU-enabled build still runs the
  // occasional transcribe on CPU predictably.
  cparams.use_gpu = false;
  whisper_context* ctx =
      whisper_init_from_file_with_params(model_path, cparams);
  if (ctx == nullptr) return nullptr;

  whisper_full_params wparams =
      whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  wparams.n_threads = 4;
  wparams.print_progress = false;
  wparams.print_realtime = false;
  wparams.print_timestamps = false;
  wparams.print_special = false;
  wparams.translate = false;         // transcribe in the spoken language
  wparams.no_timestamps = true;      // we only want the text
  const bool auto_lang =
      lang == nullptr || lang[0] == '\0' || std::strcmp(lang, "auto") == 0;
  wparams.language = auto_lang ? "auto" : lang;
  wparams.detect_language = auto_lang;

  char* result = nullptr;
  if (whisper_full(ctx, wparams, pcm16k, n_samples) == 0) {
    std::string text;
    const int n = whisper_full_n_segments(ctx);
    for (int i = 0; i < n; i++) {
      const char* seg = whisper_full_get_segment_text(ctx, i);
      if (seg) text += seg;
    }
    // Trim a leading space whisper often emits.
    size_t start = text.find_first_not_of(' ');
    if (start != std::string::npos && start > 0) text = text.substr(start);
    result = strdup(text.c_str());
  }
  whisper_free(ctx);
  return result;
}

void veil_whisper_free_string(char* s) {
  if (s) free(s);
}

const char* veil_whisper_version(void) { return "veil_whisper 0.0.1"; }

}  // extern "C"
