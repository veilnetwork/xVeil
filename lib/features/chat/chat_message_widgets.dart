part of 'chat_screen.dart';

// isImageFileName moved to state/thumbnail.dart (shared with the send path's
// thumb generation) and re-exported via the import above.

/// Type-specific icon for a document file row (media epic: "документы —
/// иконка типа"). Pure extension→icon mapping, unit-tested; anything
/// unrecognized keeps the generic file icon.
IconData documentIcon(String? name) {
  final ext = FileDownloadPolicy.extensionOf(name);
  return switch (ext) {
    'pdf' => Icons.picture_as_pdf_outlined,
    'zip' ||
    'rar' ||
    '7z' ||
    'tar' ||
    'gz' ||
    'xz' ||
    'bz2' => Icons.folder_zip_outlined,
    'mp3' ||
    'wav' ||
    'ogg' ||
    'opus' ||
    'm4a' ||
    'flac' ||
    'aac' => Icons.audiotrack_outlined,
    'mp4' || 'mov' || 'mkv' || 'webm' || 'avi' => Icons.movie_outlined,
    'doc' || 'docx' || 'odt' || 'rtf' => Icons.description_outlined,
    'xls' || 'xlsx' || 'ods' || 'csv' => Icons.table_chart_outlined,
    'ppt' || 'pptx' || 'odp' => Icons.slideshow_outlined,
    'txt' || 'md' || 'log' => Icons.article_outlined,
    'apk' => Icons.android_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

/// Inline preview for a downloaded image file: a rounded, bounded thumbnail
/// that opens a full-screen zoomable viewer on tap. Bytes come from the
/// encrypted container (loadFile), so nothing hits disk in the clear.
/// Decode a message's embedded micro-thumb ('tb'), or null when absent or
/// corrupt (a hostile field must fall back to the plain row, never throw).
Uint8List? _decodeThumbB64(String? tb) {
  if (tb == null) return null;
  try {
    return base64Decode(tb);
  } catch (_) {
    return null;
  }
}

/// A shared sticker pack: an install card (first-sticker thumb + name/count +
/// an Install button once the blob is held; a download affordance before).
/// Installing decodes the STKP blob into a new local pack. A held blob also
/// shows its provenance — signed-by-author (v2) or an honest "unsigned"
/// (legacy v1) — and a signed pack whose signature does NOT verify refuses
/// to install with a visible error instead of silently landing.
class _StickerPackCard extends ConsumerStatefulWidget {
  const _StickerPackCard({
    required this.fileKey,
    required this.thumbB64,
    required this.downloaded,
    this.progress,
    this.onDownload,
  });

  final String fileKey;
  final String? thumbB64;
  final bool downloaded;
  final double? progress;
  final VoidCallback? onDownload;

  @override
  ConsumerState<_StickerPackCard> createState() => _StickerPackCardState();
}

class _StickerPackCardState extends ConsumerState<_StickerPackCard> {
  bool _installing = false;
  int? _installed;
  bool _badSignature = false;
  Future<StickerPackBundle?>? _bundle;

  Future<void> _install() async {
    setState(() {
      _installing = true;
      _badSignature = false;
    });
    try {
      final bytes = await ref.read(storageProvider).loadFile(widget.fileKey);
      if (bytes == null) return;
      final n = await ref
          .read(stickerControllerProvider.notifier)
          .installPack(bytes);
      if (mounted) setState(() => _installed = n);
    } on StickerPackBadSignature {
      if (mounted) setState(() => _badSignature = true);
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  /// Provenance line under the title once the blob is held: who signed the
  /// pack, or an explicit "unsigned" for a legacy v1 container.
  Widget _provenance(AppL10n l, ColorScheme scheme) {
    _bundle ??= ref
        .read(storageProvider)
        .loadFile(widget.fileKey)
        .then((b) => b == null ? null : decodeStickerPack(b));
    return FutureBuilder<StickerPackBundle?>(
      future: _bundle,
      builder: (context, snap) {
        final bundle = snap.data;
        if (bundle == null) return const SizedBox.shrink();
        final style = Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
        return Text(
          bundle.isSigned
              ? l.stickerPackSignedBy(
                  NodeId(Uint8List.fromList(bundle.authorId!)).short,
                )
              : l.stickerPackUnsigned,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final thumb = _decodeThumbB64(widget.thumbB64);
    return SizedBox(
      width: 220,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: thumb != null
                ? Image.memory(
                    thumb,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  )
                : Icon(
                    Icons.sticky_note_2_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.stickerPackTitle,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                if (widget.downloaded) _provenance(l, scheme),
                const SizedBox(height: 4),
                if (_badSignature)
                  Text(
                    l.stickerPackBadSignature,
                    style: Theme.of(
                      context,
                    ).textTheme.labelSmall?.copyWith(color: scheme.error),
                  )
                else if (_installed != null)
                  Text(
                    l.stickerImported(_installed!),
                    style: Theme.of(context).textTheme.labelSmall,
                  )
                else if (_installing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (!widget.downloaded)
                  (widget.progress != null
                      ? CancelableDownloadProgress(
                          progress: widget.progress,
                          onCancel: widget.onDownload!,
                          size: 24,
                          strokeWidth: 2,
                        )
                      : TextButton(
                          onPressed: widget.onDownload,
                          child: Text(l.stickerPackDownload),
                        ))
                else
                  FilledButton.tonal(
                    onPressed: _install,
                    child: Text(l.stickerPackInstall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A sticker: the image itself, naked (the bubble adds no chrome for sticker
/// messages). Until the blob lands, the blurred sidecar micro-thumb (or a
/// progress ring) stands in — stickers are small and auto-download, so this
/// is a blink. Animated WebP animates for free via Image.memory.
class _StickerContent extends ConsumerStatefulWidget {
  const _StickerContent({
    required this.fileKey,
    required this.thumbB64,
    this.progress,
    this.onCancel,
    this.onDownload,
  });

  final String fileKey;
  final String? thumbB64;
  final double? progress;
  final VoidCallback? onCancel;
  final VoidCallback? onDownload;

  static const double _side = 160;

  @override
  ConsumerState<_StickerContent> createState() => _StickerContentState();
}

class _StickerContentState extends ConsumerState<_StickerContent> {
  Uint8List? _bytes;
  bool _loadInFlight = false;
  DateTime? _lastAttemptAt;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loadInFlight || widget.fileKey.isEmpty) return;
    final fileKey = widget.fileKey;
    _loadInFlight = true;
    _lastAttemptAt = DateTime.now();
    Uint8List? bytes;
    try {
      bytes = await ref
          .read(storageProvider)
          .loadFile(fileKey, maxBytes: kInlineImageMaxBytes);
    } catch (_) {
      // A transient storage failure keeps the micro-thumb/download affordance;
      // the next provider rebuild can retry after the throttle below.
    } finally {
      _loadInFlight = false;
    }
    if (!mounted) return;
    // A content offer can switch from contentId to a local fileId while an
    // earlier read is still in flight. Never paint the old key's bytes into
    // the updated message; immediately start the read didUpdateWidget could
    // not start while single-flight was occupied.
    if (widget.fileKey != fileKey) {
      unawaited(_load());
      return;
    }
    if (bytes == null) return;
    setState(() => _bytes = bytes);
  }

  @override
  void didUpdateWidget(covariant _StickerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileKey != widget.fileKey) {
      _bytes = null;
      _lastAttemptAt = null;
      unawaited(_load());
      return;
    }
    if (_bytes != null || widget.fileKey.isEmpty) return;
    final downloadEnded = oldWidget.progress != null && widget.progress == null;
    final last = _lastAttemptAt;
    final throttleElapsed =
        last == null ||
        DateTime.now().difference(last) > const Duration(seconds: 2);
    if (downloadEnded || throttleElapsed) unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final thumb = _decodeThumbB64(widget.thumbB64);
    return SizedBox(
      width: _StickerContent._side,
      height: _StickerContent._side,
      child: widget.fileKey.isEmpty
          ? _placeholder(context, thumb)
          : _bytes == null
          ? _placeholder(context, thumb)
          : Image.memory(
              _bytes!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              cacheWidth: mediaPreviewCacheDimension(
                _StickerContent._side,
                MediaQuery.devicePixelRatioOf(context),
              ),
              cacheHeight: mediaPreviewCacheDimension(
                _StickerContent._side,
                MediaQuery.devicePixelRatioOf(context),
              ),
              errorBuilder: (_, _, _) => _placeholder(context, thumb),
            ),
    );
  }

  Widget _placeholder(BuildContext context, Uint8List? thumb) {
    return Stack(
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        if (thumb != null)
          ImageFiltered(
            imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
            child: Image.memory(
              thumb,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          )
        else
          ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
          ),
        if (widget.progress != null && widget.onCancel != null)
          Center(
            child: CancelableDownloadProgress(
              progress: widget.progress,
              onCancel: widget.onCancel!,
              size: 32,
              strokeWidth: 3,
            ),
          )
        else if (widget.onDownload != null)
          Center(
            child: IconButton.filledTonal(
              // An unnamed icon on top of a blurred thumbnail: nothing said
              // whether it downloads, opens, or dismisses.
              tooltip: AppL10n.of(context).fileDownloadTitle,
              onPressed: widget.onDownload,
              icon: const Icon(Icons.download),
            ),
          ),
      ],
    );
  }
}

/// Round video note. Before download: the first-frame micro-thumb from the
/// `vn1:` sidecar in a circle + a download affordance. Downloaded: tap plays
/// INLINE — live frames fill the circle (pulled at the audio position), a
/// progress ring runs around it, tap again pauses. Duration below turns into
/// a live clock while active.
class _VnoteBubble extends ConsumerWidget {
  const _VnoteBubble({
    required this.messageId,
    required this.fileKey,
    required this.sidecar,
    required this.outgoing,
    required this.downloaded,
    this.progress,
    this.onDownload,
  });

  final String messageId;
  final String fileKey;
  final VnoteSidecar? sidecar;
  final bool outgoing;
  final bool downloaded;
  final double? progress;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final onBubble = outgoing ? scheme.onPrimary : scheme.onSurface;
    final thumb = _decodeThumbB64(sidecar?.thumbB64);
    final play = ref.watch(vnotePlayControllerProvider);
    final active = downloaded && play.isActive(messageId);
    final playing = downloaded && play.isPlaying(messageId);

    void onTap() {
      if (!downloaded) {
        onDownload?.call();
        return;
      }
      ref.read(vnotePlayControllerProvider.notifier).toggle(messageId, fileKey);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 184,
            height: 184,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: const EdgeInsets.all(2),
                  child: ClipOval(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (active)
                          VnotePreview(
                            frameListenable: ref
                                .read(vnotePlayControllerProvider.notifier)
                                .frame,
                          )
                        else if (thumb != null)
                          Image.memory(
                            thumb,
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.low,
                            // The chat list rebuilds often, and every rebuild
                            // makes a fresh provider for these bytes: without
                            // this the poster BLANKS while it decodes again,
                            // which reads as a circle strobing on its own —
                            // reported as "flickering like filming one screen
                            // with another", and only while at rest, because a
                            // playing note paints a decoded frame it holds.
                            gaplessPlayback: true,
                          )
                        else
                          ColoredBox(color: scheme.surfaceContainerHighest),
                        // Dim + center affordance only when NOT playing (the
                        // playing circle is clean video, Telegram-style).
                        if (!playing) ...[
                          ColoredBox(
                            color: Colors.black.withValues(alpha: 0.18),
                          ),
                          Center(
                            child: progress != null
                                ? CancelableDownloadProgress(
                                    progress: progress,
                                    onCancel: onDownload!,
                                    size: 36,
                                    strokeWidth: 3,
                                    color: Colors.white,
                                  )
                                : Icon(
                                    downloaded
                                        ? Icons.play_arrow
                                        : Icons.download,
                                    color: Colors.white,
                                    size: 44,
                                  ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                // Playback progress ring around the circle.
                if (active)
                  CircularProgressIndicator(
                    value: play.progress,
                    strokeWidth: 2.5,
                    color: scheme.primary,
                    backgroundColor: onBubble.withValues(alpha: 0.15),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          active
              ? formatVoiceDuration(Duration(milliseconds: play.positionMs))
              : formatVoiceDuration(sidecar?.duration),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: onBubble.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

/// Voice message: a play/download control + the clip waveform + duration,
/// rendered from the `vw1:` sidecar that travelled in the message (no decode
/// needed to show it). Play is enabled only once the small Opus blob is held
/// (it auto-downloads under the cap); while fetching it shows a progress ring,
/// otherwise a download affordance.
class _VoiceBubble extends ConsumerWidget {
  const _VoiceBubble({
    required this.messageId,
    required this.fileKey,
    required this.sidecar,
    required this.outgoing,
    required this.downloaded,
    this.progress,
    this.onDownload,
  });

  final String messageId;
  final String fileKey;
  final VoiceSidecar? sidecar;
  final bool outgoing;
  final bool downloaded;
  final double? progress;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final onBubble = outgoing ? scheme.onPrimary : scheme.onSurface;
    final bars = sidecar?.bars ?? const <double>[];
    final play = ref.watch(voicePlayControllerProvider);
    final active = downloaded && play.isActive(messageId);
    final playing = downloaded && play.isPlaying(messageId);
    // Show the playback clock when active, else the total clip length.
    final label = active
        ? formatVoiceDuration(Duration(milliseconds: play.positionMs))
        : formatVoiceDuration(sidecar?.duration);

    void onLead() {
      if (!downloaded) {
        onDownload?.call();
        return;
      }
      ref.read(voicePlayControllerProvider.notifier).toggle(messageId, fileKey);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 232,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: onLead,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: progress != null
                      ? CancelableDownloadProgress(
                          progress: progress,
                          onCancel: onDownload!,
                          size: 32,
                          strokeWidth: 2,
                          color: onBubble,
                        )
                      : Icon(
                          !downloaded
                              ? Icons.download
                              : (playing ? Icons.pause : Icons.play_arrow),
                          color: onBubble,
                          size: 32,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: bars.isEmpty
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Icon(
                            Icons.graphic_eq,
                            size: 20,
                            color: onBubble.withValues(alpha: 0.5),
                          ),
                        )
                      // Touch anywhere on the waveform to hear that moment —
                      // tap to jump, drag to scrub. Enabled as soon as the clip
                      // is downloaded rather than only while it is the active
                      // one: a bar that ignores every touch until you have
                      // already played the message from the start reads as not
                      // being a control at all.
                      : LayoutBuilder(
                          builder: (context, box) {
                            final can = downloaded && box.maxWidth > 0;
                            double at(Offset p) => p.dx / box.maxWidth;
                            final notifier = ref.read(
                              voicePlayControllerProvider.notifier,
                            );
                            // Start-if-needed on the first touch only; every
                            // later drag sample is a plain seek, so dragging
                            // cannot stack load attempts on top of each other.
                            void begin(Offset p) => unawaited(
                              notifier.seekOrStart(messageId, fileKey, at(p)),
                            );
                            void move(Offset p) =>
                                unawaited(notifier.seekTo(messageId, at(p)));
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: can
                                  ? (d) => begin(d.localPosition)
                                  : null,
                              onHorizontalDragStart: can
                                  ? (d) => begin(d.localPosition)
                                  : null,
                              onHorizontalDragUpdate: can
                                  ? (d) => move(d.localPosition)
                                  : null,
                              child: VoiceWaveform(
                                bars: bars,
                                progress: active ? play.progress : 0,
                                playedColor: onBubble,
                                unplayedColor: onBubble.withValues(alpha: 0.4),
                              ),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(width: 8),
              // While active, a speed chip (1×/1.5×/2×) cycles playback rate;
              // otherwise just the duration.
              if (active)
                GestureDetector(
                  onTap: () => ref
                      .read(voicePlayControllerProvider.notifier)
                      .cycleSpeed(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: onBubble.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${_speedLabel(play.speed)}×',
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(color: onBubble),
                    ),
                  ),
                )
              else
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: onBubble.withValues(alpha: 0.8),
                  ),
                ),
            ],
          ),
        ),
        if (downloaded) _transcript(context, ref, onBubble),
      ],
    );
  }

  /// Offered in place of the Transcribe button when the model is not here yet.
  Widget _modelOffer(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final model = ref.watch(whisperModelControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    final label = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: muted);

    if (model.isBusy) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              // Null progress while the server has not said how long the body
              // is — an indeterminate bar beats a made-up percentage.
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: muted,
                value: model.progress,
              ),
            ),
            const SizedBox(width: 8),
            Text(l.voiceModelDownloading, style: label),
          ],
        ),
      );
    }
    final failed = model.phase == WhisperModelPhase.failed;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: () async {
          final ok = await ref
              .read(whisperModelControllerProvider.notifier)
              .download();
          // The availability probe caches its answer, so it has to be asked
          // again or the Transcribe button never appears.
          if (ok) {
            ref.invalidate(transcriptionAvailableProvider);
            ref.invalidate(transcriptionNativeReadyProvider);
          }
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_outlined, size: 15, color: muted),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                failed
                    ? l.voiceModelFailed
                    : model.resumeFraction != null
                    ? '${l.voiceModelResume} · '
                          '${l.voiceModelResumeAt((model.resumeFraction! * 100).round())}'
                    : '${l.voiceModelDownload} · ${l.voiceModelSize}',
                style: label,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The on-device transcription affordance under a downloaded voice clip: a
  /// "Transcribe" button, a spinner while running, then the cached text. Hidden
  /// entirely when the native STT layer / model isn't present.
  Widget _transcript(BuildContext context, WidgetRef ref, Color onBubble) {
    final available = ref.watch(transcriptionAvailableProvider).value ?? false;
    if (!available) {
      // The model is fetched on demand now, so "not available" splits in two.
      // With the native layer present it is a download away and saying so is
      // the whole point; without it there is no whisper build for this
      // platform and offering 57 MiB that cannot help would be a lie.
      final nativeReady =
          ref.watch(transcriptionNativeReadyProvider).value ?? false;
      if (!nativeReady) return const SizedBox.shrink();
      return _modelOffer(context, ref);
    }
    final entry = ref.watch(
      transcriptionControllerProvider.select((m) => m[messageId]),
    );
    // Lazily load a cached transcript once (idempotent in the controller).
    if (entry == null) {
      Future.microtask(
        () => ref
            .read(transcriptionControllerProvider.notifier)
            .loadCached(messageId, fileKey),
      );
    }
    final l = AppL10n.of(context);
    final muted = onBubble.withValues(alpha: 0.7);
    final style = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: onBubble);

    if (entry != null && entry.isRunning) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
            ),
            const SizedBox(width: 8),
            Text(
              l.chatVoiceTranscribing,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      );
    }
    if (entry != null && entry.isDone) {
      final text = entry.text ?? '';
      if (text.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          // Selectable, so the transcript can be taken out of the bubble the
          // way any other text can. It is the one thing on a voice message a
          // person is likely to want to quote, search or paste elsewhere, and
          // a plain Text offered no way to reach it at all. Selection brings
          // the platform's own Copy / Select all with it.
          // Same gesture on the finished text: a transcript that came out as
          // nonsense is exactly when someone wants to name the language, and
          // by then the button that offered it is gone.
          child: GestureDetector(
            onLongPress: () => _pickTranscriptLanguage(
              context,
              ref,
              messageId: messageId,
              fileKey: fileKey,
              senderLang: sidecar?.lang,
              current: entry.lang,
            ),
            child: SelectableText(text, style: style),
          ),
        ),
      );
    }
    // none / failed → a tap-to-transcribe (re-tappable after a failure).
    final failed = entry?.phase == TranscriptPhase.failed;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      // The long-press below is the only way to choose a language, and a
      // gesture with nothing naming it is a feature nobody finds. The tooltip
      // is that name — on desktop it appears on hover, on a phone on the same
      // long press that opens the chooser.
      child: Tooltip(
        message: l.chatVoiceTranscribeAs,
        child: InkWell(
          onTap: () => ref
              .read(transcriptionControllerProvider.notifier)
              .transcribe(messageId, fileKey, senderLang: sidecar?.lang),
          // The guess is right most of the time and wrong in exactly the cases a
          // person notices: a note in a language neither the sender's tag nor
          // this device announces. Long-press says which language to read it as.
          onLongPress: () => _pickTranscriptLanguage(
            context,
            ref,
            messageId: messageId,
            fileKey: fileKey,
            senderLang: sidecar?.lang,
            current: entry?.lang,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.subtitles_outlined, size: 15, color: muted),
              const SizedBox(width: 4),
              Text(
                failed ? l.chatVoiceTranscribeFailed : l.chatVoiceTranscribe,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: failed ? Theme.of(context).colorScheme.error : muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _speedLabel(double s) =>
      s == s.roundToDouble() ? s.toStringAsFixed(0) : s.toStringAsFixed(1);
}

/// Languages offered when a person asks to read a voice note as something
/// other than what was guessed.
///
/// Whisper's model is multilingual, so this is a choice of PROMPT, not a
/// download: the same file reads back differently depending on what it is told
/// to expect. Native names, because a list of languages is the one list a
/// reader can navigate without knowing the app's language.
const _transcriptLanguages = <(String, String)>[
  ('ru', 'Русский'),
  ('en', 'English'),
  ('uk', 'Українська'),
  ('be', 'Беларуская'),
  ('kk', 'Қазақша'),
  ('de', 'Deutsch'),
  ('fr', 'Français'),
  ('es', 'Español'),
  ('pt', 'Português'),
  ('it', 'Italiano'),
  ('pl', 'Polski'),
  ('tr', 'Türkçe'),
  ('ar', 'العربية'),
  ('fa', 'فارسی'),
  ('he', 'עברית'),
  ('hi', 'हिन्दी'),
  ('zh', '中文'),
  ('ja', '日本語'),
  ('ko', '한국어'),
  ('vi', 'Tiếng Việt'),
  ('id', 'Bahasa Indonesia'),
  ('nl', 'Nederlands'),
  ('sv', 'Svenska'),
  ('cs', 'Čeština'),
];

/// Ask which language to read a clip as, then transcribe in it.
Future<void> _pickTranscriptLanguage(
  BuildContext context,
  WidgetRef ref, {
  required String messageId,
  required String fileKey,
  String? senderLang,
  String? current,
}) async {
  final l = AppL10n.of(context);
  final chosen = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l.chatVoiceTranscribeLanguage,
                style: Theme.of(sheet).textTheme.titleSmall,
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _transcriptLanguages.length,
              itemBuilder: (_, i) {
                final (code, name) = _transcriptLanguages[i];
                return ListTile(
                  dense: true,
                  title: Text(name),
                  trailing: code == current
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.of(sheet).pop(code),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
  if (chosen == null) return;
  await ref
      .read(transcriptionControllerProvider.notifier)
      .transcribe(
        messageId,
        fileKey,
        senderLang: senderLang,
        chosenLang: chosen,
      );
}

/// Video message with an embedded preview frame: the media-box rendering
/// (Telegram-style still + overlay) replacing the play-icon file row. The
/// micro-thumb is upscaled + blurred exactly like an image's undownloaded
/// preview (we never decode the video locally for a full-res poster — the
/// frame travels in the advert). Overlay: download progress ring while a
/// transfer runs, play when the blob is held, download otherwise; a held
/// video keeps its save/export affordance as a corner button.
class _VideoPreviewBox extends StatelessWidget {
  const _VideoPreviewBox({
    required this.thumb,
    required this.playable,
    this.progress,
    this.sizeLabel,
    this.onTap,
    this.onSave,
  });

  final Uint8List thumb;
  final bool playable;
  final double? progress;
  final String? sizeLabel;
  final VoidCallback? onTap;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        // Fixed box for the same reason as the image preview: a 32-px thumb's
        // intrinsic size would collapse the bubble to a postage stamp.
        child: SizedBox(
          width: 260,
          height: 170,
          child: Stack(
            alignment: Alignment.center,
            fit: StackFit.expand,
            children: [
              BlurredThumb(bytes: thumb, boxWidth: 260),
              Center(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.35),
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: progress != null
                        ? CancelableDownloadProgress(
                            progress: progress,
                            onCancel: onTap!,
                            size: 24,
                            strokeWidth: 2.5,
                            color: Colors.white,
                          )
                        : Icon(
                            playable ? Icons.play_arrow : Icons.download,
                            size: 24,
                            color: Colors.white,
                          ),
                  ),
                ),
              ),
              if (onSave != null)
                Positioned(
                  top: 6,
                  right: 6,
                  // Named, because a floating disc with a glyph in it is not
                  // self-explanatory and a screen reader announced nothing at
                  // all here. The string for it already existed; nothing used
                  // it. `Tooltip` carries the semantics label as well as the
                  // hover/long-press text, so one wrapper answers both.
                  child: Tooltip(
                    message: AppL10n.of(context).chatFileSave,
                    child: GestureDetector(
                      onTap: onSave,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.save_alt,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (sizeLabel != null)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        sizeLabel!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePreview extends ConsumerStatefulWidget {
  const _ImagePreview({
    required this.fileKey,
    required this.name,
    this.thumbB64,
    this.progress,
    this.onCancel,
    this.onOpen,
    this.onView,
  });
  final String fileKey;
  final String name;

  /// Tap on the DOWNLOADED preview — the swipeable conversation gallery
  /// (falls back to the single-image viewer when null).
  final VoidCallback? onView;

  /// Embedded micro-thumb (base64 PNG travelling IN the message) — rendered
  /// blurred/upscaled while the blob itself is not yet downloaded.
  final String? thumbB64;
  final double? progress;
  final VoidCallback? onCancel;

  /// Fallback tap (download/open) when the bytes aren't in the store yet.
  final VoidCallback? onOpen;

  @override
  ConsumerState<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends ConsumerState<_ImagePreview> {
  /// Resolved image bytes, or null while loading / when the blob is not in
  /// the store. State-based (not a memoized FutureBuilder) so a RE-check can
  /// run silently: the first load shows the spinner, every later attempt
  /// keeps rendering the current state until bytes actually appear. The
  /// memoized-future version fixed the rebuild jitter («чат дрожит») but
  /// never re-read the store, so an incoming photo stayed a blurred
  /// download-affordance forever after its download completed (its fileKey —
  /// the content hash — does not change) and the next tap fell through to
  /// save-file instead of the viewer.
  Uint8List? _resolved;
  bool _initialLoading = true;
  bool _loadInFlight = false;
  DateTime? _lastAttemptAt;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    if (_loadInFlight) return;
    _loadInFlight = true;
    _lastAttemptAt = DateTime.now();
    try {
      final bytes = await ref
          .read(storageProvider)
          .loadFile(widget.fileKey, maxBytes: kInlineImageMaxBytes);
      if (!mounted) return;
      if (bytes != null || _initialLoading) {
        setState(() {
          _resolved = bytes;
          _initialLoading = false;
        });
      }
    } finally {
      _loadInFlight = false;
    }
  }

  @override
  void didUpdateWidget(covariant _ImagePreview old) {
    super.didUpdateWidget(old);
    if (old.fileKey != widget.fileKey) {
      _resolved = null;
      _initialLoading = true;
      unawaited(_load());
      return;
    }
    if (_resolved != null || _initialLoading) return;
    // Undownloaded so far — quietly re-check on rebuilds (messagesProvider
    // re-yields on every signal, including download completion). A finished
    // download is the progress → null edge; the throttle covers completions
    // whose progress stream never emitted.
    final downloadEnded = old.progress != null && widget.progress == null;
    final last = _lastAttemptAt;
    final throttleOk =
        last == null ||
        DateTime.now().difference(last) > const Duration(seconds: 2);
    if (downloadEnded || throttleOk) unawaited(_load());
  }

  String get name => widget.name;
  String? get thumbB64 => widget.thumbB64;
  VoidCallback? get onOpen => widget.onOpen;
  VoidCallback? get onView => widget.onView;
  double? get progress => widget.progress;
  VoidCallback? get onCancel => widget.onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The blurred placeholder gives way to the photo as a fade, not a cut.
    // These are two different subtrees, so a plain rebuild swapped them in one
    // frame — the picture appeared to snap into focus out of nowhere. Keyed on
    // "do we have the bytes yet", which is exactly the moment worth animating.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      // Cross-fade in place: the default lays the outgoing child out again and
      // the fixed-size preview box would jump.
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.center,
        children: <Widget>[...previous, ?current],
      ),
      child: KeyedSubtree(
        key: ValueKey<bool>(_resolved != null),
        child: _content(context, scheme),
      ),
    );
  }

  Widget _content(BuildContext context, ColorScheme scheme) {
    return Builder(
      builder: (context) {
        // First load → spinner. Loaded-but-absent (not in store) → a
        // tappable file chip (download/open), NEVER a perpetual spinner.
        if (_initialLoading) {
          return const SizedBox(
            height: 120,
            width: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final bytes = _resolved;
        if (bytes == null) {
          // Not downloaded yet. With an embedded micro-thumb → an instant
          // blurred preview (tap = the same download affordance); without →
          // the compact file chip.
          Uint8List? thumb;
          final tb = thumbB64;
          if (tb != null) {
            try {
              thumb = base64Decode(tb);
            } catch (_) {
              thumb = null; // hostile/corrupt field — fall back to the chip
            }
          }
          if (thumb != null) {
            return GestureDetector(
              onTap: progress != null ? onCancel : onOpen,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                // Fixed preview box: a 32-px micro-thumb has a tiny intrinsic
                // size, and max-constraints alone would render it (and the
                // bubble) postage-stamp small — size the box, cover-fit the
                // upscaled thumb into it.
                child: SizedBox(
                  width: 260,
                  height: 170,
                  child: Stack(
                    alignment: Alignment.center,
                    fit: StackFit.expand,
                    children: [
                      // The micro-thumb upscaled; the blur hides the pixels
                      // (Telegram-style) and reads as "loading", not "final".
                      BlurredThumb(bytes: thumb, boxWidth: 260),
                      // Download affordance over the preview (Center keeps it
                      // intrinsic-sized under StackFit.expand).
                      Center(
                        child: progress != null && onCancel != null
                            ? CancelableDownloadProgress(
                                progress: progress,
                                onCancel: onCancel!,
                                size: 40,
                                strokeWidth: 3,
                                color: Colors.white,
                              )
                            : DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  shape: BoxShape.circle,
                                ),
                                child: const Padding(
                                  padding: EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.download,
                                    size: 24,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
          return InkWell(
            onTap: progress != null ? onCancel : onOpen,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
                if (progress != null && onCancel != null) ...[
                  const SizedBox(width: 8),
                  CancelableDownloadProgress(
                    progress: progress,
                    onCancel: onCancel!,
                    size: 24,
                    strokeWidth: 2,
                  ),
                ],
              ],
            ),
          );
        }
        return GestureDetector(
          onTap:
              onView ??
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => _FullscreenImage(bytes: bytes, name: name),
                ),
              ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 280),
              child: Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                // Decode only to the physical display footprint. Keeping a
                // 12-MP source as a full RGBA surface for a 280×240 bubble can
                // cost tens of MiB per visible message; the original bytes are
                // still used by the full-screen gallery for lossless zoom.
                cacheWidth: mediaPreviewCacheDimension(
                  280,
                  MediaQuery.devicePixelRatioOf(context),
                ),
                cacheHeight: mediaPreviewCacheDimension(
                  240,
                  MediaQuery.devicePixelRatioOf(context),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One entry of the conversation media gallery: an image message, keyed the
/// way the bubble keys its preview (fileId when held, else the contentId —
/// an incoming content-path image keeps fileContentId even после download,
/// its blob living under the hash; loadFile resolves both). [thumb] is the
/// embedded micro-thumb, the fallback rendering for pages whose blob isn't
/// downloaded yet.
typedef GalleryItem = ({String id, String fileKey, String name, String? thumb});

/// The gallery retains raw decrypted bytes only for the visible page and its
/// immediate neighbours. A conversation may contain hundreds of large images;
/// memoizing every visited `Future<Uint8List>` until the route closes otherwise
/// grows linearly and can exhaust a mobile process even though PageView has
/// already disposed the distant page widgets.
const kMediaGalleryRetainedRadius = 1;
const kMediaPreviewMaxDecodeDimension = 2048;

/// Convert a logical preview dimension into the exact physical-pixel decode
/// target, with a defensive ceiling for pathological device metrics.
int mediaPreviewCacheDimension(double logicalPixels, double devicePixelRatio) {
  if (!logicalPixels.isFinite ||
      !devicePixelRatio.isFinite ||
      logicalPixels <= 0 ||
      devicePixelRatio <= 0) {
    return 1;
  }
  return (logicalPixels * devicePixelRatio).ceil().clamp(
    1,
    kMediaPreviewMaxDecodeDimension,
  );
}

Set<String> mediaGalleryRetainedKeys(
  List<GalleryItem> items,
  int current, {
  int radius = kMediaGalleryRetainedRadius,
}) {
  if (items.isEmpty || radius < 0) return const {};
  final center = current.clamp(0, items.length - 1);
  final first = center - radius < 0 ? 0 : center - radius;
  final last = center + radius >= items.length
      ? items.length - 1
      : center + radius;
  return {for (var i = first; i <= last; i++) items[i].fileKey};
}

/// The swipeable-gallery item set for a loaded conversation: every image
/// message with a loadable key, in display order. Pure — unit-tested. Pages
/// without local bytes degrade to the embedded thumb / a placeholder, so an
/// offered-not-downloaded image doesn't break the swipe sequence.
List<GalleryItem> conversationGalleryItems(List<Message> messages) => [
  for (final msg in messages)
    if (isImageFileName(msg.fileName) &&
        (msg.fileId ?? msg.fileContentId) != null)
      (
        id: msg.id,
        fileKey: (msg.fileId ?? msg.fileContentId)!,
        name: msg.fileName ?? '',
        thumb: msg.thumb,
      ),
];

/// Swipeable full-screen gallery over every downloaded image of the
/// conversation (media epic: "свайп между медиа"). Pages load their bytes
/// from the encrypted store on demand; each page zooms independently. The
/// app bar shows the current file name and the position in the set.
class _MediaGallery extends ConsumerStatefulWidget {
  const _MediaGallery({required this.items, required this.initialIndex});
  final List<GalleryItem> items;
  final int initialIndex;

  @override
  ConsumerState<_MediaGallery> createState() => _MediaGalleryState();
}

class _MediaGalleryState extends ConsumerState<_MediaGallery> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _current = widget.initialIndex;

  /// Per-key memoized loads for the current page and immediate neighbours.
  /// Keeping every visited image would retain every raw decrypted blob until
  /// the gallery route closes, even after PageView disposed the page.
  final Map<String, Future<Uint8List?>> _loads = {};

  Future<Uint8List?> _load(int index) {
    final fileKey = widget.items[index].fileKey;
    final keep = mediaGalleryRetainedKeys(widget.items, _current);
    if (!keep.contains(fileKey)) {
      return ref
          .read(storageProvider)
          .loadFile(fileKey, maxBytes: kInlineImageMaxBytes);
    }
    return _loads[fileKey] ??= ref
        .read(storageProvider)
        .loadFile(fileKey, maxBytes: kInlineImageMaxBytes);
  }

  void _onPageChanged(int index) {
    final keep = mediaGalleryRetainedKeys(widget.items, index);
    _loads.removeWhere((fileKey, _) => !keep.contains(fileKey));
    setState(() => _current = index);
  }

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_current];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(item.name, overflow: TextOverflow.ellipsis),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${_current + 1}/${widget.items.length}',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _page,
        itemCount: widget.items.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, i) {
          final it = widget.items[i];
          return FutureBuilder<Uint8List?>(
            future: _load(i),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final bytes = snap.data;
              if (bytes == null) {
                // Not downloaded (offered) or vanished: degrade to the
                // embedded micro-thumb when the message carries one, else an
                // inert placeholder — never a crash or spinner.
                Uint8List? thumb;
                final tb = it.thumb;
                if (tb != null) {
                  try {
                    thumb = base64Decode(tb);
                  } catch (_) {
                    thumb = null;
                  }
                }
                if (thumb != null) {
                  return ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: 6,
                      sigmaY: 6,
                      tileMode: TileMode.decal,
                    ),
                    child: Image.memory(
                      thumb,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  );
                }
                return const Center(
                  child: Icon(
                    Icons.image_not_supported_outlined,
                    color: Colors.white38,
                    size: 48,
                  ),
                );
              }
              return Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Image.memory(bytes, gaplessPlayback: true),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// Full-screen zoomable image viewer (pinch/scroll to zoom, drag to pan).
class _FullscreenImage extends StatelessWidget {
  const _FullscreenImage({required this.bytes, required this.name});
  final Uint8List bytes;
  final String name;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(name, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Image.memory(bytes, gaplessPlayback: true),
        ),
      ),
    );
  }
}

enum _FileAffordance { download, save, open, gone }

/// Resolve a forwarded message's origin (the original author's node-id hex on
/// the wire) to a display name using MY OWN contacts: "you" for my identity, my
/// contact name for a known peer, else a short node id. Legacy forwards that
/// stored a display label (pre node-id attribution) are shown as-is.
String _resolveForwardAuthor(WidgetRef ref, AppL10n l, String origin) {
  final NodeId id;
  try {
    id = NodeId.fromHex(origin);
  } catch (_) {
    return origin; // not a node id — an old label-based forward
  }
  final myHex = ref.read(appControllerProvider).identity?.nodeId.hex;
  if (myHex != null && id.hex == myHex) return l.chatYou;
  final contact = ref.watch(contactProvider(id.hex)).value;
  return contact?.name ?? id.short;
}

class _SpaceRecommendationBubble extends ConsumerStatefulWidget {
  const _SpaceRecommendationBubble({required this.card});

  final SpaceRecommendationCard card;

  @override
  ConsumerState<_SpaceRecommendationBubble> createState() =>
      _SpaceRecommendationBubbleState();
}

class _SpaceRecommendationBubbleState
    extends ConsumerState<_SpaceRecommendationBubble> {
  bool _working = false;

  Future<void> _openOrJoin() async {
    if (_working) return;
    setState(() => _working = true);
    final l = AppL10n.of(context);
    final service = ref.read(groupServiceProvider);
    if (service == null) {
      if (mounted) setState(() => _working = false);
      return;
    }
    final local = await service.load(widget.card.spaceId);
    if (!mounted) return;
    if (local != null) {
      setState(() => _working = false);
      await context.push('/space/${widget.card.spaceId.hex}');
      return;
    }
    final sent = await service.requestToJoinSpace(widget.card.joinCode);
    if (!mounted) return;
    setState(() => _working = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(sent ? l.spaceJoinRequestSent : l.spaceOperationFailed),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 340),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 19,
                backgroundColor: scheme.secondaryContainer,
                foregroundColor: scheme.onSecondaryContainer,
                child: const Icon(Icons.groups_2_outlined, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.card.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(widget.card.text),
          if (widget.card.description.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              widget.card.description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _working ? null : _openOrJoin,
              icon: _working
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
              label: Text(l.spaceJoinAction),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends ConsumerWidget {
  const _Bubble({
    super.key,
    required this.message,
    this.quoted,
    this.selected = false,
    this.selecting = false,
    this.onTapFile,
    this.onLongPress,
    this.onTap,
    this.onTapQuote,
    this.onOpenImage,
    this.onPlayVideo,
    this.onToggleReaction,
    this.onShowReactors,
    this.highlight,
  });
  final Message message;

  /// Tap a reaction chip to toggle that emoji on this message.
  final void Function(Message message, String emoji)? onToggleReaction;

  /// Long-press (or right-click) a reaction chip: show who reacted.
  final void Function(Message message)? onShowReactors;

  /// Tap on a DOWNLOADED inline image — the chat screen opens the swipeable
  /// media gallery positioned on this message (null = fall back to the
  /// single-image viewer).
  final void Function(Message message)? onOpenImage;

  /// Tap on a HELD video file row — the chat screen opens the in-app player
  /// (loopback-streamed; null = the row keeps the plain save behavior).
  final void Function(Message message)? onPlayVideo;

  /// Active in-chat search query — occurrences in the body get a highlight
  /// background (null when not searching).
  final String? highlight;

  /// The message this one replies to, resolved from the visible window (null if
  /// it's not a reply, or the quoted message is out of the window / deleted).
  final Message? quoted;

  /// Multi-select rendering: [selected] tints the row; [selecting] means a plain
  /// tap toggles selection (via [onTap]) instead of doing nothing.
  final bool selected;
  final bool selecting;
  final void Function(Message message)? onTapFile;
  final void Function(Message message)? onLongPress;
  final VoidCallback? onTap;

  /// Tap on the quoted-reply block — the chat screen jumps to the quoted
  /// message.
  final VoidCallback? onTapQuote;

  /// Whether the file blob is locally available (bubble shows "save" vs
  /// "download"). Resilient: a not-yet-open / erroring store falls back to the
  /// fileId presence instead of throwing out of build.
  /// What tapping the file does right now: download an OFFER, SAVE a blob we hold
  /// in the app, or OPEN a file already downloaded unencrypted to disk.
  Future<_FileAffordance> _affordance(WidgetRef ref) async {
    final key = message.fileId ?? message.fileContentId;
    if (key == null) {
      return message.fileId != null
          ? _FileAffordance.save
          : _FileAffordance.download;
    }
    try {
      if (await ref.read(storageProvider).hasFile(key)) {
        return _FileAffordance.save;
      }
    } catch (_) {
      if (message.fileId != null) return _FileAffordance.save;
    }
    final cid = message.fileContentId ?? message.fileId;
    if (cid != null) {
      final saved = await ref
          .read(messagingServiceProvider)
          .contentSavedPath(cid);
      if (saved != null &&
          await _savedFileLooksComplete(
            saved,
            expectedSize: message.fileSize,
          )) {
        return _FileAffordance.open;
      }
      // Every known holder said the bytes are gone — render the terminal
      // "ask the sender to re-send" state. A tap still retries (the download
      // entry point clears the mark; a live holder then re-offers).
      try {
        if (await ref
            .read(messagingServiceProvider)
            .isContentUnavailable(cid)) {
          return _FileAffordance.gone;
        }
      } catch (_) {}
    }
    return _FileAffordance.download;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message.direction == MessageDirection.outgoing;
    final recommendation = parseSpaceRecommendationMessage(message.body);
    final naked = message.isFile && isStickerFileName(message.fileName);
    // In-flight download fraction for this file (null = not downloading). Falls
    // back to fileId so our OWN re-download (pulling a deleted sent file back
    // from the recipient) shows progress too.
    final cid = message.fileContentId ?? message.fileId;
    final progress = cid == null
        ? null
        : ref.watch(contentProgressProvider.select((m) => m[cid]));
    // A parked auto-resume shows NO progress until a pull moves bytes; surface
    // it as "resuming…" so a queued/retrying download does not look idle.
    final resuming =
        cid != null &&
        progress == null &&
        ref.watch(contentResumingProvider.select((s) => s.contains(cid)));
    final cancelDownload = cid == null
        ? null
        : () => unawaited(_cancelContentDownload(ref, cid));
    return Container(
      // Selected rows get a full-width tint so the selection reads at a glance.
      color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
      child: Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: GestureDetector(
          // Long-press (touch) AND secondary-tap (desktop right-click) both open
          // the message actions — without the latter the menu is unreachable on
          // desktop, where there is no long-press. In select mode a plain tap
          // toggles the row instead.
          onTap: onTap,
          onLongPress: onLongPress == null ? null : () => onLongPress!(message),
          onSecondaryTap: onLongPress == null
              ? null
              : () => onLongPress!(message),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            // A sticker renders NAKED (no bubble chrome), Telegram-style —
            // just the image with the meta row under it.
            padding: naked
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75,
            ),
            decoration: naked
                ? null
                : BoxDecoration(
                    color: outgoing
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(outgoing ? 16 : 4),
                      bottomRight: Radius.circular(outgoing ? 4 : 16),
                    ),
                  ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                // "Forwarded from X" caption. The wire carries the original
                // author's node-id hex; resolve it through MY OWN contacts here so
                // the sender's private alias never leaked (see _forwardMessages).
                if (message.forwardedFrom != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forward,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            l.chatForwardedFrom(
                              _resolveForwardAuthor(
                                ref,
                                l,
                                message.forwardedFrom!,
                              ),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontStyle: FontStyle.italic,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                // Quoted reply preview (a reference to a deleted/out-of-window
                // message shows a generic stub). Tapping it jumps to the quoted
                // message.
                if (message.replyToId != null)
                  GestureDetector(
                    onTap: onTapQuote,
                    child: _QuoteBlock(quoted: quoted, outgoing: outgoing),
                  ),
                if (recommendation != null)
                  _SpaceRecommendationBubble(card: recommendation)
                else if (message.isFile &&
                    isStickerPackFileName(message.fileName))
                  _StickerPackCard(
                    fileKey: message.fileId ?? message.fileContentId ?? '',
                    thumbB64: message.thumb,
                    downloaded: progress == null && (message.fileId != null),
                    progress: progress,
                    onDownload: progress != null
                        ? cancelDownload
                        : onTapFile == null
                        ? null
                        : () => onTapFile!(message),
                  )
                else if (message.isFile &&
                    isModelBundleFileName(message.fileName))
                  // A model, not content: an offer to install something that
                  // will decide what this app says other people wrote. The
                  // card says so, and installs nothing until its manifest and
                  // hashes have been read.
                  ModelBundleCard(
                    fileKey: message.fileId ?? message.fileContentId ?? '',
                    fileName: message.fileName,
                    sizeBytes: message.fileSize,
                    downloaded: progress == null && (message.fileId != null),
                    progress: progress,
                    onDownload: progress != null
                        ? cancelDownload
                        : onTapFile == null
                        ? null
                        : () => onTapFile!(message),
                  )
                else if (message.isFile && isStickerFileName(message.fileName))
                  _StickerContent(
                    fileKey: message.fileId ?? message.fileContentId ?? '',
                    thumbB64: message.thumb,
                    progress: progress,
                    onCancel: cancelDownload,
                    onDownload: onTapFile == null
                        ? null
                        : () => onTapFile!(message),
                  )
                else if (message.isFile && isVnoteFileName(message.fileName))
                  FutureBuilder<_FileAffordance>(
                    future: _affordance(ref),
                    builder: (context, snap) {
                      final a =
                          snap.data ??
                          (message.fileId != null
                              ? _FileAffordance.save
                              : _FileAffordance.download);
                      final downloaded =
                          progress == null && a == _FileAffordance.save;
                      return _VnoteBubble(
                        messageId: message.id,
                        fileKey: message.fileId ?? message.fileContentId ?? '',
                        sidecar: decodeVnoteSidecar(message.thumb),
                        outgoing: outgoing,
                        downloaded: downloaded,
                        progress: progress,
                        onDownload: progress != null
                            ? cancelDownload
                            : (!downloaded && onTapFile != null)
                            ? () => onTapFile!(message)
                            : null,
                      );
                    },
                  )
                else if (message.isFile && isVoiceFileName(message.fileName))
                  FutureBuilder<_FileAffordance>(
                    future: _affordance(ref),
                    builder: (context, snap) {
                      final a =
                          snap.data ??
                          (message.fileId != null
                              ? _FileAffordance.save
                              : _FileAffordance.download);
                      final downloaded =
                          progress == null && a == _FileAffordance.save;
                      return _VoiceBubble(
                        messageId: message.id,
                        fileKey: message.fileId ?? message.fileContentId ?? '',
                        sidecar: decodeVoiceSidecar(message.thumb),
                        outgoing: outgoing,
                        downloaded: downloaded,
                        progress: progress,
                        onDownload: progress != null
                            ? cancelDownload
                            : (!downloaded && onTapFile != null)
                            ? () => onTapFile!(message)
                            : null,
                      );
                    },
                  )
                else if (message.isFile &&
                    isImageFileName(message.fileName) &&
                    (message.fileId ?? message.fileContentId) != null)
                  _ImagePreview(
                    fileKey: (message.fileId ?? message.fileContentId)!,
                    name: message.fileName ?? '',
                    thumbB64: message.thumb,
                    progress: progress,
                    onCancel: cancelDownload,
                    onOpen: onTapFile == null
                        ? null
                        : () => onTapFile!(message),
                    onView: onOpenImage == null
                        ? null
                        : () => onOpenImage!(message),
                  )
                else if (message.isFile)
                  FutureBuilder<_FileAffordance>(
                    future: _affordance(ref),
                    builder: (context, snap) {
                      final a =
                          snap.data ??
                          (message.fileId != null
                              ? _FileAffordance.save
                              : _FileAffordance.download);
                      // Terminal state only renders when nothing is in flight —
                      // a live retry's spinner wins over the stale mark.
                      final gone =
                          progress == null && a == _FileAffordance.gone;
                      // A HELD video plays on tap (the in-app player over the
                      // loopback stream); save moves to the trailing button.
                      final playable =
                          onPlayVideo != null &&
                          a == _FileAffordance.save &&
                          isVideoFileName(message.fileName);
                      // A video WITH an embedded preview frame renders as a
                      // media box (thumb + play/download overlay) instead of
                      // the file row. Terminal-degraded states (gone /
                      // resuming) keep the row — its honest status text.
                      final videoThumb =
                          isVideoFileName(message.fileName) &&
                              !gone &&
                              !resuming
                          ? _decodeThumbB64(message.thumb)
                          : null;
                      if (videoThumb != null) {
                        return _VideoPreviewBox(
                          thumb: videoThumb,
                          playable: playable,
                          progress: progress,
                          sizeLabel: message.fileSize != null
                              ? _formatBytes(message.fileSize!)
                              : null,
                          onTap: progress != null
                              ? cancelDownload
                              : playable
                              ? () => onPlayVideo!(message)
                              : (onTapFile == null
                                    ? null
                                    : () => onTapFile!(message)),
                          onSave: playable && onTapFile != null
                              ? () => onTapFile!(message)
                              : null,
                        );
                      }
                      return InkWell(
                        onTap: progress != null || resuming
                            ? cancelDownload
                            : playable
                            ? () => onPlayVideo!(message)
                            : (onTapFile == null
                                  ? null
                                  : () => onTapFile!(message)),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              playable
                                  ? Icons.play_circle_outline
                                  : documentIcon(message.fileName),
                              size: 20,
                              color: playable
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    message.fileName ?? message.body,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  // Subtitle: "Downloading NN%" while a transfer
                                  // is in flight; the ask-to-re-send notice when
                                  // every holder said GONE; else the file size.
                                  if (progress != null)
                                    Text(
                                      '${l.fileDownloading} ${(progress * 100).round()}%',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    )
                                  else if (resuming)
                                    Text(
                                      l.fileResuming,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    )
                                  else if (gone)
                                    Text(
                                      l.fileGoneAskResend,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(color: scheme.error),
                                    )
                                  else if (message.fileSize != null)
                                    Text(
                                      _formatBytes(message.fileSize!),
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: scheme.onSurfaceVariant,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            // While downloading: a ring at the current fraction.
                            // Else an icon per affordance. A HELD blob shows the
                            // "downloaded ✓" mark (NOT a plain down-arrow — that
                            // reads as "still needs downloading", the exact
                            // confusion users hit after storage compaction, which
                            // keeps the file but the bubble looked un-fetched);
                            // tapping it still exports/saves.
                            if (progress != null)
                              CancelableDownloadProgress(
                                progress: progress,
                                onCancel: cancelDownload!,
                                size: 20,
                                strokeWidth: 2,
                                color: scheme.onSurfaceVariant,
                              )
                            else if (resuming)
                              CancelableDownloadProgress(
                                progress: null,
                                onCancel: cancelDownload!,
                                size: 20,
                                strokeWidth: 2,
                                color: scheme.onSurfaceVariant,
                              )
                            else if (playable)
                              // Row-tap plays; saving the video moved here.
                              InkWell(
                                onTap: onTapFile == null
                                    ? null
                                    : () => onTapFile!(message),
                                child: Icon(
                                  Icons.download_done_outlined,
                                  size: 16,
                                  color: scheme.primary,
                                ),
                              )
                            else
                              Icon(
                                switch (a) {
                                  _FileAffordance.save =>
                                    Icons.download_done_outlined,
                                  _FileAffordance.open => Icons.open_in_new,
                                  _FileAffordance.gone =>
                                    Icons.file_download_off_outlined,
                                  _FileAffordance.download =>
                                    Icons.download_outlined,
                                },
                                size: 16,
                                color: switch (a) {
                                  _FileAffordance.gone => scheme.error,
                                  _FileAffordance.save => scheme.primary,
                                  _ => scheme.onSurfaceVariant,
                                },
                              ),
                          ],
                        ),
                      );
                    },
                  )
                else
                  FormattedText(
                    message.body,
                    highlight: highlight,
                    customEmoji: message.customEmoji,
                  ),
                // On-device translation of an INCOMING message, by button.
                // Hidden entirely when no engine is present — see
                // `_TranslationRow`.
                if (message.direction == MessageDirection.incoming &&
                    message.body.trim().isNotEmpty)
                  _TranslationRow(messageId: message.id, body: message.body),
                // Reaction chips: aggregated emoji → count for this message.
                // Tap toggles my reaction, long-press / right-click lists the
                // reactors; hidden entirely by the "show reactions" preference.
                // In select mode the chips go inert so taps fall through to
                // the row-selection gesture.
                Builder(
                  builder: (context) {
                    if (!ref.watch(showReactionsProvider)) {
                      return const SizedBox.shrink();
                    }
                    final forMsg = ref
                        .watch(reactionsProvider(message.conversationId))
                        .value?[message.id];
                    if (forMsg == null || forMsg.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final selfHex = ref.watch(
                      appControllerProvider.select(
                        (s) => s.identity?.nodeId.hex,
                      ),
                    );
                    final mine = selfHex == null ? null : forMsg[selfHex];
                    final counts = <String, int>{};
                    for (final e in forMsg.values) {
                      counts[e] = (counts[e] ?? 0) + 1;
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final entry in counts.entries)
                            InkWell(
                              onTap: selecting || onToggleReaction == null
                                  ? null
                                  : () => onToggleReaction!(message, entry.key),
                              onLongPress: selecting || onShowReactors == null
                                  ? null
                                  : () => onShowReactors!(message),
                              onSecondaryTap:
                                  selecting || onShowReactors == null
                                  ? null
                                  : () => onShowReactors!(message),
                              borderRadius: BorderRadius.circular(10),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: mine == entry.key
                                      ? scheme.primaryContainer
                                      : scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(10),
                                  border: mine == entry.key
                                      ? Border.all(
                                          color: scheme.primary,
                                          width: 1,
                                        )
                                      : null,
                                ),
                                child: Text(
                                  '${entry.key} ${entry.value}',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.edited) ...[
                      Text(
                        l.chatEdited,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      formatHhmm(message.timestamp),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (outgoing) ...[
                      const SizedBox(width: 4),
                      Icon(
                        _statusIcon(message.status),
                        size: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                    ..._signatureBadge(context, l, scheme),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Attestation badge for the "request signature" feature — an icon + tooltip
  /// reflecting [Message.signature]. Empty for [MessageSignature.none].
  List<Widget> _signatureBadge(
    BuildContext context,
    AppL10n l,
    ColorScheme scheme,
  ) {
    final (
      IconData icon,
      Color color,
      String tip,
    ) = switch (message.signature) {
      MessageSignature.none => (Icons.circle, Colors.transparent, ''),
      MessageSignature.requested => (
        Icons.hourglass_empty,
        scheme.onSurfaceVariant,
        l.chatSignaturePending,
      ),
      MessageSignature.verified => (
        Icons.verified,
        Colors.green,
        l.chatSignatureVerified,
      ),
      MessageSignature.refused => (
        Icons.gpp_bad_outlined,
        scheme.onSurfaceVariant,
        l.chatSignatureRefused,
      ),
      MessageSignature.failed => (
        Icons.error_outline,
        scheme.error,
        l.chatSignatureFailed,
      ),
    };
    if (message.signature == MessageSignature.none) return const [];
    return [
      const SizedBox(width: 4),
      Tooltip(
        message: tip,
        child: Icon(icon, size: 13, color: color),
      ),
    ];
  }

  static IconData _statusIcon(MessageStatus s) => switch (s) {
    MessageStatus.sending => Icons.schedule,
    MessageStatus.sent => Icons.check,
    MessageStatus.delivered => Icons.done_all,
    MessageStatus.failed => Icons.error_outline,
  };
}

/// The on-device translation affordance under an incoming text message: a
/// "Translate" button, a spinner while running, then the reading in this
/// device's language with a tap to go back to the original.
///
/// Hidden entirely when no engine is wired, exactly as the transcription
/// affordance is hidden without whisper. A button that cannot work is worse
/// than no button: it promises a capability the build does not have, and the
/// person who taps it learns that by being ignored.
///
/// Incoming only. Translating one's own message is a spell-checker, not a
/// translator, and the bubble has no room for affordances nobody asked for.
class _TranslationRow extends ConsumerStatefulWidget {
  const _TranslationRow({required this.messageId, required this.body});

  final String messageId;
  final String body;

  @override
  ConsumerState<_TranslationRow> createState() => _TranslationRowState();
}

class _TranslationRowState extends ConsumerState<_TranslationRow> {
  @override
  void initState() {
    super.initState();
    // ONCE per mount, not once per build.
    //
    // The look-up costs a read of the encrypted store, and a widget under
    // every incoming message rebuilds with the list. Asking from `build` meant
    // a read per message per frame — the controller now remembers a miss as
    // well as a hit, and this makes sure the question is not asked that often
    // in the first place.
    Future.microtask(
      () => ref
          .read(translationControllerProvider.notifier)
          .loadCached(widget.messageId),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messageId = widget.messageId;
    final body = widget.body;
    if (!ref.watch(translationAvailableProvider)) {
      return const SizedBox.shrink();
    }
    final entry = ref.watch(
      translationControllerProvider.select((m) => m[messageId]),
    );
    final l = AppL10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;

    if (entry != null && entry.isRunning) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.6, color: muted),
            ),
            const SizedBox(width: 8),
            Text(
              l.chatTranslating,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: muted),
            ),
          ],
        ),
      );
    }
    if (entry != null && entry.isDone) {
      final text = entry.text ?? '';
      if (text.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Reachable after the fact too: a reading that came out wrong is
            // exactly when someone wants to name the language, and by then the
            // button that offered it is gone.
            GestureDetector(
              onLongPress: () => _pickTranslationLanguage(
                context,
                ref,
                messageId: messageId,
                body: body,
                current: entry.to,
              ),
              child: SelectableText(
                text,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            InkWell(
              onTap: () => ref
                  .read(translationControllerProvider.notifier)
                  .clear(messageId),
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  l.chatTranslationShowOriginal,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: muted),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final failed = entry?.phase == TranslationPhase.failed;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      // Same shape as the transcription affordance: tap reads it in this
      // device's language, long-press says which language to read it AS. The
      // guess is right most of the time and wrong exactly where a person
      // notices — a thread in a language neither this device nor the sender
      // announces.
      child: Tooltip(
        message: l.chatTranslateInto,
        child: InkWell(
        onTap: () => ref
            .read(translationControllerProvider.notifier)
            .translate(messageId, body),
        onLongPress: () => _pickTranslationLanguage(
          context,
          ref,
          messageId: messageId,
          body: body,
          current: entry?.to,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate_outlined, size: 15, color: muted),
            const SizedBox(width: 4),
            Text(
              failed ? l.chatTranslateFailed : l.chatTranslate,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: failed ? scheme.error : muted,
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// Languages offered when a person asks to read a message as something other
/// than what this device announces.
///
/// The same list the voice transcriber offers, and for the same reason: a list
/// of languages is the one list a reader can navigate without already knowing
/// the app's language, so the names are native.
const _translationLanguages = _transcriptLanguages;

Future<void> _pickTranslationLanguage(
  BuildContext context,
  WidgetRef ref, {
  required String messageId,
  required String body,
  String? current,
}) async {
  final l = AppL10n.of(context);
  final chosen = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                l.chatTranslateInto,
                style: Theme.of(sheet).textTheme.titleSmall,
              ),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _translationLanguages.length,
              itemBuilder: (_, i) {
                final (code, name) = _translationLanguages[i];
                return ListTile(
                  dense: true,
                  title: Text(name),
                  trailing: code == current
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.of(sheet).pop(code),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
  if (chosen == null) return;
  await ref
      .read(translationControllerProvider.notifier)
      .translate(messageId, body, to: chosen);
}
