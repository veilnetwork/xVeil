// In-chat video playback (media epic, v1): full-screen player over the
// loopback media server — the blob is served on 127.0.0.1 with Range support,
// so ExoPlayer/AVPlayer can seek and NOTHING plaintext ever touches disk.
// P0-5: it is decrypted RANGE BY RANGE as the player asks, not read whole
// first; opening a large video no longer costs an allocation its size, and a
// viewer who watches ten seconds decrypts ten seconds. Android/iOS/macOS use the official
// video_player backend. Linux has no such backend and ships no OS media stack
// (media_kit/libmpv rejected: LGPL + 40-80 MB); it plays through the NATIVE
// veil_media bricks instead — the WebM is demuxed in Dart, VP8 frames stream
// through the windowed VNOTE1 player and Opus audio through the voice player,
// which doubles as the clock (see NativeVideoPlayer). Same screen, same
// controls; only the playback engine forks.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/log.dart';
import '../../l10n/app_localizations.dart';
import '../../data/range_sources.dart';
import '../../domain/range_source.dart';
import '../../state/media_stream_server.dart';
import '../../state/native_video_player.dart';
import '../../state/providers.dart';
import '../../state/vnote_play_controller.dart'
    show vnoteFramePlayerFactoryProvider;
import '../../state/voice_play_controller.dart' show voicePlayerFactoryProvider;
import '../calls/video_frame_view.dart';

class VideoPlayerScreen extends ConsumerStatefulWidget {
  const VideoPlayerScreen({
    super.key,
    required this.name,
    this.fileKey,
    this.sourcePath,
  }) : assert(
         (fileKey == null) != (sourcePath == null),
         'exactly one video source is required',
       );

  /// Blob key, exactly like the image preview keys it (fileId when held,
  /// else the contentId — loadFile resolves both).
  final String? fileKey;

  /// User-selected plaintext source. It is accepted only after the content
  /// layer re-hashes the file against the signed content id.
  final String? sourcePath;
  final String name;

  /// Overrides the platform pick of the playback engine (tests exercise the
  /// native path off-Linux and the plugin path everywhere).
  @visibleForTesting
  static bool? debugUseNative;

  /// Engine pick: Linux has no plugin at all, so it is always native. On the
  /// other desktop/Apple platforms the OS engine (AVFoundation/WMF) cannot
  /// decode VP8/WebM — media_kit used to cover that and was removed — so
  /// WebM/Matroska names route to the codec-stripped native layer instead of
  /// dying with a playback error. Android keeps the plugin everywhere:
  /// ExoPlayer decodes WebM natively.
  static bool prefersNativeEngine({
    required String name,
    required bool isLinux,
    required bool isAndroid,
    bool? override,
  }) {
    if (override != null) return override;
    if (isLinux) return true;
    if (isAndroid) return false;
    final lower = name.toLowerCase();
    return lower.endsWith('.webm') || lower.endsWith('.mkv');
  }

