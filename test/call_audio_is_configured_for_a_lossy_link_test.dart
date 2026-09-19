import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural, because what this guards is a STRING handed to a C++ codec
/// factory inside a dylib that no Dart test can load, and whose absence is
/// invisible: `SdpAudioFormat("opus", 48000, 2)` with no parameters is a
/// perfectly valid call that quietly runs with FEC off, DTX off and stereo on.
/// Nothing reddens, nothing logs; the only symptom is a listener on a lossy
/// link hearing dropouts and a jitter buffer that grows to cover them.
void main() {
  final engine = File(
    'third_party/veil/flutter/veil_media/src/veil_media_engine.cc',
  );

  test('the Opus send format asks for mono, inband FEC and DTX', () {
    final source = engine.readAsStringSync();
    // Vacuity guard: a moved or unreadable file must redden here rather than
    // satisfy the absence checks below by being empty.
    expect(source.length, greaterThan(10000));

    final helper = RegExp(
      r'SdpAudioFormat VeilOpusSendFormat\(\)\s*\{(.*?)\n\}',
      dotAll: true,
    ).firstMatch(source);
    expect(
      helper,
      isNotNull,
      reason: 'VeilOpusSendFormat is gone — the send format is being built '
          'somewhere else and this guard no longer sees it',
    );
    final body = helper!.group(1)!;
    for (final param in const [
      '{"stereo", "0"}',
      '{"useinbandfec", "1"}',
      '{"usedtx", "1"}',
    ]) {
      expect(
        body.contains(param),
        isTrue,
        reason: '$param dropped from the Opus send format: the encoder falls '
            'back to a WebRTC default that is wrong for a voice call on a '
            'mobile link',
      );
    }
  });

  test('every audio send stream goes through that one format', () {
    final source = engine.readAsStringSync();
    // Both the 1:1 call and the group room build a SendCodecSpec. A second
    // copy of the literal is how one of them silently keeps the old defaults.
    final specs = RegExp(
      r'SendCodecSpec\(\s*kOpusPayloadType,\s*([A-Za-z_][A-Za-z0-9_]*\(\)|'
      r'webrtc::SdpAudioFormat\([^)]*\))',
      dotAll: true,
    ).allMatches(source).map((m) => m.group(1)!.trim()).toList();

    expect(
      specs,
      isNotEmpty,
      reason: 'no audio send stream found — re-point this guard',
    );
    for (final spec in specs) {
      expect(
        spec,
        'VeilOpusSendFormat()',
        reason: 'an audio send stream builds its own Opus format instead of '
            'the shared one, so it keeps the defaults the shared one exists '
            'to replace',
      );
    }
  });
}
