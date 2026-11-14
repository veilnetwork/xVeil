import 'dart:async';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show VideoCaptureOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show DeviceOrientation;

import '../core/capture_output_file.dart';
import '../core/capture_resource_lifetime.dart';
import 'owned_camera_controller.dart';

/// Outlives the camera widget. Owns accepted platform operations, untransferred
/// outputs and controller leases; a widget disposal is not their completion.
final class AttachmentCaptureWork implements CaptureResource {
  AttachmentCaptureWork({
    required CaptureResourceLifetime lifetime,
    this.outputStore = const FileCaptureOutputStore(),
    this.onSealed,
  }) : _lifetime = lifetime {
    _sealed = !lifetime.admit(this);
  }
  final CaptureResourceLifetime _lifetime;
  final CaptureOutputStore outputStore;
  final VoidCallback? onSealed;
  final _pending = <Future<void>>{};
  final _cameras = <CameraController, OwnedCameraController>{};
  final _busyCameras = <CameraController>{};
  final _videoMayExist = <CameraController>{};
  final _recordingStarted = <CameraController>{};
  final _videoStarts = <CameraController>{};
  final _postStartStops = <CameraController>{};
  final _videoStops = <CameraController, Future<CaptureOutputFile?>>{};
  final _earlyStops = <Future<Object?>>[];
  final _outputs = <CaptureOutputFile>{};
  final _closing = <CameraController, Future<void>>{};
  bool _sealed = false, _unknownOutput = false;
  Future<void>? _retiring;
  bool get isActive => !_sealed && _lifetime.isAdmitting;

  Future<T?> run<T>(Future<T> Function() action) {
    if (!isActive) return Future.value(null);
    final settled = Completer<void>();
    _pending.add(settled.future);
    final result = Future<T>.sync(action);
    void finish() {
      _pending.remove(settled.future);
      settled.complete();
    }

    unawaited(
      result.then<void>(
        (_) => finish(),
        onError: (Object _, StackTrace _) => finish(),
      ),
    );
    return result;
  }

  OwnedCameraController? own(CameraController controller) {
    if (!isActive) return null;
    final owner = OwnedCameraController.tryOwn(
      controller,
      lifetime: _lifetime,
      automaticRetirement: false,
      retireOwner: retire,
    );
    if (owner != null) _cameras[controller] = owner;
    return owner;
  }

  Future<CaptureOutputFile?> takePicture(CameraController controller) =>
      run<CaptureOutputFile?>(() async {
        _busyCameras.add(controller);
        try {
          final owner = _cameras[controller];
          if (owner == null) throw const CaptureResourceRetirementFailure();
          final file = await owner.platform.takePicture(controller.cameraId);
          final output = _adopt(file.path);
          return isActive ? output : null;
        } catch (_) {
          _unknownOutput = true;
          rethrow;
        } finally {
          _busyCameras.remove(controller);
        }
      });

  Future<bool?> startVideo(CameraController controller) => run(() async {
    _busyCameras.add(controller);
    _videoMayExist.add(controller);
    _videoStarts.add(controller);
    try {
      final owner = _cameras[controller];
      if (owner == null) throw const CaptureResourceRetirementFailure();
      await owner.platform.startVideoCapturing(
        VideoCaptureOptions(
          controller.cameraId,
          enablePersistentRecording: true,
        ),
      );
      if (isActive) {
        _recordingStarted.add(controller);
        controller.value = controller.value.copyWith(
          isRecordingVideo: true,
          recordingOrientation: Optional<DeviceOrientation>.of(
            controller.value.lockedCaptureOrientation ??
                controller.value.deviceOrientation,
          ),
        );
      }
      return isActive;
    } finally {
      _videoStarts.remove(controller);
      _busyCameras.remove(controller);
    }
  });

  Future<CaptureOutputFile?> finishVideo(CameraController controller) =>
      run<CaptureOutputFile?>(() async {
        _busyCameras.add(controller);
        try {
          final output = await _stopVideo(controller);
          return isActive ? output : null;
        } finally {
          _busyCameras.remove(controller);
        }
      });

  CaptureOutputFile _adopt(String path) {
    if (path.isEmpty) {
      _unknownOutput = true;
      throw const CaptureResourceRetirementFailure();
    }
    final file = CaptureOutputFile(
      path,
      lifetime: _lifetime,
      store: outputStore,
    );
    _outputs.add(file);
    return file;
  }

