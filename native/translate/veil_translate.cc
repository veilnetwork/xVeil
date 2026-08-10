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

// Split into units a translation model can actually handle.
//
// An NMT model translates a SENTENCE. Handed a whole paragraph as one
// sequence it does not merely slow down: the tail goes missing, quietly, and a
// truncated translation says nothing about having been truncated. This is not
// a decoding-length question — raising that bound did not bring the ending
// back — it is what the model was trained to do.
//
// So: paragraphs by newline, sentences by terminal punctuation, and anything
// still enormous cut at a space. Deliberately simple. A perfect splitter needs
// per-language abbreviation lists; being wrong here costs a slightly odd break
// between two translated sentences, while not splitting at all costs the end
// of the message.
std::vector<std::string> split_for_translation(const std::string& text) {
  // Roughly a long sentence. Past this a chunk is cut at whitespace rather
  // than fed whole, so a wall of text with no punctuation still arrives.
  constexpr size_t kMaxChunkChars = 600;

  std::vector<std::string> chunks;
  size_t start = 0;
  const size_t n = text.size();

  auto flush = [&](size_t from, size_t to) {
    while (from < to && std::isspace(static_cast<unsigned char>(text[from]))) ++from;
    while (to > from && std::isspace(static_cast<unsigned char>(text[to - 1]))) --to;
    if (to > from) chunks.emplace_back(text.substr(from, to - from));
  };

  for (size_t i = 0; i < n; ++i) {
    const char c = text[i];
    const bool terminal = (c == '.' || c == '!' || c == '?' || c == '\n');
    if (!terminal) continue;
    // A terminator ends a sentence when what follows is space or the end;
    // "3.14" and "e.g." then stay in one piece more often than not.
    if (c != '\n' && i + 1 < n &&
        !std::isspace(static_cast<unsigned char>(text[i + 1]))) {
      continue;
    }
    flush(start, i + 1);
    start = i + 1;
  }
  flush(start, n);

  // Second pass: cut anything still too long at a space.
  std::vector<std::string> bounded;
  for (const auto& chunk : chunks) {
    size_t at = 0;
    while (chunk.size() - at > kMaxChunkChars) {
      size_t cut = chunk.rfind(' ', at + kMaxChunkChars);
      if (cut == std::string::npos || cut <= at) cut = at + kMaxChunkChars;
      bounded.emplace_back(chunk.substr(at, cut - at));
      at = cut;
      while (at < chunk.size() && chunk[at] == ' ') ++at;
    }
    if (at < chunk.size()) bounded.emplace_back(chunk.substr(at));
  }
  return bounded;
}

std::string& library_error() {
  // thread_local, not a plain static. Opening an engine writes this, and
  // nothing serialises opens: the Dart side gives each language pair its own
  // isolate, so two directions opening at once wrote the same std::string from
  // two threads — a data race, and undefined behaviour rather than a garbled
  // message.
  //
  // Per-thread is also the right shape for what it is FOR: the caller reads
  // the reason on the thread whose open just failed, and another thread's
  // failure was never any of its business.
  thread_local std::string error;
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
    const auto chunks = split_for_translation(text);
    if (chunks.empty()) {
      char* empty = static_cast<char*>(std::malloc(1));
      if (empty != nullptr) empty[0] = '\0';
      return empty;
    }

    std::vector<std::vector<std::string>> batch;
    batch.reserve(chunks.size());
    size_t longest = 0;
    for (const auto& chunk : chunks) {
      std::vector<std::string> pieces;
      const auto status = engine->source.Encode(chunk, &pieces);
      if (!status.ok()) {
        engine->last_error = "encode: " + status.ToString();
        return nullptr;
      }
      // Marian expects the source to end with this. Without it the decoder
      // does not know where the input stopped and repeats itself: fluent,
      // plausible and wrong in a way that reads as a weak model.
      pieces.emplace_back(kEndOfSequence);
      longest = std::max(longest, pieces.size());
      batch.emplace_back(std::move(pieces));
    }

    // Bound the decode against the longest chunk rather than with a constant.
    // Unbounded, a degenerate repetition loop hangs the UI; fixed, it cuts
    // honest text. No language expands fourfold, so this never bites a real
    // translation.
    auto options = engine->options;
    options.max_decoding_length = std::max<size_t>(64, longest * 4);

    // One batch, not a loop: the whole point of a batch is that the engine
    // runs them together.
    const auto results = engine->translator->translate_batch(batch, options);
    if (results.size() != batch.size()) {
      engine->last_error = "the model answered a different number of sentences";
      return nullptr;
    }

    std::string out;
    for (size_t i = 0; i < results.size(); ++i) {
      if (results[i].hypotheses.empty()) {
        engine->last_error = "the model returned no hypothesis";
        return nullptr;
      }
      std::string piece;
      const auto decoded = engine->target.Decode(results[i].hypotheses[0], &piece);
      if (!decoded.ok()) {
        engine->last_error = "decode: " + decoded.ToString();
        return nullptr;
      }
      if (!out.empty() && !piece.empty()) out += ' ';
      out += piece;
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
