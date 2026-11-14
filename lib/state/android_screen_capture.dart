import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/log.dart';
import '../core/capture_resource_lifetime.dart';
import 'android_camera_capture.dart' show I420FrameSink;

/// Injectable boundary around Android's user-consented MediaProjection source.
abstract interface class AndroidScreenCaptureSource {
  Future<bool> start(I420FrameSink sink);

  /// Detach a retiring engine or attach its replacement without obtaining a
  /// second MediaProjection token. A stopped source cannot be resumed here.
  bool rebindFrameSink(I420FrameSink? sink);
  Future<void> stop();
}

typedef AndroidScreenCaptureFactory =
    AndroidScreenCaptureSource Function(VoidCallback onUnexpectedStop);

AndroidScreenCaptureSource createAndroidScreenCapture(
  VoidCallback onUnexpectedStop, {
  CaptureResourceLifetime? captureLifetime,
}) => AndroidScreenCapture(onUnexpectedStop, captureLifetime: captureLifetime);

/// Android screen SEND path. The platform foreground service owns the
/// MediaProjection token and emits small, tightly packed I420 frames over this
/// control channel. Frames and the consent token stay in RAM; no recorder or
/// temporary file is involved.
class AndroidScreenCapture
    implements AndroidScreenCaptureSource, CaptureResource {
  AndroidScreenCapture(
    this._onUnexpectedStop, {
    MethodChannel? channel,
    bool? isAndroid,
    CaptureResourceLifetime? captureLifetime,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _isAndroid = isAndroid ?? Platform.isAndroid,
       _captureLifetime = captureLifetime ?? CaptureResourceLifetime.current() {
    _retired = !_captureLifetime.admit(this);
  }

  static const _channelName = 'xveil/screen_capture';

  final VoidCallback _onUnexpectedStop;
  final MethodChannel _channel;
  final bool _isAndroid;
  final CaptureResourceLifetime _captureLifetime;
  static final _owners = Expando<Map<String, AndroidScreenCapture>>();
  static final _random = Random.secure();
  Map<String, AndroidScreenCapture> get _channels =>
      _owners[_channel.binaryMessenger] ??= {};
  bool get _ownsChannel => identical(_channels[_channel.name], this);

  I420FrameSink? _sink;
  String? _session;
  bool _running = false;
  bool _retired = false;
  Future<bool>? _starting;
  Future<void>? _stopping;
  bool _firstFrameLogged = false;
  bool _firstDeliveryLogged = false;

  @override
  Future<bool> start(I420FrameSink sink) {
    if (!_isAndroid || _retired || _running) return Future.value(false);
    // A denied/busy attempt can have released its resource registration. A
    // retry must re-enter the original profile, never whichever profile is now
    // current. The lifetime is sealed before profile erasure starts awaiting.
    if (!_captureLifetime.admit(this)) return Future.value(false);
    final pending = _starting;
    if (pending != null) return pending;
    // Reserve before entering an adapter, which may synchronously call stop.
    final result = Completer<bool>();
    _starting = result.future;
    _start(sink).then(
      (value) {
        _starting = null;
        _forgetIfReleased();
        result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        _starting = null;
        _forgetIfReleased();
        result.completeError(error, stack);
      },
    );
    return result.future;
  }

  Future<bool> _start(I420FrameSink sink) async {
    final previous = _channels[_channel.name];
    if (previous != null && !identical(previous, this)) {
      final closing = previous._stopping;
      if (closing == null) return false;
      try {
        await closing;
      } catch (_) {
        return false;
      }
    }
    if (_retired || _channels[_channel.name] != null) return false;
    _channels[_channel.name] = this;
    _session = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _sink = sink;
    _channel.setMethodCallHandler(_handlePlatformCall);
    try {
      final started =
          await _channel.invokeMethod<bool>('start', {'session': _session}) ??
          false;
      if (_retired || !_captureLifetime.isAdmitting || !_ownsChannel) {
        return false;
      }
      if (!started) {
        _sink = null;
        _releaseChannel();
        return false;
      }
      _running = true;
      return true;
    } catch (_) {
      _sink = null;
      // A lost reply does not prove that the service did not start. Retain
      // ownership if the explicit native cleanup cannot be acknowledged.
      if (!_retired && _ownsChannel) {
        _retired = true;
        try {
          await _channel.invokeMethod<void>('stop', {'session': _session});
          _releaseChannel();
        } catch (_) {}
      }
      return false;
    }
  }

  void _releaseChannel() {
    if (!_ownsChannel) return;
    _channel.setMethodCallHandler(null);
    _channels.remove(_channel.name);
    _forgetIfReleased();
  }

  void _forgetIfReleased() {
    if (!_ownsChannel && _starting == null && _stopping == null) {
      _captureLifetime.forget(this);
    }
  }

  @override
  Future<void> retire() => stop();

  Future<void> _handlePlatformCall(MethodCall call) async {
    final arguments = call.arguments;
    if (!_ownsChannel ||
        arguments is! Map ||
        arguments['session'] != _session) {
      return;
    }
    switch (call.method) {
      case 'frame':
        final bytes = arguments['frame'];
        if (!_firstDeliveryLogged) {
          _firstDeliveryLogged = true;
          devLog(() => 'veil-screen: first platform delivery');
        }
        if (bytes is! Uint8List) return;
        final frame = decodeAndroidScreenFrame(bytes);
        final sink = _sink;
        if (frame == null ||
            sink == null ||
            _retired ||
            !_captureLifetime.isAdmitting) {
          return;
        }
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
        final expected = _retired;
        _retired = true;
        _running = false;
        _sink = null;
        if (_stopping == null) _releaseChannel();
        if (!expected) _onUnexpectedStop();
        return;
    }
  }

  @override
  bool rebindFrameSink(I420FrameSink? sink) {
    if (sink == null) {
      _sink = null;
      return true;
    }
    if (!_running ||
        _retired ||
        !_captureLifetime.isAdmitting ||
        !_ownsChannel) {
      return false;
    }
    _sink = sink;
    return true;
  }

  @override
  Future<void> stop() {
    _retired = true;
    _running = false;
    _sink = null;
    final pending = _stopping;
    if (pending != null) return pending;
    final starting = _starting;
    final result = Completer<void>();
    _stopping = result.future;
    _stop(starting).then(
      (_) {
        _stopping = null;
        _forgetIfReleased();
        result.complete();
      },
      onError: (Object error, StackTrace stack) {
        _stopping = null;
        result.completeError(error, stack);
      },
    );
    return result.future;
  }

  Future<void> _stop(Future<bool>? starting) async {
    try {
      // Cancel consent immediately, before joining its reply. Waiting first
      // would deadlock on the system permission dialog.
      if (_isAndroid && _ownsChannel) {
        await _channel.invokeMethod<void>('stop', {'session': _session});
      }
    } finally {
      await starting;
    }
    _releaseChannel();
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
