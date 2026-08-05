import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/ids.dart';
import '../../data/serve_source.dart';
import '../../domain/content_manifest.dart';
import '../../domain/media_file_name.dart';
import '../../domain/media_object.dart' show kInlineImageMaxBytes;
import '../../domain/space_post.dart';
import '../../l10n/app_localizations.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart'
    show
        contentProgressProvider,
        contentResumingProvider,
        kMaxIncomingFileBytes,
        messagingServiceProvider;
import '../../state/providers.dart';
import '../chat/cancelable_download_progress.dart';
import '../chat/video_player_screen.dart';

typedef SpacePostMediaPickResult = ({List<MediaObject> media, int rejected});

/// Registers recorder output through the same content-addressed path as picked
/// publication files. Recorder bytes never enter the signed post or draft;
/// only this strict [MediaObject] reference does.
Future<MediaObject?> registerSpacePostRecording(
  WidgetRef ref, {
  required Uint8List bytes,
  required String name,
  required String kind,
  required String mimeType,
  required int durationMs,
}) async {
  if (bytes.isEmpty || name.isEmpty || kind.isEmpty || durationMs < 0) {
    return null;
  }
  final contentId = await ref
      .read(messagingServiceProvider)
      .registerGroupContent(bytes, name: name);
  final media = MediaObject(
    contentId: contentId,
    kind: kind,
    name: name,
    mimeType: mimeType,
    size: bytes.length,
    durationMs: durationMs,
  );
  return media.isStructurallyValid ? media : null;
}

String spacePostMediaKind(String name) {
  if (isImageFileName(name)) return 'image';
  if (isVideoFileName(name)) return 'video';
  final lower = name.toLowerCase();
  if (lower.endsWith('.mp3') ||
      lower.endsWith('.m4a') ||
      lower.endsWith('.aac') ||
      lower.endsWith('.ogg') ||
      lower.endsWith('.opus') ||
      lower.endsWith('.wav') ||
      lower.endsWith('.flac')) {
    return 'audio';
  }
  return 'file';
}

String? spacePostMediaMimeType(String name) {
  final lower = name.toLowerCase();
  const known = <String, String>{
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.png': 'image/png',
    '.gif': 'image/gif',
    '.webp': 'image/webp',
    '.bmp': 'image/bmp',
    '.mp4': 'video/mp4',
    '.m4v': 'video/x-m4v',
    '.mov': 'video/quicktime',
    '.webm': 'video/webm',
    '.mkv': 'video/x-matroska',
    '.mp3': 'audio/mpeg',
    '.m4a': 'audio/mp4',
    '.aac': 'audio/aac',
    '.ogg': 'audio/ogg',
    '.opus': 'audio/opus',
    '.wav': 'audio/wav',
    '.flac': 'audio/flac',
    '.pdf': 'application/pdf',
    '.txt': 'text/plain',
  };
  for (final entry in known.entries) {
    if (lower.endsWith(entry.key)) return entry.value;
  }
  return null;
}

