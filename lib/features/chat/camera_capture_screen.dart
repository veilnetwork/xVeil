import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../core/capture_resource_lifetime.dart';
import '../../state/owned_camera_controller.dart';

class CapturedComposerMedia {
  const CapturedComposerMedia({
    required this.path,
    required this.name,
    required this.isVideo,
  });

  final String path;
  final String name;
  final bool isVideo;
}

bool get composerCameraSupported =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// Select photo/video first, then open a real full-screen camera. The camera
/// plugin owns a temporary source file; callers read it immediately and remove
/// it after the encrypted send/register path has accepted the bytes.
Future<CapturedComposerMedia?> captureComposerMedia(
  BuildContext context,
) async {
  if (!composerCameraSupported) return null;
  final l = AppL10n.of(context);
  final video = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: Text(l.composerCamera),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(l.composerUploadPhoto),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: Text(l.composerUploadVideo),
          ),
        ),
      ],
    ),
  );
  if (video == null || !context.mounted) return null;
  return Navigator.of(context).push<CapturedComposerMedia>(
    MaterialPageRoute(builder: (_) => CameraCaptureScreen(video: video)),
  );
}

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key, required this.video});

  final bool video;

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  final _captureLifetime = CaptureResourceLifetime.current();
  final _ownedCameras = <CameraController, OwnedCameraController>{};
  final _abandonedPaths = <CameraController, String>{};
  List<CameraDescription> _cameras = const [];
  int _cameraIndex = 0;
  int _openEpoch = 0;
  Object? _error;
  bool _busy = false;
  bool _pausedForLifecycle = false;
  Timer? _autoStop;

  String _captureName(String path, String fallbackExtension) {
    final leaf = path.split('/').last;
    final dot = leaf.lastIndexOf('.');
    final extension = dot >= 0 && dot < leaf.length - 1
        ? leaf.substring(dot + 1).toLowerCase()
        : fallbackExtension;
    return 'camera-${DateTime.now().millisecondsSinceEpoch}.$extension';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open());
  }

  Future<void> _open([int? index]) async {
    final epoch = ++_openEpoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _cameras = _cameras.isEmpty ? await availableCameras() : _cameras;
      if (_cameras.isEmpty) throw StateError('no camera');
      final requested =
          index ??
          _cameras.indexWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
          );
      _cameraIndex = requested < 0 ? 0 : requested % _cameras.length;
      final old = _controller;
      _controller = null;
      await _discardController(old);
      for (final owned in _ownedCameras.keys.toList()) {
        await _discardController(owned);
      }
      if (!mounted || epoch != _openEpoch) return;
      final controller = CameraController(
        _cameras[_cameraIndex],
        ResolutionPreset.medium,
        enableAudio: widget.video,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      final owner = OwnedCameraController.tryOwn(
        controller,
        lifetime: _captureLifetime,
        automaticRetirement: false,
      );
      if (owner == null) {
        await controller.dispose();
        throw const CameraCaptureRetirementFailure();
      }
      _ownedCameras[controller] = owner;
      try {
        await controller.initialize();
      } catch (_) {
        await _discardController(controller);
        rethrow;
      }
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          epoch != _openEpoch ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
        if (epoch == _openEpoch &&
            lifecycle != null &&
            lifecycle != AppLifecycleState.resumed) {
          _pausedForLifecycle = true;
        }
        await _discardController(controller);
        return;
      }
      _pausedForLifecycle = false;
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted && epoch == _openEpoch) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && epoch == _openEpoch) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _discardController(CameraController? controller) async {
    if (controller == null) return;
    XFile? abandonedRecording;
    try {
      if (controller.value.isRecordingVideo) {
        abandonedRecording = await controller.stopVideoRecording();
      }
    } catch (_) {
      // The platform may have already revoked the camera while backgrounding.
    }
    if (abandonedRecording != null) {
      _abandonedPaths[controller] = abandonedRecording.path;
    }
    final path = _abandonedPaths[controller];
    if (path != null && path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
        _abandonedPaths.remove(controller);
      } catch (_) {
        // Retain both the pending path and the non-automatic lease. A later
        // retry can clean them; erasure cannot adopt a camera-only proof.
        return;
      }
    }
    final owner = _ownedCameras[controller];
    if (owner != null) {
      try {
        await owner.close();
        _ownedCameras.remove(controller);
      } catch (_) {
        // Keep the exact owner for a lifecycle/reopen retry.
      }
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _busy) return;
    if (widget.video && controller.value.isRecordingVideo) {
      await _finishVideo(controller);
      return;
    }
    setState(() => _busy = true);
    try {
      if (widget.video) {
        await controller.startVideoRecording();
        _autoStop = Timer(
          const Duration(seconds: 60),
          () => unawaited(_finishVideo(controller)),
        );
        if (mounted) setState(() => _busy = false);
      } else {
        final file = await controller.takePicture();
        if (!mounted || !identical(_controller, controller)) {
          try {
            await File(file.path).delete();
          } catch (_) {}
          return;
        }
        Navigator.of(context).pop(
          CapturedComposerMedia(
            path: file.path,
            name: _captureName(file.path, 'jpg'),
            isVideo: false,
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted && !(_controller?.value.isRecordingVideo ?? false)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _finishVideo(CameraController controller) async {
    if (_busy || !controller.value.isRecordingVideo) return;
    _autoStop?.cancel();
    setState(() => _busy = true);
    try {
      final file = await controller.stopVideoRecording();
      if (!mounted || !identical(_controller, controller)) {
        try {
          await File(file.path).delete();
        } catch (_) {}
        return;
      }
      Navigator.of(context).pop(
        CapturedComposerMedia(
          path: file.path,
          name: _captureName(file.path, 'mp4'),
          isVideo: true,
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 ||
        _busy ||
        (_controller?.value.isRecordingVideo ?? false)) {
      return;
    }
    await _open((_cameraIndex + 1) % _cameras.length);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_pausedForLifecycle) {
        _pausedForLifecycle = false;
        unawaited(_open(_cameraIndex));
      }
      return;
    }

    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    _pausedForLifecycle = true;
    _openEpoch++;
    _autoStop?.cancel();
    _autoStop = null;
    _controller = null;
    if (mounted) {
      setState(() => _busy = false);
    }
    unawaited(_discardController(controller));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _openEpoch++;
    _autoStop?.cancel();
    unawaited(_discardController(_controller));
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final controller = _controller;
    final recording = controller?.value.isRecordingVideo ?? false;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          widget.video ? l.composerUploadVideo : l.composerUploadPhoto,
        ),
        actions: [
          if (_cameras.length > 1)
            IconButton(
              tooltip: l.callSwitchCamera,
              onPressed: recording ? null : _switchCamera,
              icon: const Icon(Icons.cameraswitch_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: _error != null
                    ? Text(
                        l.composerCameraUnavailable,
                        style: const TextStyle(color: Colors.white),
                      )
                    : controller == null || !controller.value.isInitialized
                    ? const CircularProgressIndicator()
                    : AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: CameraPreview(controller),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: IconButton.filled(
                key: const ValueKey('composer-camera-capture'),
                onPressed: controller == null ? null : _capture,
                iconSize: 36,
                style: IconButton.styleFrom(
                  backgroundColor: recording ? Colors.red : Colors.white,
                  foregroundColor: recording ? Colors.white : Colors.black,
                ),
                icon: Icon(
                  recording
                      ? Icons.stop_rounded
                      : widget.video
                      ? Icons.videocam_rounded
                      : Icons.camera_alt_rounded,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
