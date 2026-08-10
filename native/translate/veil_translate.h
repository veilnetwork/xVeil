// C ABI over CTranslate2 + SentencePiece: one call in, translated text out.
//
// Shaped like native/whisper/veil_whisper.h on purpose. The Dart side should
// not be assembling a translation pipeline — tokenise, append the end marker,
// beam search, detokenise — because every one of those steps is a place to get
// it subtly wrong in a way that reads as "the model is bad".
//
// Threading: an engine may be used from one thread at a time. Calls are
// serialised internally, so concurrent use is safe but not parallel; open a
// second engine if two translations must genuinely overlap.
#ifndef VEIL_TRANSLATE_H
#define VEIL_TRANSLATE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct veil_translate_engine veil_translate_engine;

// Opens a model directory: a CTranslate2 model (model.bin, config.json,
// shared_vocabulary.json) plus the pair's source.spm and target.spm.
//
// `intra_threads` is how many cores one translation may use; 0 asks the
// library to decide. `beam_size` of 1 is greedy — cheapest, and adequate for
// short chat messages; 4 is the usual quality setting.
//
// Returns NULL if anything is missing or unreadable. Ask
// veil_translate_last_error() with NULL for why.
veil_translate_engine* veil_translate_open(const char* model_dir,
                                           int intra_threads,
                                           int beam_size);

// Translates one UTF-8 string. Returns a NUL-terminated UTF-8 string the
// CALLER owns and must release with veil_translate_free, or NULL on failure.
//
// An empty or whitespace-only input returns an empty string rather than an
// error: nothing to translate is not a fault.
char* veil_translate(veil_translate_engine* engine, const char* text);

// Releases a string returned by veil_translate. Freeing with the platform's
// free() would be wrong wherever the engine and the caller use different
// allocators, which is why this exists.
void veil_translate_free(char* text);

// The last failure on this engine, or on the library itself when `engine` is
// NULL. Owned by the library; valid until the next call on the same engine.
// Never NULL — returns an empty string when nothing has failed.
const char* veil_translate_last_error(const veil_translate_engine* engine);

void veil_translate_close(veil_translate_engine* engine);

// Identifies the build. Used by the same kind of gate that checks the call
// engine: a prebuilt that silently went stale is the failure mode this whole
// family of libraries has, repeatedly.
const char* veil_translate_version(void);

#ifdef __cplusplus
}
#endif

#endif  // VEIL_TRANSLATE_H
