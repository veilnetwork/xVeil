// Voice-message core (voice epic): pure helpers with NO native / Flutter deps,
// so they unit-test freely and are shared by the record path, the send path,
// and the bubble UI.
//
// Wire/storage reuse: a voice message is just a small `.opus` FILE message sent
// over the existing content path. Its duration + a compact waveform ride the
// SAME `thumb` sidecar that image micro-thumbs use (unbound manifest field), so
// there are ZERO new wire / manifest / storage / Message fields. The sidecar is
// distinguished from an image thumb by the [kVoiceSidecarPrefix] tag.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Extension the recorder writes and the bubble keys voice rendering on. Opus
/// in an Ogg container — what the loopback player + every platform decode.
const String kVoiceFileExt = '.opus';

/// Number of amplitude bars in the transmitted waveform. Small enough that the
/// sidecar (1 byte/bar + a short duration prefix, base64) stays well within the
/// image-thumb budget so a voice advert still fits one datagram; dense enough
/// to read as a real waveform in a chat-width bubble.
const int kVoiceWaveformBars = 48;

/// Marks the [thumb] field as a voice sidecar rather than a base64 PNG. Chosen
/// so it can never be confused with a PNG (which is binary, never this ASCII).
const String kVoiceSidecarPrefix = 'vw1:';

/// True when [name] is a voice-message audio blob (by extension). Distinct from
/// a generic audio attachment so only recorder output renders as a voice bubble.
bool isVoiceFileName(String? name) {
  if (name == null) return false;
  return name.toLowerCase().endsWith(kVoiceFileExt);
}

/// A decoded voice sidecar: clip length + normalized bar heights (0..1) + the
/// SENDER's language code (for on-device transcription — a note is in the
/// sender's language, not the receiver's locale). [lang] is null for older
/// senders that didn't carry it.
class VoiceSidecar {
  const VoiceSidecar({
    required this.durationMs,
    required this.bars,
    this.lang,
  });

  final int durationMs;

  /// Bar heights in 0..1, [kVoiceWaveformBars] of them (decode tolerates other
  /// lengths — an older/newer sender is still renderable).
  final List<double> bars;

  /// The sender's language code ("ru"/"en"/…), or null when absent.
  final String? lang;

  Duration get duration => Duration(milliseconds: durationMs);
}

/// Encode [durationMs] + optional [lang] + [bars] (each 0..1) into the compact
/// `thumb` sidecar string `vw1:<durationMs>:<lang>:<base64 of one byte per
/// bar>`. [lang] (the sender's language) may be empty. Bars are quantized to a
/// single byte (0..255) — inaudible precision loss, tiny payload.
String encodeVoiceSidecar(int durationMs, List<double> bars, {String? lang}) {
  final bytes = Uint8List(bars.length);
  for (var i = 0; i < bars.length; i++) {
    final v = (bars[i].clamp(0.0, 1.0) * 255).round();
    bytes[i] = v;
  }
  // lang must be colon-free (a 2-letter code); guard just in case.
  final safeLang = (lang ?? '').replaceAll(':', '');
  return '$kVoiceSidecarPrefix${durationMs < 0 ? 0 : durationMs}:'
      '$safeLang:${base64Encode(bytes)}';
}

/// Decode a `thumb` sidecar written by [encodeVoiceSidecar], or null when [s]
/// is absent / not a voice sidecar / malformed (a hostile or truncated field
/// must never throw — the bubble just falls back to a plain audio row).
/// Tolerates the legacy 2-field form (`vw1:<dur>:<b64>`, no language).
VoiceSidecar? decodeVoiceSidecar(String? s) {
  if (s == null || !s.startsWith(kVoiceSidecarPrefix)) return null;
  try {
    final rest = s.substring(kVoiceSidecarPrefix.length);
    // base64 never contains ':', so splitting is unambiguous: 3 parts = new
    // (dur, lang, b64), 2 parts = legacy (dur, b64).
    final parts = rest.split(':');
    if (parts.length < 2) return null;
    final durationMs = int.parse(parts[0]);
    final String? lang;
    final String b64;
    if (parts.length >= 3) {
      lang = parts[1].isEmpty ? null : parts[1];
      b64 = parts.sublist(2).join(':');
    } else {
      lang = null;
      b64 = parts[1];
    }
    final bytes = base64Decode(b64);
    if (bytes.isEmpty) return null;
    final bars = [for (final b in bytes) b / 255.0];
    return VoiceSidecar(
      durationMs: durationMs < 0 ? 0 : durationMs,
      bars: bars,
      lang: lang,
    );
  } catch (_) {
    return null;
  }
}

/// Downsample a stream of per-frame amplitudes ([samples], any length ≥ 0) to
/// exactly [bars] normalized heights in 0..1. Each output bar is the PEAK of
/// its input window (peaks read as a waveform far better than an average), then
/// the whole set is scaled so the loudest bar is 1.0 — a quiet clip still shows
/// a full-height waveform. Returns all-zero bars for empty/silent input.
List<double> downsampleWaveform(List<double> samples, {int bars = kVoiceWaveformBars}) {
  final out = List<double>.filled(bars, 0);
  if (samples.isEmpty || bars <= 0) return out;
  var peak = 0.0;
  for (var i = 0; i < bars; i++) {
    final lo = (i * samples.length / bars).floor();
    final hi = math.max(lo + 1, ((i + 1) * samples.length / bars).floor());
    var m = 0.0;
    for (var j = lo; j < hi && j < samples.length; j++) {
      final a = samples[j].abs();
      if (a > m) m = a;
    }
    out[i] = m;
    if (m > peak) peak = m;
  }
  if (peak > 0) {
    for (var i = 0; i < bars; i++) {
      out[i] = out[i] / peak;
    }
  }
  return out;
}

/// Format a clip length as `m:ss` (voice bubbles are short — no hours). A null
/// or negative duration shows `0:00`.
String formatVoiceDuration(Duration? d) {
  final total = (d == null || d.isNegative) ? 0 : d.inSeconds;
  final m = total ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
