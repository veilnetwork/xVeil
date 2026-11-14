import 'dart:async';
import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraPlatform;
import '../core/capture_resource_lifetime.dart';

/// Bounded error text: platform labels, ids and messages stay on device.
final class CameraCaptureRetirementFailure implements Exception {
  const CameraCaptureRetirementFailure();
  @override
  String toString() => 'CameraCaptureRetirementFailure';
}

/// CameraController.dispose marks itself disposed before awaiting the platform.
/// Repeating that wrapper after a lost/failed native close is a no-op. Retain
/// the exact backend/id and retry the platform operation, never the wrapper.
final class OwnedCameraController implements CaptureResource {
  OwnedCameraController._(
    this.controller,
    this.platform,
    this._lifetime,
    this._automatic,
    this._retireOwner,
  );
  static final _owners = Expando<OwnedCameraController>();
  final CaptureResourceLifetime _lifetime;
  final bool _automatic;
  final Future<void> Function()? _retireOwner;

  static OwnedCameraController? tryOwn(
    CameraController controller, {
    required CaptureResourceLifetime lifetime,
    bool automaticRetirement = true,
    Future<void> Function()? retireOwner,
  }) {
    final platform = CameraPlatform.instance;
    if (_owners[platform] != null) return null;
    final owner = OwnedCameraController._(
      controller,
      platform,
      lifetime,
      automaticRetirement,
      retireOwner,
    );
    if (!lifetime.admit(owner)) return null;
    _owners[platform] = owner;
    return owner;
  }

  @override
  Future<void> retire() {
    if (_released) return Future.value();
    // Attachment capture also owns pending output/files. Its widget must drain
    // those before closing this lease; a camera-only proof cannot stand in.
    if (!_automatic) {
      final retire = _retireOwner;
      if (retire != null) return retire();
      return Future.error(const CameraCaptureRetirementFailure());
    }
    return close();
  }

  final CameraController controller;
  final CameraPlatform platform;
  bool _attempted = false,
      _nativeClosed = false,
      _refresh = false,
      _released = false;
  Future<void>? _closing, _nativeClosing;

  /// Stop hardware promptly while a parent still owns accepted operations and
  /// their late output replies. Keep the backend lease until that parent drains.
  Future<void> closeWhileRetainingOwner({bool refreshAfterPending = true}) {
    _refresh = _refresh || refreshAfterPending;
    return _closeNative();
  }

  Future<void> close() {
    if (_released) return Future.value();
    final pending = _closing;
    if (pending != null) return pending;
    final result = Completer<void>();
    _closing = result.future;
    unawaited(() async {
      try {
        final earlier = _nativeClosing;
        if (earlier != null) {
          try {
            await earlier;
          } catch (_) {}
        }
        // A parent can have an outstanding native START when it requests the
        // early close. Refresh disposal after that parent's accepted work has
        // actually settled, while replacement admission is still fenced.
        if (_refresh) {
          _nativeClosed = false;
          _refresh = false;
        }
        await _closeNative();
        _released = true;
        if (identical(_owners[platform], this)) _owners[platform] = null;
        _lifetime.forget(this);
        result.complete();
      } catch (_) {
        result.completeError(const CameraCaptureRetirementFailure());
      } finally {
        _closing = null;
      }
    }());
    return result.future;
  }

  Future<void> _closeNative() {
    if (_nativeClosed) return Future.value();
    final pending = _nativeClosing;
    if (pending != null) return pending;
    final result = Completer<void>();
    _nativeClosing = result.future;
    unawaited(() async {
      try {
        if (!identical(_owners[platform], this)) {
          throw const CameraCaptureRetirementFailure();
        }
        if (!_attempted) {
          _attempted = true;
          try {
            if (controller.value.isStreamingImages) {
              await controller.stopImageStream();
            }
          } catch (_) {}
          await controller.dispose();
        } else {
          final id = controller.cameraId;
          if (id < 0) throw const CameraCaptureRetirementFailure();
          await platform.dispose(id);
        }
        _nativeClosed = true;
        result.complete();
      } catch (_) {
        result.completeError(const CameraCaptureRetirementFailure());
      } finally {
        _nativeClosing = null;
      }
    }());
    return result.future;
  }
}