/// Registers user-picked publication media in the existing content-addressed
/// group path. Small files enter the encrypted blob store; large path-backed
/// files keep a verified, restart-durable streaming source. The returned refs
/// are metadata only — bytes never enter the signed SpacePost row.
Future<SpacePostMediaPickResult> pickAndRegisterSpacePostMedia(
  WidgetRef ref, {
  required int remaining,
}) async {
  if (remaining <= 0) {
    return (media: const <MediaObject>[], rejected: 0);
  }
  final picked = await FilePicker.pickFiles(allowMultiple: true);
  if (picked == null) {
    return (media: const <MediaObject>[], rejected: 0);
  }
  final messaging = ref.read(messagingServiceProvider);
  final media = <MediaObject>[];
  var rejected = picked.files.length > remaining
      ? picked.files.length - remaining
      : 0;
  for (final file in picked.files.take(remaining)) {
    if (file.name.isEmpty || file.name.length > 255) {
      rejected++;
      continue;
    }
    var size = file.size;
    if (file.path != null) {
      try {
        size = await File(file.path!).length();
      } catch (_) {}
    }
    if (size <= 0) {
      rejected++;
      continue;
    }
    final String contentId;
    try {
      if (size <= kMaxIncomingFileBytes) {
        final bytes =
            file.bytes ??
            (file.path == null ? null : await File(file.path!).readAsBytes());
        if (bytes == null || bytes.length != size) {
          rejected++;
          continue;
        }
        contentId = await messaging.registerGroupContent(
          bytes,
          name: file.name,
        );
      } else {
        final path = file.path;
        if (path == null) {
          rejected++;
          continue;
        }
        final absolutePath = File(path).absolute.path;
        final source = await veilSourceOpener(absolutePath);
        if (source == null) {
          rejected++;
          continue;
        }
        contentId = await messaging.registerGroupContentStreaming(
          file.name,
          size,
          source.read,
          close: source.close,
          sourcePath: absolutePath,
        );
      }
    } catch (_) {
      rejected++;
      continue;
    }
    final reference = MediaObject(
      contentId: contentId,
      kind: spacePostMediaKind(file.name),
      name: file.name,
      mimeType: spacePostMediaMimeType(file.name),
      size: size,
    );
    if (!reference.isStructurallyValid) {
      rejected++;
      continue;
    }
    media.add(reference);
  }
  return (media: media, rejected: rejected);
}

class SpacePostMediaList extends StatelessWidget {
  const SpacePostMediaList({
    super.key,
    required this.spaceId,
    required this.post,
    this.compact = false,
    this.publicOnly = false,
  });

  final NodeId spaceId;
  final SpacePostView post;
  final bool compact;
  final bool publicOnly;

  @override
  Widget build(BuildContext context) {
    if (post.mediaHiddenByRetention) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            const Icon(Icons.hide_image_outlined, size: 18),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                AppL10n.of(context).spaceRetentionMediaExpired,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }
    return MediaObjectList(
      spaceId: spaceId,
      author: post.author,
      media: post.media,
      compact: compact,
      publicOnly: publicOnly,
    );
  }
}

/// Renders references from any Space-owned object through the same content
/// fetch/open/save path. Publications and comments intentionally share this
/// component so neither can accidentally grow a parallel media store.
class MediaObjectList extends StatelessWidget {
  const MediaObjectList({
    super.key,
    required this.spaceId,
    required this.author,
    required this.media,
    this.compact = false,
    this.publicOnly = false,
  });

  final NodeId spaceId;
  final NodeId author;
  final List<MediaObject> media;
  final bool compact;
  final bool publicOnly;

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in media)
            _SpacePostMediaTile(
              key: ValueKey('space-post-media-${item.contentId}'),
              spaceId: spaceId,
              author: author,
              media: item,
              compact: compact,
              publicOnly: publicOnly,
            ),
        ],
      ),
    );
  }
}

class _SpacePostMediaTile extends ConsumerStatefulWidget {
  const _SpacePostMediaTile({
    super.key,
    required this.spaceId,
    required this.author,
    required this.media,
    required this.compact,
    required this.publicOnly,
  });

  final NodeId spaceId;
  final NodeId author;
  final MediaObject media;
  final bool compact;
  final bool publicOnly;

  @override
  ConsumerState<_SpacePostMediaTile> createState() =>
      _SpacePostMediaTileState();
}

class _SpacePostMediaTileState extends ConsumerState<_SpacePostMediaTile> {
  Uint8List? _image;
  bool _loadingImage = false;
  bool _imageReadAttempted = false;
  bool _busy = false;
  String get _cid => widget.media.contentId!;

  @override
  void initState() {
    super.initState();
    if (widget.media.kind == 'image') unawaited(_loadImage());
  }