  bool handOff(CaptureOutputFile file) => isActive && _outputs.remove(file);

  bool isRecording(CameraController? controller) =>
      _recordingStarted.contains(controller);

  Future<CaptureOutputFile?> _stopVideo(CameraController controller) {
    if (!_videoMayExist.contains(controller) &&
        !_recordingStarted.contains(controller)) {
      return Future.value(null);
    }
    final pending = _videoStops[controller];
    if (pending != null) return pending;
    final owner = _cameras[controller];
    if (owner == null) {
      return Future.error(const CaptureResourceRetirementFailure());
    }
    final result = Completer<CaptureOutputFile?>();
    _videoStops[controller] = result.future;
    // Submit stop before submitting early disposal. The platform receives both
    // while this exact backend lease is still held. Raw platform calls retain
    // their output even if CameraController has already been disposed.
    Future<XFile>.sync(
      () => owner.platform.stopVideoRecording(controller.cameraId),
    ).then(
      (file) {
        _videoMayExist.remove(controller);
        _recordingStarted.remove(controller);
        if (isActive) {
          controller.value = controller.value.copyWith(
            isRecordingVideo: false,
            recordingOrientation: const Optional<DeviceOrientation>.absent(),
          );
        }
        _videoStops.remove(controller);
        try {
          result.complete(_adopt(file.path));
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
      onError: (Object error, StackTrace stack) {
        _videoStops.remove(controller);
        result.completeError(error, stack);
      },
    );
    return result.future;
  }

  Future<void> discardIdleController(CameraController controller) {
    if (_busyCameras.contains(controller)) {
      return Future.error(const CaptureResourceRetirementFailure());
    }
    final pending = _closing[controller];
    if (pending != null) return pending;
    final result = Completer<void>();
    _closing[controller] = result.future;
    unawaited(() async {
      var failed = false;
      try {
        await _stopVideo(controller);
      } catch (_) {
        _unknownOutput = true;
        _videoMayExist.remove(controller);
        failed = true;
      }
      // Stop the hardware even when the output reply was lost. An unknown
      // output remains a separate registered refusal; never retry a global
      // native video-stop against a replacement controller later.
      try {
        await _cameras[controller]?.close();
        _cameras.remove(controller);
      } catch (_) {
        failed = true;
      }
      _closing.remove(controller);
      if (failed) {
        result.completeError(const CaptureResourceRetirementFailure());
      } else {
        result.complete();
      }
    }());
    return result.future;
  }

  @override
  Future<void> retire() {
    final firstSeal = !_sealed;
    _sealed = true;
    final pending = _retiring;
    if (pending != null) return pending;
    final result = Completer<void>();
    _retiring = result.future;
    if (firstSeal) {
      try {
        onSealed?.call();
      } catch (_) {}
      for (final entry in _cameras.entries.toList()) {
        if (_videoStarts.contains(entry.key)) _postStartStops.add(entry.key);
        if (_videoMayExist.contains(entry.key)) {
          final stop = _stopVideo(entry.key);
          _earlyStops.add(stop);
          unawaited(
            stop.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
          );
        }
        final close = entry.value.closeWhileRetainingOwner(
          refreshAfterPending: _pending.isNotEmpty,
        );
        _earlyStops.add(close);
        unawaited(
          close.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
      }
    }
    unawaited(() async {
      var failed = false;
      try {
        await Future.wait(_pending.toList());
        for (final early in _earlyStops) {
          try {
            await early;
          } catch (_) {}
        }
        _earlyStops.clear();
        // An early STOP can finish before an accepted START. Its output is
        // owned, but it cannot prove that the later START created no new file.
        // Ask again only after both replies settled and before lease release.
        _videoMayExist.addAll(_postStartStops);
        _postStartStops.clear();
        for (final controller in _cameras.keys.toList()) {
          try {
            await discardIdleController(controller);
          } catch (_) {
            failed = true;
          }
        }
        for (final file in _outputs.toList()) {
          try {
            await file.retire();
            _outputs.remove(file);
          } catch (_) {
            failed = true;
          }
        }
        if (failed ||
            _unknownOutput ||
            _cameras.isNotEmpty ||
            _outputs.isNotEmpty) {
          throw const CaptureResourceRetirementFailure();
        }
        _lifetime.forget(this);
        result.complete();
      } catch (_) {
        result.completeError(const CaptureResourceRetirementFailure());
      } finally {
        _retiring = null;
      }
    }());
    return result.future;
  }
}
