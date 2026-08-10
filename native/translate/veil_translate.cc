#include "veil_translate.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// The engine's version is not exposed by any CTranslate2 header, so the build
// script passes it in. Left "unknown" rather than omitted: a version string
// that quietly disappears is how a stale prebuilt stops being detectable.
#ifndef VEIL_TRANSLATE_CT2_VERSION
#define VEIL_TRANSLATE_CT2_VERSION "unknown"
#endif

#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

namespace {

// Marian — which is what an OPUS-MT model is — expects the source sequence to
// end with this. Without it the decoder does not know where the input stopped
// and produces text that is correct in substance and badly repetitive in form:
// "I'll see you tomorrow tomorrow tomorrow morning morning at 7 p.m. at 7 p.m."
//
// That is worth stating plainly because the output is not obviously broken. It
// looks like a weak model rather than a missing token, and someone would
// reasonably conclude the engine is no good and go looking for another one.
constexpr const char* kEndOfSequence = "</s>";

std::string join_path(const std::string& dir, const char* name) {
  if (dir.empty()) return name;
  if (dir.back() == '/' || dir.back() == '\\') return dir + name;
  return dir + "/" + name;
}

bool is_blank(const char* text) {
  for (const char* p = text; *p; ++p) {
    if (!std::isspace(static_cast<unsigned char>(*p))) return false;
  }
  return true;
}

std::string& library_error() {
  static std::string error;
  return error;
}

}  // namespace

struct veil_translate_engine {
  std::unique_ptr<ctranslate2::Translator> translator;
  sentencepiece::SentencePieceProcessor source;
  sentencepiece::SentencePieceProcessor target;
  ctranslate2::TranslationOptions options;
  std::mutex lock;
  std::string last_error;
};

veil_translate_engine* veil_translate_open(const char* model_dir,
                                           int intra_threads,
                                           int beam_size) {
  library_error().clear();
  if (model_dir == nullptr || *model_dir == '\0') {
    library_error() = "no model directory given";
    return nullptr;
  }

  auto engine = std::make_unique<veil_translate_engine>();
  const std::string dir(model_dir);

  // The tokenisers first: they are cheap, and failing on them before loading
  // a hundred megabytes of weights is the difference between an instant answer
  // and a long wait for one.
  const auto source_status = engine->source.Load(join_path(dir, "source.spm"));
  if (!source_status.ok()) {
    library_error() = "source.spm: " + source_status.ToString();
    return nullptr;
  }
  const auto target_status = engine->target.Load(join_path(dir, "target.spm"));
  if (!target_status.ok()) {
    library_error() = "target.spm: " + target_status.ToString();
    return nullptr;
  }

  try {
    ctranslate2::ComputeType compute_type = ctranslate2::ComputeType::INT8;
    engine->translator = std::make_unique<ctranslate2::Translator>(
        dir, ctranslate2::Device::CPU, compute_type,
        /*device_indices=*/std::vector<int>{0},
        /*tensor_parallel=*/false,
        ctranslate2::ReplicaPoolConfig{
            /*num_threads_per_replica=*/static_cast<size_t>(std::max(0, intra_threads)),
            /*max_queued_batches=*/0,
            /*cpu_core_offset=*/-1});
  } catch (const std::exception& e) {
    library_error() = std::string("model: ") + e.what();
    return nullptr;
  }

  engine->options.beam_size = static_cast<size_t>(beam_size > 0 ? beam_size : 1);
  // A translation cannot usefully be many times longer than its input, and an
  // unbounded decode is how a degenerate repetition loop turns a chat bubble
  // into a hung UI.
  engine->options.max_decoding_length = 256;
  return engine.release();
}

char* veil_translate(veil_translate_engine* engine, const char* text) {
  if (engine == nullptr) {
    library_error() = "no engine";
    return nullptr;
  }
  std::lock_guard<std::mutex> guard(engine->lock);
  engine->last_error.clear();

  if (text == nullptr || is_blank(text)) {
    char* empty = static_cast<char*>(std::malloc(1));
    if (empty != nullptr) empty[0] = '\0';
    return empty;
  }

  try {
    std::vector<std::string> pieces;
    const auto status = engine->source.Encode(text, &pieces);
    if (!status.ok()) {
      engine->last_error = "encode: " + status.ToString();
      return nullptr;
    }
    pieces.emplace_back(kEndOfSequence);

    const auto results = engine->translator->translate_batch(
        std::vector<std::vector<std::string>>{pieces}, engine->options);
    if (results.empty() || results[0].hypotheses.empty()) {
      engine->last_error = "the model returned no hypothesis";
      return nullptr;
    }

    std::string out;
    const auto decoded = engine->target.Decode(results[0].hypotheses[0], &out);
    if (!decoded.ok()) {
      engine->last_error = "decode: " + decoded.ToString();
      return nullptr;
    }

    char* copy = static_cast<char*>(std::malloc(out.size() + 1));
    if (copy == nullptr) {
      engine->last_error = "out of memory";
      return nullptr;
    }
    std::memcpy(copy, out.c_str(), out.size() + 1);
    return copy;
  } catch (const std::exception& e) {
    engine->last_error = e.what();
    return nullptr;
  }
}

void veil_translate_free(char* text) { std::free(text); }

const char* veil_translate_last_error(const veil_translate_engine* engine) {
  if (engine == nullptr) return library_error().c_str();
  return engine->last_error.c_str();
}

void veil_translate_close(veil_translate_engine* engine) { delete engine; }

const char* veil_translate_version(void) {
  return "veil_translate 1 ctranslate2 " VEIL_TRANSLATE_CT2_VERSION;
}