  @override
  void didUpdateWidget(covariant _SpacePostMediaTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.contentId != widget.media.contentId) {
      _image = null;
      _imageReadAttempted = false;
      if (widget.media.kind == 'image') unawaited(_loadImage());
    }
  }

  Future<void> _loadImage() async {
    if (_loadingImage || _imageReadAttempted) return;
    // The size the SENDER declared is a hint, not a bound: it was `(size ?? 0) >
    // limit`, so a post that simply omitted one read as zero and sailed through
    // to a whole-file read of any size at all. The real ceiling is enforced by
    // the store, against the size it recorded itself; this only saves the round
    // trip when the declared size already says no.
    final declared = widget.media.size;
    if (declared != null && declared > kInlineImageMaxBytes) return;
    _imageReadAttempted = true;
    _loadingImage = true;
    Uint8List? bytes;
    try {
      bytes = await ref
          .read(storageProvider)
          .loadFile(_cid, maxBytes: kInlineImageMaxBytes);
    } catch (_) {}
    _loadingImage = false;
    if (mounted && bytes != null) setState(() => _image = bytes);
  }

  Future<ContentManifest?> _manifest() async {
    try {
      final bytes = await ref.read(storageProvider).loadFile('mf:$_cid');
      if (bytes == null) return null;
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      return value is Map<String, dynamic>
          ? ContentManifest.fromJson(value)
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveHeld() async {
    final manifest = await _manifest();
    final size = widget.media.size ?? manifest?.size;
    if (size == null || size <= 0 || !mounted) return;
    final name = _safeFileName(widget.media.name ?? manifest?.name ?? 'file');
    final String? path;
    if (Platform.isAndroid || Platform.isIOS) {
      path = '${(await getApplicationDocumentsDirectory()).path}/$name';
    } else {
      path = await FilePicker.saveFile(fileName: name);
    }
    if (path == null) return;
    var written = 0;
    var ok = true;
    IOSink? output;
    try {
      output = File(path).openWrite();
      while (written < size) {
        final remaining = size - written;
        final want = remaining > 256 * 1024 ? 256 * 1024 : remaining;
        final chunk = await ref
            .read(storageProvider)
            .readFileRange(_cid, written, want);
        if (chunk == null || chunk.length != want) {
          ok = false;
          break;
        }
        output.add(chunk);
        written += chunk.length;
      }
    } catch (_) {
      ok = false;
    } finally {
      await output?.close();
    }
    if (!ok) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? AppL10n.of(context).chatFileSaved
                : AppL10n.of(context).chatFileSaveFailed,
          ),
        ),
      );
    }
  }

  Future<void> _openOrFetch(bool held) async {
    if (held) {
      if (widget.media.kind == 'video' && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                VideoPlayerScreen(fileKey: _cid, name: widget.media.name ?? ''),
          ),
        );
      } else if (widget.media.kind == 'image') {
        final bytes = _image ?? await ref.read(storageProvider).loadFile(_cid);
        if (bytes != null && mounted) {
          await showDialog<void>(
            context: context,
            builder: (_) =>
                Dialog(child: InteractiveViewer(child: Image.memory(bytes))),
          );
        } else {
          await _saveHeld();
        }
      } else {
        await _saveHeld();
      }
      return;
    }
    final messaging = ref.read(messagingServiceProvider);
    final sourcePath = await messaging.verifiedGroupContentSourcePath(_cid);
    if (sourcePath != null) {
      if (widget.media.kind == 'video' && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => VideoPlayerScreen(
              sourcePath: sourcePath,
              name: widget.media.name ?? '',
            ),
          ),
        );
      } else if (widget.media.kind == 'image' && mounted) {
        await showDialog<void>(
          context: context,
          builder: (_) => Dialog(
            child: InteractiveViewer(child: Image.file(File(sourcePath))),
          ),
        );
      } else {
        await _openSource(sourcePath);
      }
      return;
    }
    final service = ref.read(groupServiceProvider);
    final started =
        service != null &&
        (widget.publicOnly
            ? await service.requestSubscribedPublicSpaceMedia(
                widget.spaceId,
                _cid,
              )
            : await service.fetchGroupContent(
                widget.spaceId,
                _cid,
                widget.author,
              ));
    if (!started && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
      );
    }
  }

  Future<void> _openSource(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
        return;
      }
      if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
        return;
      }
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
        return;
      }
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${AppL10n.of(context).chatFileSaved}: $path')),
      );
    }
  }

  Future<void> _handleTap(bool held) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _openOrFetch(held);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppL10n.of(context).spaceOperationFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(
      contentProgressProvider.select((items) => items[_cid]),
    );
    final resuming = ref.watch(
      contentResumingProvider.select((items) => items.contains(_cid)),
    );
    final downloading = progress != null || resuming;
    if (downloading && widget.media.kind == 'image') {
      _imageReadAttempted = false;
    } else if (_image == null && widget.media.kind == 'image') {
      unawaited(_loadImage());
    }
    return FutureBuilder<bool>(
      future: ref.read(storageProvider).hasFile(_cid).catchError((_) => false),
      builder: (context, snapshot) {
        final held = snapshot.data ?? false;
        final scheme = Theme.of(context).colorScheme;
        final width = widget.compact ? 180.0 : 230.0;
        return Semantics(
          button: true,
          label: widget.media.name ?? widget.media.kind,
          child: InkWell(
            onTap: downloading
                ? () => unawaited(
                    ref
                        .read(messagingServiceProvider)
                        .cancelContentDownload(_cid),
                  )
                : _busy
                ? null
                : () => unawaited(_handleTap(held)),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: width,
              constraints: BoxConstraints(
                minHeight: widget.media.kind == 'image' ? 128 : 72,
              ),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: widget.media.kind == 'image' && _image != null
                  ? Stack(
                      fit: StackFit.passthrough,
                      children: [
                        Image.memory(
                          _image!,
                          height: 132,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, _, _) => const SizedBox(height: 72),
                        ),
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 6,
                          child: Text(
                            widget.media.name ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              shadows: [Shadow(blurRadius: 5)],
                            ),
                          ),
                        ),
                        if (_busy || downloading)
                          Positioned.fill(
                            child: ColoredBox(
                              color: Colors.black38,
                              child: Center(
                                child: downloading
                                    ? CancelableDownloadProgress(
                                        progress: progress,
                                        onCancel: () => unawaited(
                                          ref
                                              .read(messagingServiceProvider)
                                              .cancelContentDownload(_cid),
                                        ),
                                        size: 32,
                                        strokeWidth: 3,
                                      )
                                    : const CircularProgressIndicator(),
                              ),
                            ),
                          ),
                      ],
                    )
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(spacePostMediaIcon(widget.media.kind), size: 28),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.media.name ?? widget.media.kind,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  downloading
                                      ? progress == null
                                            ? AppL10n.of(context).fileResuming
                                            : '${(progress * 100).round()}%'
                                      : _formatBytes(widget.media.size),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                          if (_busy)
                            const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                              ),
                            )
                          else if (downloading)
                            CancelableDownloadProgress(
                              progress: progress,
                              onCancel: () => unawaited(
                                ref
                                    .read(messagingServiceProvider)
                                    .cancelContentDownload(_cid),
                              ),
                              size: 24,
                              strokeWidth: 2.5,
                            )
                          else
                            Icon(
                              held
                                  ? Icons.check_circle_outline
                                  : Icons.download_outlined,
                              size: 21,
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}

IconData spacePostMediaIcon(String kind) => switch (kind) {
  'image' => Icons.image_outlined,
  'video' => Icons.movie_outlined,
  'audio' => Icons.audio_file_outlined,
  'voice' => Icons.mic_none_outlined,
  'vnote' => Icons.video_camera_front_outlined,
  _ => Icons.insert_drive_file_outlined,
};

String _formatBytes(int? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

String _safeFileName(String value) {
  final sanitized = value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .trim();
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
    return 'file';
  }
  return sanitized.length <= 180 ? sanitized : sanitized.substring(0, 180);
}
