import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';

@immutable
class AndroidNativeCallVideoTexture {
  const AndroidNativeCallVideoTexture({
    required this.textureId,
    required this.width,
    required this.height,
    required this.frames,
    required this.lastFrameAt,
  });

  final int textureId;
  final int width;
  final int height;
  final int frames;
  final DateTime? lastFrameAt;

  bool get hasFrame => frames > 0 && width > 0 && height > 0;
}

final ValueNotifier<AndroidNativeCallVideoTexture?>
androidNativeCallVideoTexture = ValueNotifier<AndroidNativeCallVideoTexture?>(
  null,
);

/// Control-only bridge for Android's native decoded-video texture.
class AndroidNativeCallVideoRenderer {
  AndroidNativeCallVideoRenderer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('xveil/native_call_video');

  final MethodChannel _channel;

  /// Bumped by every [start] and every [stop].
  ///
  /// `refreshStats` reads the texture id, awaits the platform channel and then
  /// PUBLISHES. A stop landing in that window cleared the id and the notifier,
  /// and the poll then republished the texture it had captured — a texture the
  /// native side has freed. If a new call had started meanwhile, the stale poll
  /// overwrote ITS texture with the dead one (report9 X-11).
  int _generation = 0;

  /// Whether a stats poll is in flight.
  ///
  /// Read by the TIMER only. The timer fires every 200ms and a poll slower
  /// than that used to overlap itself, with two answers publishing in whatever
  /// order the platform returned them. An explicit [refreshStats] still always
  /// polls: a caller asking for fresh numbers and silently getting none is a
  /// worse contract than an occasional overlap, and the existing renderer test
  /// says so.
  bool _polling = false;

  Timer? _statsTimer;
  int? _textureId;
  int _lastFrames = 0;
  DateTime? _lastFrameAt;
  Map<String, Object?> _diagnostics = const {};

  bool get isRunning => _textureId != null;
  Map<String, Object?> get diagnostics => _diagnostics;

  Future<bool> start({required int engineAddress}) async {
    await stop();
    final generation = ++_generation;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('start', {
        'engine': engineAddress,
      });
      final textureId = (value?['textureId'] as num?)?.toInt();
      if (textureId == null || textureId < 0) {
        await _channel.invokeMethod<void>('stop');
        return false;
      }
      if (generation != _generation) {
        // Stopped — or restarted — while this start was in flight. The texture
        // this call created belongs to nobody, so hand it back rather than
        // publish it over whatever is current now.
        await _channel.invokeMethod<void>('stop');
        return false;
      }
      _textureId = textureId;
      _lastFrames = 0;
      _lastFrameAt = null;
      androidNativeCallVideoTexture.value = AndroidNativeCallVideoTexture(
        textureId: textureId,
        width: 0,
        height: 0,
        frames: 0,
        lastFrameAt: null,
      );
      _statsTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (_polling) return; // the previous tick has not answered yet
        unawaited(refreshStats());
      });
      unawaited(refreshStats());
      return true;
    } on PlatformException catch (error) {
      devLog(
        () =>
            'veil-video-texture: start failed ${error.code}: ${error.message}',
      );
      return false;
    } catch (error) {
      devLog(() => 'veil-video-texture: start failed: $error');
      return false;
    }
  }

  Future<void> refreshStats() async {
    final textureId = _textureId;
    if (textureId == null) return;
    final generation = _generation;
    _polling = true;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('stats');
      if (value == null) return;
      // Everything below publishes. A stop or a restart in the await above
      // means this answer describes a texture that is gone.
      if (generation != _generation) return;
      final diagnostics = value.map(
        (key, item) => MapEntry(key?.toString() ?? '', item),
      )..remove('');
      _diagnostics = diagnostics;
      if (diagnostics['video_texture_running'] == false) {
        await stop();
        return;
      }
      final frames =
          (diagnostics['video_texture_frames'] as num?)?.toInt() ?? 0;
      final width = (diagnostics['video_texture_width'] as num?)?.toInt() ?? 0;
      final height =
          (diagnostics['video_texture_height'] as num?)?.toInt() ?? 0;
      if (frames > _lastFrames) _lastFrameAt = DateTime.now();
      _lastFrames = frames;
      final next = AndroidNativeCallVideoTexture(
        textureId: textureId,
        width: width,
        height: height,
        frames: frames,
        lastFrameAt: _lastFrameAt,
      );
      final previous = androidNativeCallVideoTexture.value;
      if (previous?.textureId != next.textureId ||
          previous?.width != next.width ||
          previous?.height != next.height ||
          previous?.frames != next.frames) {
        androidNativeCallVideoTexture.value = next;
      }
    } catch (_) {
      // A diagnostics poll is advisory and cannot disturb a running renderer.
    } finally {
      _polling = false;
    }
  }

  Future<void> stop() async {
    _generation++;
    _statsTimer?.cancel();
    _statsTimer = null;
    _textureId = null;
    _lastFrames = 0;
    _lastFrameAt = null;
    _diagnostics = const {};
    androidNativeCallVideoTexture.value = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {}
  }
}
