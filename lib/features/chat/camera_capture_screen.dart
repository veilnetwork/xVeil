import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../core/capture_resource_lifetime.dart';
import '../../state/owned_camera_controller.dart';
import '../../state/attachment_capture_work.dart';
import '../../core/capture_output_file.dart';

class CapturedComposerMedia {
  CapturedComposerMedia._(
    this._output, {
    required this.name,
    required this.isVideo,
  });
  final CaptureOutputFile _output;
  final String name;
  final bool isVideo;
  Future<void> use(Future<void> Function(String path) consume) async {
    if (!_output.canUse) {
      try {
        await _output.retire();
      } catch (_) {}
      return;
    }
    await _output.use(consume);
  }

  Future<void> discard() => _output.retire();
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
  final lifetime = CaptureResourceLifetime.current();
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
  if (video == null || !context.mounted || !lifetime.isAdmitting) return null;
  return Navigator.of(context).push<CapturedComposerMedia>(
    MaterialPageRoute(
      builder: (_) =>
          CameraCaptureScreen(video: video, captureLifetime: lifetime),
    ),
  );
}

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({
    super.key,
    required this.video,
    this.captureLifetime,
    this.outputStore,
  });

  final bool video;
  final CaptureResourceLifetime? captureLifetime;
  @visibleForTesting
  final CaptureOutputStore? outputStore;

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  late final CaptureResourceLifetime _captureLifetime;
  late AttachmentCaptureWork _work;
  bool _disposing = false;
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
    _captureLifetime =
        widget.captureLifetime ?? CaptureResourceLifetime.current();
    _work = _newWork();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_open());
  }

  AttachmentCaptureWork _newWork() {
    late final AttachmentCaptureWork work;
    work = AttachmentCaptureWork(
      lifetime: _captureLifetime,
      // ignore: invalid_use_of_visible_for_testing_member
      outputStore: widget.outputStore ?? const FileCaptureOutputStore(),
      onSealed: () {
        if (!identical(_work, work)) return;
        _openEpoch++;
        _autoStop?.cancel();
        _autoStop = null;
        _controller = null;
        if (mounted && !_disposing) setState(() => _busy = false);
      },
    );
    return work;
  }

  Future<void> _open([int? index]) async {
    final work = _work;
    await work.run(() => _openAccepted(work, index));
  }

  Future<void> _openAccepted(AttachmentCaptureWork work, int? index) async {
    final epoch = ++_openEpoch;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _cameras = _cameras.isEmpty ? await availableCameras() : _cameras;
      if (!mounted || epoch != _openEpoch || !work.isActive) return;
      if (_cameras.isEmpty) throw StateError('no camera');
      final requested =
          index ??
          _cameras.indexWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
          );
      _cameraIndex = requested < 0 ? 0 : requested % _cameras.length;
      final old = _controller;
      _controller = null;
      if (old != null) await work.discardIdleController(old);
      if (!mounted || epoch != _openEpoch || !work.isActive) return;
      final controller = CameraController(
        _cameras[_cameraIndex],
        ResolutionPreset.medium,
        enableAudio: widget.video,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      final owner = work.own(controller);
      if (owner == null) {
        await controller.dispose();
        throw const CameraCaptureRetirementFailure();
      }
      try {
        await controller.initialize();
      } catch (_) {
        await work.discardIdleController(controller);
        rethrow;
      }
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (!mounted ||
          epoch != _openEpoch ||
          !work.isActive ||
          (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
        if (epoch == _openEpoch &&
            lifecycle != null &&
            lifecycle != AppLifecycleState.resumed) {
          _pausedForLifecycle = true;
        }
        await work.discardIdleController(controller);
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

  Future<void> _capture() async {
    final controller = _controller;
    final work = _work;
    if (controller == null || _busy || !work.isActive) return;
    if (widget.video && work.isRecording(controller)) {
      await _finishVideo(controller);
      return;
    }
    await work.run(() async {
      setState(() => _busy = true);
      try {
        if (widget.video) {
          await work.startVideo(controller);
          if (!work.isActive ||
              !mounted ||
              !identical(_controller, controller)) {
            return;
          }
          _autoStop = Timer(
            const Duration(seconds: 60),
            () => unawaited(_finishVideo(controller)),
          );
          setState(() => _busy = false);
        } else {
          final output = await work.takePicture(controller);
          if (output == null) return;
          if (!mounted ||
              !identical(_controller, controller) ||
              !work.handOff(output)) {
            return;
          }
          Navigator.of(context).pop(
            CapturedComposerMedia._(
              output,
              name: _captureName(output.path, 'jpg'),
              isVideo: false,
            ),
          );
        }
      } catch (error) {
        if (mounted && work.isActive) setState(() => _error = error);
      } finally {
        if (mounted && work.isActive && !work.isRecording(_controller)) {
          setState(() => _busy = false);
        }
      }
    });
  }

  Future<void> _finishVideo(CameraController controller) async {
    final work = _work;
    if (_busy || !work.isRecording(controller) || !work.isActive) return;
    _autoStop?.cancel();
    await work.run(() async {
      setState(() => _busy = true);
      try {
        final output = await work.finishVideo(controller);
        if (output == null) return;
        if (!mounted ||
            !identical(_controller, controller) ||
            !work.handOff(output)) {
          return;
        }
        Navigator.of(context).pop(
          CapturedComposerMedia._(
            output,
            name: _captureName(output.path, 'mp4'),
            isVideo: true,
          ),
        );
      } catch (error) {
        if (mounted && work.isActive) setState(() => _error = error);
      } finally {
        if (mounted && work.isActive) setState(() => _busy = false);
      }
    });
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2 || _busy || _work.isRecording(_controller)) {
      return;
    }
    await _open((_cameraIndex + 1) % _cameras.length);
  }

  Future<void> _resumeCamera() async {
    final previous = _work;
    try {
      await previous.retire();
    } catch (_) {}
    if (!mounted ||
        !_captureLifetime.isAdmitting ||
        !identical(_work, previous)) {
      return;
    }
    _work = _newWork();
    await _open(_cameraIndex);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_pausedForLifecycle) {
        _pausedForLifecycle = false;
        unawaited(_resumeCamera());
      }
      return;
    }
    _pausedForLifecycle = true;
    unawaited(_work.retire().catchError((Object _) {}));
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _openEpoch++;
    _autoStop?.cancel();
    _controller = null;
    unawaited(_work.retire().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final controller = _controller;
    final recording = _work.isRecording(controller);
    final workIsActive = _work.isActive;
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
                child: _error != null || !_work.isActive
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
                onPressed: controller == null || !workIsActive
                    ? null
                    : _capture,
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
