// Embedded micro-thumb (media epic): the thumb travels IN the message —
// unbound manifest-advert field + message row — and must (a) survive the
// wire round-trip, (b) never participate in contentId (same bytes = same id
// with or without a thumb), (c) be generated within the datagram budget.

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/content_manifest.dart';
import 'package:xveil/state/thumbnail.dart';
import 'package:xveil/state/video_thumb.dart';

Uint8List _bytes(int n) =>
    Uint8List.fromList(List.generate(n, (i) => (i * 31 + 7) & 0xff));

Future<Uint8List> _pngOfSize(int w, int h) async {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  // A gradient-ish fill so the PNG is photographic-adjacent, not a flat fill.
  for (var y = 0; y < h; y += 8) {
    canvas.drawRect(
      ui.Rect.fromLTWH(0, y.toDouble(), w.toDouble(), 8),
      ui.Paint()
        ..color = ui.Color.fromARGB(255, (y * 255 ~/ h), 128, 255 - (y * 255 ~/ h)),
    );
  }
  final img = await rec.endRecording().toImage(w, h);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List(0, data.lengthInBytes);
}

void main() {
  test('manifest thumb survives toJson/fromJson and is NOT in contentId', () {
    final bytes = _bytes(64 * 1024);
    final base = ContentManifest.fromBytes('pic.png', bytes, pieceSize: 16 * 1024);
    final thumb = base64Encode(_bytes(1200));
    final withThumb = base.withEvent(msgId: 'm1', thumbB64: thumb);

    // Unbound: identical contentId with and without the thumb.
    expect(withThumb.contentId, base.contentId);
    expect(withThumb.isSelfConsistent, isTrue);

    final decoded = ContentManifest.fromJson(withThumb.toJson());
    expect(decoded, isNotNull);
    expect(decoded!.thumbB64, thumb);
    expect(decoded.contentId, base.contentId);

    // An older sender (no `th` key) still parses, thumb == null.
    final legacyJson = Map<String, dynamic>.from(base.toJson())..remove('th');
    final legacy = ContentManifest.fromJson(legacyJson);
    expect(legacy, isNotNull);
    expect(legacy!.thumbB64, isNull);
  });

  test('makeMessageThumbB64 fits the datagram budget for a large image',
      () async {
    final png = await _pngOfSize(1200, 800);
    final b64 = await makeMessageThumbB64(png);
    expect(b64, isNotNull);
    final raw = base64Decode(b64!);
    expect(raw.length, lessThanOrEqualTo(kThumbMaxRawBytes));
    // It must itself be a decodable image.
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(raw));
    final frame = await codec.getNextFrame();
    expect(frame.image.width, greaterThan(0));
    expect(
      frame.image.width >= frame.image.height,
      isTrue, // 1200x800 is landscape — aspect must be preserved
    );
    frame.image.dispose();
    codec.dispose();
  });

  test('makeMessageThumbB64 returns null for non-image bytes', () async {
    expect(await makeMessageThumbB64(_bytes(5000)), isNull);
    expect(await makeMessageThumbB64(Uint8List(0)), isNull);
  });

  group('makeVideoThumbB64 (platform frame grabber wrapper)', () {
    tearDown(() => videoFrameGrabber = channelVideoFrameGrabber);

    test('grabbed frame goes through the same ladder/budget', () async {
      // The platform hands back a small encoded frame (here 64x36, like the
      // real grabbers' maxDim output); the wrapper must budget-encode it.
      videoFrameGrabber = (path) async {
        expect(path, '/tmp/clip.mp4');
        return _pngOfSize(64, 36);
      };
      final b64 = await makeVideoThumbB64('/tmp/clip.mp4');
      expect(b64, isNotNull);
      final raw = base64Decode(b64!);
      expect(raw.length, lessThanOrEqualTo(kThumbMaxRawBytes));
      final codec = await ui.instantiateImageCodec(Uint8List.fromList(raw));
      final frame = await codec.getNextFrame();
      expect(frame.image.width >= frame.image.height, isTrue); // landscape
      frame.image.dispose();
      codec.dispose();
    });

    test('null/empty/undecodable frames yield null (thumb is optional)',
        () async {
      videoFrameGrabber = (path) async => null;
      expect(await makeVideoThumbB64('/tmp/a.mp4'), isNull);
      videoFrameGrabber = (path) async => Uint8List(0);
      expect(await makeVideoThumbB64('/tmp/b.mp4'), isNull);
      videoFrameGrabber = (path) async => _bytes(500); // not an image
      expect(await makeVideoThumbB64('/tmp/c.mp4'), isNull);
    });

    test('the channel grabber returns null when no platform handler exists',
        () async {
      // Under flutter_test there is no host platform — the MethodChannel has
      // no handler and must surface as "no thumb", never a throw (this is the
      // Linux behaviour in production too).
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(await channelVideoFrameGrabber('/tmp/none.mp4'), isNull);
    });
  });
}
