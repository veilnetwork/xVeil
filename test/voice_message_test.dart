import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/voice_message.dart';

void main() {
  group('isVoiceFileName', () {
    test('matches .opus only, case-insensitive', () {
      expect(isVoiceFileName('clip.opus'), isTrue);
      expect(isVoiceFileName('CLIP.OPUS'), isTrue);
      expect(isVoiceFileName('song.mp3'), isFalse);
      expect(isVoiceFileName('pic.png'), isFalse);
      expect(isVoiceFileName(null), isFalse);
    });
  });

  group('voice sidecar round-trip', () {
    test('duration + bars survive encode/decode within a byte of precision', () {
      final bars = [0.0, 0.25, 0.5, 0.75, 1.0, 0.1];
      final enc = encodeVoiceSidecar(12345, bars);
      expect(enc.startsWith(kVoiceSidecarPrefix), isTrue);

      final dec = decodeVoiceSidecar(enc);
      expect(dec, isNotNull);
      expect(dec!.durationMs, 12345);
      expect(dec.bars.length, bars.length);
      for (var i = 0; i < bars.length; i++) {
        expect((dec.bars[i] - bars[i]).abs(), lessThan(1 / 255 + 1e-9));
      }
    });

    test('carries the sender language; legacy 2-field form decodes lang=null',
        () {
      final enc = encodeVoiceSidecar(2000, [0.5, 0.5], lang: 'ru');
      final dec = decodeVoiceSidecar(enc);
      expect(dec!.lang, 'ru');
      expect(dec.durationMs, 2000);
      expect(dec.bars.length, 2);
      // Empty lang → null on decode.
      expect(decodeVoiceSidecar(encodeVoiceSidecar(1000, [0.5]))!.lang, isNull);
      // Legacy 2-field sidecar (no lang segment) still decodes.
      final legacy = 'vw1:1500:${base64Encode(Uint8List.fromList([128]))}';
      final ld = decodeVoiceSidecar(legacy);
      expect(ld!.durationMs, 1500);
      expect(ld.lang, isNull);
      expect(ld.bars.length, 1);
    });

    test('decode rejects non-voice / malformed / null without throwing', () {
      expect(decodeVoiceSidecar(null), isNull);
      expect(decodeVoiceSidecar('iVBORw0KGgo='), isNull); // a PNG thumb
      expect(decodeVoiceSidecar('vw1:'), isNull); // no separator
      expect(decodeVoiceSidecar('vw1:abc:zzz'), isNull); // bad duration
      expect(decodeVoiceSidecar('vw1:100:@@@@'), isNull); // bad base64
    });

    test('negative duration is clamped to 0 on both ends', () {
      final enc = encodeVoiceSidecar(-5, [0.5]);
      final dec = decodeVoiceSidecar(enc);
      expect(dec!.durationMs, 0);
    });

    test('bars are clamped to 0..1 before quantizing', () {
      final enc = encodeVoiceSidecar(1000, [-1.0, 2.0]);
      final dec = decodeVoiceSidecar(enc);
      expect(dec!.bars[0], 0.0);
      expect(dec.bars[1], 1.0);
    });
  });

  group('downsampleWaveform', () {
    test('produces exactly N bars normalized so the peak is 1.0', () {
      final samples = List<double>.generate(1000, (i) => (i % 100) / 100.0);
      final bars = downsampleWaveform(samples, bars: 48);
      expect(bars.length, 48);
      expect(bars.every((b) => b >= 0 && b <= 1), isTrue);
      expect(bars.reduce((a, b) => a > b ? a : b), closeTo(1.0, 1e-9));
    });

    test('empty / silent input yields all-zero bars, no divide-by-zero', () {
      expect(downsampleWaveform(const [], bars: 8), List.filled(8, 0.0));
      expect(downsampleWaveform(List.filled(50, 0.0), bars: 8),
          List.filled(8, 0.0));
    });

    test('uses peaks: a single loud spike in a window shows full height', () {
      final samples = List<double>.filled(96, 0.01);
      samples[10] = 1.0; // spike in the first half
      final bars = downsampleWaveform(samples, bars: 2);
      expect(bars[0], closeTo(1.0, 1e-9)); // peak-normalized to the spike
      expect(bars[1], lessThan(0.1));
    });

    test('fewer samples than bars still fills every bar', () {
      final bars = downsampleWaveform([1.0, 0.5, 0.25], bars: 48);
      expect(bars.length, 48);
      expect(bars.any((b) => b > 0), isTrue);
    });
  });

  group('formatVoiceDuration', () {
    test('m:ss with zero-padded seconds', () {
      expect(formatVoiceDuration(const Duration(seconds: 5)), '0:05');
      expect(formatVoiceDuration(const Duration(seconds: 65)), '1:05');
      expect(formatVoiceDuration(const Duration(minutes: 2)), '2:00');
      expect(formatVoiceDuration(null), '0:00');
      expect(formatVoiceDuration(const Duration(seconds: -3)), '0:00');
    });
  });
}
