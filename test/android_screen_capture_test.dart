import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/android_screen_capture.dart';

void main() {
  test('decodes the strict width/height + I420 platform frame', () {
    final bytes = Uint8List(8 + 8 + 2 + 2);
    final header = ByteData.sublistView(bytes);
    header.setUint32(0, 4);
    header.setUint32(4, 2);
    bytes.setRange(8, bytes.length, List<int>.generate(12, (i) => i));

    final frame = decodeAndroidScreenFrame(bytes);
    expect(frame, isNotNull);
    expect((frame!.width, frame.height), (4, 2));
    expect(frame.y, orderedEquals([0, 1, 2, 3, 4, 5, 6, 7]));
    expect(frame.u, orderedEquals([8, 9]));
    expect(frame.v, orderedEquals([10, 11]));
  });

  test('rejects malformed or unreasonable platform frames', () {
    expect(decodeAndroidScreenFrame(Uint8List(7)), isNull);

    final wrongLength = Uint8List(12);
    final header = ByteData.sublistView(wrongLength);
    header.setUint32(0, 4);
    header.setUint32(4, 2);
    expect(decodeAndroidScreenFrame(wrongLength), isNull);

    final oversized = Uint8List(8);
    final oversizedHeader = ByteData.sublistView(oversized);
    oversizedHeader.setUint32(0, 4096);
    oversizedHeader.setUint32(4, 4096);
    expect(decodeAndroidScreenFrame(oversized), isNull);
  });

  test('enabling screen share cannot outlive the media session', () {
    // A structural check, because the behavioural one is out of reach here:
    // the whole branch is `Platform.isAndroid`, the capture factory is a final
    // field, and a real MediaProjection is not something a unit test starts.
    //
    // What it asserts is the ordering the defect was made of. Enabling share
    // stops the camera FIRST: it nulls `_androidNativeCam` and `_androidCam`
    // and awaits their stops, and in that window all three source fields are
    // null. A hangup landing there finds nothing to stop, tears the engine
    // down and finishes — and the continuation then creates and starts a
    // foreground capture on the far side of the boundary the hangup drew
    // (report18 XV18-H3). So the session epoch has to be taken before those
    // awaits and re-checked before the source is created.
    final source = File('lib/state/veil_call_media.dart').readAsStringSync();
    final start = source.indexOf('Future<bool> setScreenShareEnabled');
    expect(start, isNot(-1), reason: 'setScreenShareEnabled was renamed');
    final end = source.indexOf('\n  Future<', start + 1);
    expect(end, isNot(-1));
    final body = source.substring(start, end).replaceAll(RegExp(r'\s+'), ' ');

    final tookEpoch = body.indexOf('final epoch = _mediaEpoch;');
    final stopsCamera = body.indexOf('await nativeCam.stop();');
    final createsSource = body.indexOf('_startAndroidScreen(engine)');
    final checksEpoch = body.indexOf('if (epoch != _mediaEpoch) return false;');

    for (final (name, at) in [
      ('the session epoch is taken', tookEpoch),
      ('the camera is stopped', stopsCamera),
      ('the screen source is created', createsSource),
      ('the epoch is re-checked', checksEpoch),
    ]) {
      expect(at, isNot(-1), reason: '$name — this branch was rewritten');
    }
    expect(
      tookEpoch < stopsCamera,
      isTrue,
      reason: 'the epoch is taken after the window it is meant to cover opens',
    );
    expect(
      checksEpoch < createsSource,
      isTrue,
      reason:
          'the screen source is created before anything asks whether the '
          'call is still the one that asked for it',
    );
  });
}
