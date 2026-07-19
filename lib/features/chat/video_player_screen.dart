// In-chat video playback (media epic, v1): full-screen player over the
// loopback media server — the encrypted blob is decrypted to RAM and served
// on 127.0.0.1 with Range support, so ExoPlayer/AVPlayer can seek and
// NOTHING plaintext ever touches disk. Android/iOS/macOS use the official
// backend; Linux registers video_player_media_kit over the distro's libmpv.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../l10n/app_localizations.dart';
import '../../state/media_stream_server.dart';
import '../../state/providers.dart';

class VideoPlayerScreen extends ConsumerStatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.fileKey,
    required this.name,
  });

  /// Blob key, exactly like the image preview keys it (fileId when held,
  /// else the contentId — loadFile resolves both).
  final String fileKey;
  final String name;

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  final _server = LocalMediaServer();
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await ref.read(storageProvider).loadFile(widget.fileKey);
      if (!mounted) return;
      if (bytes == null) {
        setState(() => _error = StateError('blob missing'));
        return;
      }
      final url = await _server.serve(bytes, name: widget.name);
      final controller = VideoPlayerController.networkUrl(url);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    unawaited(_server.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
      ),
      body: _error != null
          ? Center(
              child: Text(
                l.videoPlayError,
                style: const TextStyle(color: Colors.white70),
              ),
            )
          : c == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: c.value.aspectRatio == 0
                          ? 16 / 9
                          : c.value.aspectRatio,
                      child: GestureDetector(
                        onTap: () => c.value.isPlaying ? c.pause() : c.play(),
                        child: VideoPlayer(c),
                      ),
                    ),
                  ),
                ),
                // Controls: scrubber + play/pause + position.
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        VideoProgressIndicator(
                          c,
                          allowScrubbing: true,
                          colors: VideoProgressColors(
                            playedColor: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        Row(
                          children: [
                            ValueListenableBuilder<VideoPlayerValue>(
                              valueListenable: c,
                              builder: (_, v, _) => IconButton(
                                color: Colors.white,
                                icon: Icon(
                                  v.isPlaying ? Icons.pause : Icons.play_arrow,
                                ),
                                onPressed: () =>
                                    v.isPlaying ? c.pause() : c.play(),
                              ),
                            ),
                            ValueListenableBuilder<VideoPlayerValue>(
                              valueListenable: c,
                              builder: (_, v, _) => Text(
                                '${_fmt(v.position)} / ${_fmt(v.duration)}',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
