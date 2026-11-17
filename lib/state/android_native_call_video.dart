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

class _VideoRequest {
  _VideoRequest(this.owner);

  final AndroidNativeCallVideoRenderer owner;
}

/// Control-only bridge for Android's native decoded-video texture.
class AndroidNativeCallVideoRenderer {
  AndroidNativeCallVideoRenderer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('xveil/native_call_video');

  final MethodChannel _channel;

  // MainActivity owns one remote-video surface across bridge instances.
  // Claim it before the first await; ordered commands need not have ordered
  // asynchronous completions. A retired instance must never stop its successor.
  static _VideoRequest? _activeRequest;
  _VideoRequest? _request;
  final Set<Future<void>> _drainingStops = {};

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
    final previous = _activeRequest;
    previous?.owner._retireLocal(previous);
    final request = _VideoRequest(this);
    _request = request;
    _activeRequest = request;
    final stopped = _stopPlatform(retiringOwner: previous?.owner);
    androidNativeCallVideoTexture.value = null;
    await stopped;
    if (!_owns(request)) return _finishSupersededStart();
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('start', {
        'engine': engineAddress,
      });
      // The replacement has already issued the platform stop for this source.
      // Never clean up a stale answer with a global stop of its new surface.
      if (!_owns(request)) return _finishSupersededStart();
      final textureId = (value?['textureId'] as num?)?.toInt();
      if (textureId == null || textureId < 0) {
        await stop();
        return false;
      }
      _textureId = textureId;
      _lastFrames = 0;
      _lastFrameAt = null;
      _statsTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (_polling) return; // the previous tick has not answered yet
        unawaited(refreshStats());
      });
      androidNativeCallVideoTexture.value = AndroidNativeCallVideoTexture(
        textureId: textureId,
        width: 0,
        height: 0,
        frames: 0,
        lastFrameAt: null,
      );
      // Notifier listeners run synchronously and may replace this renderer.
      if (!_owns(request)) return _finishSupersededStart();
      unawaited(refreshStats());
      return true;
    } on PlatformException catch (error) {
      if (!_owns(request)) return _finishSupersededStart();
      devLog(
        () =>
            'veil-video-texture: start failed ${error.code}: ${error.message}',
      );
      await stop();
      return false;
    } catch (error) {
      if (!_owns(request)) return _finishSupersededStart();
      devLog(() => 'veil-video-texture: start failed: $error');
      await stop();
      return false;
    }
  }

  Future<void> refreshStats() async {
    final request = _request;
    final textureId = _textureId;
    if (request == null || !_owns(request) || textureId == null) return;
    _polling = true;
    try {
      final value = await _channel.invokeMapMethod<Object?, Object?>('stats');
      if (value == null) return;
      // Everything below publishes. A stop or a restart in the await above
      // means this answer describes a texture that is gone.
      if (!_owns(request)) return;
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
      // An old poll must not reopen the timer gate of a newer request.
      if (_owns(request)) _polling = false;
    }
  }

  bool _owns(_VideoRequest request) =>
      identical(_request, request) && identical(_activeRequest, request);

  Future<bool> _finishSupersededStart() async {
    // False permits the caller to release its engine. Fence the old native
    // surface detach first, even when a successor sent that stop on our behalf.
    await Future.wait(_drainingStops.toList());
    return false;
  }

  void _retireLocal(_VideoRequest request) {
    if (!identical(_request, request)) return;
    _request = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _textureId = null;
    _lastFrames = 0;
    _lastFrameAt = null;
    _diagnostics = const {};
    _polling = false;
  }

  void _trackStop(Future<void> stopped) {
    if (!_drainingStops.add(stopped)) return;
    unawaited(
      stopped.then<void>((_) {
        _drainingStops.remove(stopped);
      }),
    );
  }

  Future<void> _stopPlatform({AndroidNativeCallVideoRenderer? retiringOwner}) {
    final stopped = () async {
      try {
        await _channel.invokeMethod<void>('stop');
      } catch (_) {
        // Idempotent teardown; MainActivity has a final cleanup as well.
      }
    }();
    _trackStop(stopped);
    retiringOwner?._trackStop(stopped);
    return stopped;
  }

  Future<void> stop() async {
    final request = _request;
    if (request != null && _owns(request)) {
      _retireLocal(request);
      _activeRequest = null;
      _stopPlatform();
      androidNativeCallVideoTexture.value = null;
    }
    await Future.wait(_drainingStops.toList());
  }
}