  @override
  ConsumerState<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends ConsumerState<VideoPlayerScreen> {
  final _server = LocalMediaServer();
  VideoPlayerController? _controller;
  NativeVideoPlayer? _native;
  Object? _error;
  bool _unsupported = false;

  bool get _useNative => VideoPlayerScreen.prefersNativeEngine(
    name: widget.name,
    isLinux: Platform.isLinux,
    isAndroid: Platform.isAndroid,
    override: VideoPlayerScreen.debugUseNative,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Open the item as a range source. Never reads it whole: a stored video is
  /// pulled out of the container range by range as the player seeks.
  Future<RangeSource?> _openSource() async {
    if (widget.sourcePath != null) return fileRangeSource(widget.sourcePath!);
    return storageRangeSource(ref.read(storageProvider), widget.fileKey!);
  }

  Future<void> _load() async {
    try {
      if (_useNative) {
        await _loadNative();
        return;
      }
      final VideoPlayerController controller;
      if (widget.sourcePath != null) {
        controller = VideoPlayerController.file(File(widget.sourcePath!));
      } else {
        final source = await _openSource();
        if (!mounted) {
          await source?.dispose();
          return;
        }
        if (source == null) {
          setState(() => _error = StateError('blob missing'));
          return;
        }
        // The server takes ownership and disposes it on stop().
        final url = await _server.serve(source, name: widget.name);
        controller = VideoPlayerController.networkUrl(url);
      }
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
      await controller.play();
    } catch (e) {
      devLog(() => 'xVeil[video]: playback failed (${widget.name}): $e');
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadNative() async {
    // The native path demuxes WebM from one buffer, so unlike the HTTP path it
    // cannot stream. Bound it explicitly and refuse loudly: an unbounded read
    // here is the same availability hole the rest of this work removed, and a
    // clear message beats being killed by the OOM reaper.
    final source = await _openSource();
    if (!mounted) {
      await source?.dispose();
      return;
    }
    if (source == null) {
      setState(() => _error = StateError('blob missing'));
      return;
    }
    final Uint8List? bytes;
    try {
      bytes = await drainRangeSource(source, limit: kNativeVideoMaxBytes);
    } on RangeSourceTooLarge catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    } finally {
      await source.dispose();
    }
    if (!mounted) return;
    if (bytes == null) {
      setState(() => _error = StateError('blob missing'));
      return;
    }
    final native = await NativeVideoPlayer.open(
      bytes,
      frameFactory: ref.read(vnoteFramePlayerFactoryProvider),
      audioFactory: ref.read(voicePlayerFactoryProvider),
    );
    if (!mounted) {
      native?.dispose();
      return;
    }
    if (native == null) {
      // Honest boundary: the codec-stripped native layer plays WebM (VP8 +
      // Opus). H.264/mp4 attachments cannot decode on Linux — say so.
      setState(() => _unsupported = true);
      return;
    }
    setState(() => _native = native);
    await native.play();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _native?.dispose();
    unawaited(_server.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
      ),
      body: _body(l),
    );
  }

  Widget _body(AppL10n l) {
    if (_error != null || _unsupported) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _unsupported ? l.videoPlayUnsupported : l.videoPlayError,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    final native = _native;
    if (native != null) return _NativeVideoBody(player: native);
    final c = _controller;
    if (c == null) return const Center(child: CircularProgressIndicator());
    return Column(
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
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (_, v, _) => _ControlsRow(
                    playing: v.isPlaying,
                    position: v.position,
                    duration: v.duration,
                    onToggle: () => v.isPlaying ? c.pause() : c.play(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The Linux body: frames from the native player, transport off its state.
class _NativeVideoBody extends StatefulWidget {
  const _NativeVideoBody({required this.player});

  final NativeVideoPlayer player;

  @override
  State<_NativeVideoBody> createState() => _NativeVideoBodyState();
}

class _NativeVideoBodyState extends State<_NativeVideoBody> {
  /// Non-null while the user drags the scrubber: the slider follows the drag
  /// (not playback), and only the release seeks — a live per-pixel seek would
  /// thrash the native frame windows.
  double? _dragFraction;

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    return AnimatedBuilder(
      animation: p,
      builder: (context, _) {
        final duration = Duration(milliseconds: p.durationMs);
        final position = _dragFraction != null
            ? Duration(milliseconds: (p.durationMs * _dragFraction!).round())
            : Duration(milliseconds: p.positionMs);
        final fraction = _dragFraction != null
            ? _dragFraction!
            : (p.durationMs > 0
                  ? (p.positionMs / p.durationMs).clamp(0.0, 1.0)
                  : 0.0);
        return Column(
          children: [
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: p.aspectRatio == 0 ? 16 / 9 : p.aspectRatio,
                  child: GestureDetector(
                    key: const ValueKey('native-video-surface'),
                    onTap: p.togglePlay,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CallVideoFrameView(
                          frameListenable: p.frame,
                          freshnessToken: 'attachment-video',
                          waitingLabel: '',
                          placeholderIcon: p.hasVideo
                              ? Icons.movie_outlined
                              : Icons.music_note_outlined,
                        ),
                        if (p.ended)
                          const ColoredBox(
                            color: Colors.black38,
                            child: Center(
                              child: Icon(
                                Icons.replay,
                                color: Colors.white,
                                size: 56,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                      ),
                      child: Slider(
                        value: fraction,
                        onChanged: (v) => setState(() => _dragFraction = v),
                        onChangeEnd: (v) {
                          setState(() => _dragFraction = null);
                          unawaited(p.seekFraction(v));
                        },
                        activeColor: Theme.of(context).colorScheme.primary,
                        inactiveColor: Colors.white24,
                      ),
                    ),
                    _ControlsRow(
                      playing: p.isPlaying,
                      position: position,
                      duration: duration,
                      onToggle: () => unawaited(p.togglePlay()),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Play/pause + position readout, shared by both playback engines.
class _ControlsRow extends StatelessWidget {
  const _ControlsRow({
    required this.playing,
    required this.position,
    required this.duration,
    required this.onToggle,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          color: Colors.white,
          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          onPressed: onToggle,
        ),
        Text(
          '${_fmt(position)} / ${_fmt(duration)}',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ],
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
