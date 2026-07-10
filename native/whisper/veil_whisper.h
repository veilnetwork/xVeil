/* SPDX-License-Identifier: MIT
 *
 * veil_whisper.h — thin on-device speech-to-text ABI over whisper.cpp.
 *
 * A single self-contained lib (libveil_whisper) that statically links
 * whisper.cpp + ggml and exports a minimal extern-C surface. Everything runs
 * ON DEVICE: audio (PCM) and the produced text never leave the process — the
 * xVeil privacy canon for voice-note transcription.
 *
 * Input is 16 kHz mono float32 PCM (what whisper expects); the caller decodes
 * the stored VOICE_OPUS clip to that with veil_media_decode_pcm16k.
 */

#ifndef VEIL_WHISPER_H
#define VEIL_WHISPER_H

#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma GCC visibility push(default)

/* Transcribe [pcm16k] ([n_samples] float32 @ 16 kHz mono) with the ggml model
 * at [model_path]. [lang] is a whisper language code ("ru", "en", ...) or
 * "auto"/NULL for auto-detect. Returns the concatenated transcript as a
 * heap-allocated UTF-8 C string (free with veil_whisper_free_string), or NULL
 * on failure (bad model / decode error). Blocking + CPU-heavy — call OFF the
 * UI thread. */
char* veil_whisper_transcribe(const char* model_path, const float* pcm16k,
                              int n_samples, const char* lang);

/* Free a string returned by veil_whisper_transcribe. */
void veil_whisper_free_string(char* s);

/* ABI/build probe (static string, do not free). */
const char* veil_whisper_version(void);

#pragma GCC visibility pop

#ifdef __cplusplus
}
#endif

#endif /* VEIL_WHISPER_H */
