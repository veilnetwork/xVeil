import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';
import 'android_camera_capture.dart' show I420FrameSink;

/// Injectable boundary around Android's user-consented MediaProjection source.
abstract interface class AndroidScreenCaptureSource {
  Future<bool> start(I420FrameSink sink);
  Future<void> stop();
}

typedef AndroidScreenCaptureFactory =
    AndroidScreenCaptureSource Function(VoidCallback onUnexpectedStop);

AndroidScreenCaptureSource createAndroidScreenCapture(
  VoidCallback onUnexpectedStop,
) => AndroidScreenCapture(onUnexpectedStop);

/// Android screen SEND path. The platform foreground service owns the
/// MediaProjection token and emits small, tightly packed I420 frames over this
/// control channel. Frames and the consent token stay in RAM; no recorder or
/// temporary file is involved.
class AndroidScreenCapture implements AndroidScreenCaptureSource {
  AndroidScreenCapture(
    this._onUnexpectedStop, {
    MethodChannel? channel,
    bool? isAndroid,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _isAndroid = isAndroid ?? Platform.isAndroid;

  static const _channelName = 'xveil/screen_capture';

  final VoidCallback _onUnexpectedStop;
  final MethodChannel _channel;
  final bool _isAndroid;
  I420FrameSink? _sink;
  bool _running = false;
  bool _stopping = false;
  bool _firstFrameLogged = false;

  @override
  Future<bool> start(I420FrameSink sink) async {
    if (!_isAndroid || _running) return false;
    _sink = sink;
    _channel.setMethodCallHandler(_handlePlatformCall);
    try {
      final started = await _channel.invokeMethod<bool>('start') ?? false;
      if (!started) {
        _sink = null;
        _channel.setMethodCallHandler(null);
        return false;
      }
      _running = true;
      return true;
    } catch (_) {
      _sink = null;
      _channel.setMethodCallHandler(null);
      return false;
    }
  }

  Future<void> _handlePlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'frame':
        final bytes = call.arguments;
        if (bytes is! Uint8List) return;
        final frame = decodeAndroidScreenFrame(bytes);
        final sink = _sink;
        if (frame == null || sink == null || _stopping) return;
        if (!_firstFrameLogged) {
          _firstFrameLogged = true;
          devLog(
            () =>
                'veil-screen: first I420 frame '
                '${frame.width}x${frame.height}',
          );
        }
        sink(frame.y, frame.u, frame.v, frame.width, frame.height);
        return;
      case 'stopped':
        final expected = _stopping;
        _running = false;
        _sink = null;
        _channel.setMethodCallHandler(null);
        if (!expected) _onUnexpectedStop();
        return;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isAndroid) return;
    _stopping = true;
    _running = false;
    _sink = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // The app/process may already be tearing down. Local capture ownership is
      // cleared regardless; Android also destroys the projection with process.
    } finally {
      _channel.setMethodCallHandler(null);
      _stopping = false;
    }
  }
}

@visibleForTesting
final class AndroidScreenFrame {
  const AndroidScreenFrame({
    required this.y,
    required this.u,
    required this.v,
    required this.width,
    required this.height,
  });

  final Uint8List y;
  final Uint8List u;
  final Uint8List v;
  final int width;
  final int height;
}

/// Wire format: big-endian u32 width, u32 height, then tightly packed I420.
/// Bounds are deliberately strict before any sublist view is created because
/// this crosses a platform boundary and is fed straight to a native encoder.
@visibleForTesting
AndroidScreenFrame? decodeAndroidScreenFrame(Uint8List bytes) {
  if (bytes.length < 8) return null;
  final header = ByteData.sublistView(bytes, 0, 8);
  final width = header.getUint32(0);
  final height = header.getUint32(4);
  if (width < 2 || height < 2 || width > 1920 || height > 1920) return null;
  final yLength = width * height;
  final chromaLength = ((width + 1) >> 1) * ((height + 1) >> 1);
  final expected = 8 + yLength + chromaLength * 2;
  if (bytes.length != expected) return null;
  final yEnd = 8 + yLength;
  final uEnd = yEnd + chromaLength;
  return AndroidScreenFrame(
    y: Uint8List.sublistView(bytes, 8, yEnd),
    u: Uint8List.sublistView(bytes, yEnd, uEnd),
    v: Uint8List.sublistView(bytes, uEnd, expected),
    width: width,
    height: height,
  );
}
