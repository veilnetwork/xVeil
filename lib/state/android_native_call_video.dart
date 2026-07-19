import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
  Timer? _statsTimer;
  int? _textureId;
  int _lastFrames = 0;
  DateTime? _lastFrameAt;
  Map<String, Object?> _diagnostics = const {};

  bool get isRunning => _textureId != null;
  Map<String, Object?> get diagnostics => _diagnostics;

  Future<bool> start({required int engineAddress}) async {
    await stop();
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('start', {
        'engine': engineAddress,
      });
      final textureId = (value?['textureId'] as num?)?.toInt();
      if (textureId == null || textureId < 0) {
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
      _statsTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => unawaited(refreshStats()),
      );
      unawaited(refreshStats());
      return true;
    } on PlatformException catch (error) {
      debugPrint(
        'veil-video-texture: start failed ${error.code}: ${error.message}',
      );
      return false;
    } catch (error) {
      debugPrint('veil-video-texture: start failed: $error');
      return false;
    }
  }

  Future<void> refreshStats() async {
    final textureId = _textureId;
    if (textureId == null) return;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('stats');
      if (value == null) return;
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
    }
  }

  Future<void> stop() async {
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
