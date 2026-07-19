part of 'chat_screen.dart';

/// Live round self-preview while recording a video note: converts the
/// controller's latest RGBA frame to a [ui.Image], coalescing decodes (a slow
/// frame is skipped, never queued) — the calls' remote-video pattern.
enum ComposerAttachmentAction {
  voice,
  videoNote,
  camera,
  photo,
  video,
  file,
  gif,
  poll,
  location,
}

class MessageComposer extends ConsumerStatefulWidget {
  const MessageComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSend,
    this.onAttachmentAction,
    this.onVoice,
    this.onVideoNote,
    this.onSticker,
    this.allowStickerPackShare = true,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onSend;

  /// When set, shows the unified attachment menu. Voice/video-note recording
  /// stays inside this widget; file/camera choices are delegated to the chat.
  final Future<void> Function(ComposerAttachmentAction action)?
  onAttachmentAction;

  /// When set (accepted contacts only), shows a hold-to-record mic button on
  /// an empty field; releasing sends the recorded [VoiceClip].
  final void Function(VoiceClip clip)? onVoice;

  /// When set, the capture button gains a mic↔camera mode toggle and the
  /// camera mode records a round video note ([VnoteClip]).
  final void Function(VnoteClip clip)? onVideoNote;

  /// When set, a sticker button opens the sticker panel; picking one passes
  /// its store item id here to send.
  final void Function(String itemId)? onSticker;
  final bool allowStickerPackShare;

  @override
  ConsumerState<MessageComposer> createState() => _MessageComposerState();
}

class _MessageComposerState extends ConsumerState<MessageComposer> {
  TextEditingController get controller => widget.controller;
  FocusNode get focusNode => widget.focusNode;
  VoidCallback get onSend => widget.onSend;

  /// Rolling recent capture levels, painted as the live waveform while
  /// recording. Fed from the record controller's poll ticks.
  final List<double> _liveLevels = [];

  bool _fieldHovered = false;
  bool _expressionOpen = false;
  bool _expressionHoverArmed = true;
  Timer? _expressionHoverTimer;

  bool get _supportsHover =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void dispose() {
    _expressionHoverTimer?.cancel();
    super.dispose();
  }

  /// Wrap the current selection (or insert at the cursor) with a formatting
  /// marker, keeping focus + the wrapped selection so the user can keep typing
  /// or stack another format.
  void _wrap(String marker) {
    final v = controller.value;
    final r = applyMarker(v.text, v.selection, marker);
    controller.value = v.copyWith(
      text: r.text,
      selection: r.selection,
      composing: TextRange.empty,
    );
    focusNode.requestFocus();
  }

  /// Insert [s] at the cursor (replacing any selection), keeping focus and
  /// placing the caret after the insertion. Drives the emoji picker and the
  /// Shift+Enter newline.
  void _insertText(String s) {
    final v = controller.value;
    final sel = v.selection;
    final start = sel.isValid ? sel.start : v.text.length;
    final end = sel.isValid ? sel.end : v.text.length;
    controller.value = v.copyWith(
      text: v.text.replaceRange(start, end, s),
      selection: TextSelection.collapsed(offset: start + s.length),
      composing: TextRange.empty,
    );
    focusNode.requestFocus();
  }

  /// Bound to Shift+Enter: Flutter maps no default editing action to it, so
  /// without an explicit binding the keystroke would do NOTHING once plain
  /// Enter is claimed by the send shortcut.
  void _insertNewline() => _insertText('\n');

  Future<void> _openExpressions(BuildContext context) async {
    if (_expressionOpen || !mounted) return;
    _expressionOpen = true;
    _expressionHoverArmed = false;
    _expressionHoverTimer?.cancel();
    try {
      final picked = await showComposerExpressionPanel(
        context,
        enableStickers: widget.onSticker != null,
        enableGif: widget.onAttachmentAction != null,
        allowStickerPackShare: widget.allowStickerPackShare,
      );
      if (!mounted || picked == null) return;
      switch (picked.kind) {
        case ComposerExpressionKind.emoji:
          if (picked.value != null) _insertText(picked.value!);
        case ComposerExpressionKind.customEmoji:
          final itemId = picked.value;
          if (itemId == null || controller is! CustomEmojiEditingController) {
            return;
          }
          final bytes = await ref
              .read(stickerControllerProvider.notifier)
              .bytesFor(itemId);
          if (bytes == null) return;
          final emoji = await normalizeCustomEmojiBytes(bytes);
          if (emoji == null || !mounted) return;
          (controller as CustomEmojiEditingController).insertCustomEmoji(emoji);
          focusNode.requestFocus();
        case ComposerExpressionKind.sticker:
          if (picked.value != null) widget.onSticker?.call(picked.value!);
        case ComposerExpressionKind.gif:
          await widget.onAttachmentAction?.call(ComposerAttachmentAction.gif);
      }
    } finally {
      _expressionOpen = false;
    }
  }

  void _scheduleExpressionHover(BuildContext context) {
    if (!_supportsHover || _expressionOpen || !_expressionHoverArmed) return;
    _expressionHoverArmed = false;
    _expressionHoverTimer?.cancel();
    _expressionHoverTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) unawaited(_openExpressions(context));
    });
  }

  /// Prefix every line spanned by the selection (or the cursor's line) with
  /// `> `, turning it into a block quote. Line-level, so it can't reuse the
  /// marker-wrap path — the region is expanded to whole lines first.
  void _prefixQuote() {
    final v = controller.value;
    final text = v.text;
    final sel = v.selection;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final lineStart = text.lastIndexOf('\n', start - 1) + 1;
    var lineEnd = text.indexOf('\n', end);
    if (lineEnd < 0) lineEnd = text.length;
    final region = text.substring(lineStart, lineEnd);
    final quoted = region.split('\n').map((l) => '> $l').join('\n');
    final newText =
        text.substring(0, lineStart) + quoted + text.substring(lineEnd);
    controller.value = v.copyWith(
      text: newText,
      selection: TextSelection.collapsed(
        offset: lineEnd + (quoted.length - region.length),
      ),
      composing: TextRange.empty,
    );
    focusNode.requestFocus();
  }

  Future<void> _startRecording() async {
    _liveLevels.clear();
    await ref.read(voiceRecordControllerProvider.notifier).start();
  }

  /// Stop recording and send the clip (the recording bar's Send button).
  void _sendRecording() {
    final clip = ref.read(voiceRecordControllerProvider.notifier).stop();
    if (clip != null) widget.onVoice?.call(clip);
  }

  Future<void> _startVnoteRecording() async {
    await ref.read(vnoteRecordControllerProvider.notifier).start();
  }

  void _sendVnoteRecording() {
    final clip = ref.read(vnoteRecordControllerProvider.notifier).stop();
    if (clip != null) widget.onVideoNote?.call(clip);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Feed the live waveform + surface permission/record failures.
    ref.listen<VoiceRecordState>(voiceRecordControllerProvider, (prev, next) {
      if (next.phase == VoiceRecordPhase.recording) {
        setState(() {
          _liveLevels.add(next.level);
          if (_liveLevels.length > 44) _liveLevels.removeAt(0);
        });
      } else if (_liveLevels.isNotEmpty) {
        setState(_liveLevels.clear);
      }
      if (next.phase == VoiceRecordPhase.denied) {
        _showCenterToast(l.chatVoiceMicDenied);
      } else if (next.phase == VoiceRecordPhase.error) {
        _showCenterToast(l.chatVoiceRecordFailed);
      }
    });
    // Video-note phases: toasts on failure + pick up the 60s auto-stop clip.
    ref.listen<VnoteRecordState>(vnoteRecordControllerProvider, (prev, next) {
      if (next.phase == VnoteRecordPhase.denied) {
        _showCenterToast(l.chatVnoteDenied);
      } else if (next.phase == VnoteRecordPhase.error) {
        _showCenterToast(l.chatVoiceRecordFailed);
      }
      if (prev?.isRecording == true && next.phase == VnoteRecordPhase.idle) {
        final auto = ref
            .read(vnoteRecordControllerProvider.notifier)
            .takeAutoStopped();
        if (auto != null) widget.onVideoNote?.call(auto);
      }
    });
    final rec = ref.watch(voiceRecordControllerProvider);
    if (rec.isRecording) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: _recordingBar(context, l, rec),
        ),
      );
    }
    final vnoteRec = ref.watch(vnoteRecordControllerProvider);
    if (vnoteRec.isRecording) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: _vnoteRecordingBar(context, l, vnoteRec),
        ),
      );
    }
    // Desktop formatting hotkeys: Cmd/Ctrl + B / I / U (and E for inline code).
    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): () =>
            _wrap('**'),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
            _wrap('**'),
        const SingleActivator(LogicalKeyboardKey.keyI, meta: true): () =>
            _wrap('*'),
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
            _wrap('*'),
        const SingleActivator(LogicalKeyboardKey.keyU, meta: true): () =>
            _wrap('__'),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () =>
            _wrap('__'),
        const SingleActivator(LogicalKeyboardKey.keyE, meta: true): () =>
            _wrap('`'),
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
            _wrap('`'),
        // Telegram convention: Enter SENDS, Shift+Enter inserts a newline.
        // Both are explicit bindings: plain Enter is claimed by send, and
        // Flutter maps no default editing action to Shift+Enter, so the
        // newline must be inserted by hand. On mobile the IME return key is
        // a plain newline (textInputAction: newline) and sending is the
        // send button.
        const SingleActivator(LogicalKeyboardKey.enter): onSend,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): onSend,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true):
            _insertNewline,
        const SingleActivator(LogicalKeyboardKey.numpadEnter, shift: true):
            _insertNewline,
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _fieldHovered = true),
        onExit: (_) => setState(() => _fieldHovered = false),
        child: AnimatedBuilder(
          animation: focusNode,
          builder: (context, _) => TextField(
            controller: controller,
            focusNode: focusNode,
            minLines: 1,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: widget.hint,
              suffixIconConstraints: const BoxConstraints(
                minWidth: 88,
                maxWidth: 96,
              ),
              // Formatting + expression hub are part of the field's right
              // edge on every platform. The smiley opens by tap everywhere
              // and, after a short dwell, by hover on desktop.
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _formatButton(l),
                  MouseRegion(
                    onEnter: (_) => _scheduleExpressionHover(context),
                    onExit: (_) {
                      _expressionHoverTimer?.cancel();
                      if (!_expressionOpen) _expressionHoverArmed = true;
                    },
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 140),
                      opacity: _fieldHovered || focusNode.hasFocus ? 1 : 0.62,
                      child: IconButton(
                        key: const ValueKey('composer-expression-button'),
                        tooltip: l.chatEmojiTooltip,
                        icon: const Icon(Icons.emoji_emotions_outlined),
                        onPressed: () => _openExpressions(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Row(
          children: [
            if (widget.onAttachmentAction != null ||
                widget.onVoice != null ||
                widget.onVideoNote != null)
              _attachmentButton(l),
            Expanded(child: field),
            const SizedBox(width: 4),
            // Empty field → explicit video-note + voice controls. Any text
            // replaces BOTH with one send button, identically on touch/desktop.
            if (widget.onVoice != null)
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (_, value, child) => value.text.trim().isEmpty
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onVideoNote != null)
                            IconButton.filledTonal(
                              key: const ValueKey('composer-video-note'),
                              tooltip: l.chatVnoteTooltip,
                              onPressed: _startVnoteRecording,
                              icon: const Icon(Icons.videocam_outlined),
                            ),
                          _micButton(context),
                        ],
                      )
                    : IconButton.filled(
                        tooltip: l.chatSend,
                        onPressed: onSend,
                        icon: const Icon(Icons.send),
                      ),
              )
            else
              IconButton.filled(
                tooltip: l.chatSend,
                onPressed: onSend,
                icon: const Icon(Icons.send),
              ),
          ],
        ),
      ),
    );
  }

  Widget _formatButton(AppL10n l) => PopupMenuButton<String>(
    key: const ValueKey('composer-format-button'),
    padding: EdgeInsets.zero,
    icon: const Icon(Icons.text_format),
    tooltip: l.chatFormatTooltip,
    onSelected: (value) => value == '>' ? _prefixQuote() : _wrap(value),
    itemBuilder: (_) => [
      PopupMenuItem(
        value: '**',
        child: Text(
          l.chatFormatBold,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      PopupMenuItem(
        value: '*',
        child: Text(
          l.chatFormatItalic,
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      ),
      PopupMenuItem(
        value: '__',
        child: Text(
          l.chatFormatUnderline,
          style: const TextStyle(decoration: TextDecoration.underline),
        ),
      ),
      PopupMenuItem(
        value: '~~',
        child: Text(
          l.chatFormatStrike,
          style: const TextStyle(decoration: TextDecoration.lineThrough),
        ),
      ),
      PopupMenuItem(
        value: '`',
        child: Text(
          l.chatFormatCode,
          style: const TextStyle(fontFamily: 'monospace'),
        ),
      ),
      PopupMenuItem(value: '||', child: Text(l.chatFormatSpoiler)),
      PopupMenuItem(
        value: '>',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.format_quote, size: 18),
            const SizedBox(width: 8),
            Text(l.chatFormatQuote),
          ],
        ),
      ),
    ],
  );

  Widget _attachmentButton(AppL10n l) =>
      PopupMenuButton<ComposerAttachmentAction>(
        key: const ValueKey('composer-attachment-button'),
        icon: const Icon(Icons.attach_file),
        tooltip: l.chatAttachTooltip,
        onSelected: (action) async {
          switch (action) {
            case ComposerAttachmentAction.voice:
              await _startRecording();
            case ComposerAttachmentAction.videoNote:
              await _startVnoteRecording();
            case ComposerAttachmentAction.camera ||
                ComposerAttachmentAction.photo ||
                ComposerAttachmentAction.video ||
                ComposerAttachmentAction.file ||
                ComposerAttachmentAction.gif:
              await widget.onAttachmentAction?.call(action);
            case ComposerAttachmentAction.poll ||
                ComposerAttachmentAction.location:
              return;
          }
        },
        itemBuilder: (_) => [
          if (widget.onVoice != null)
            PopupMenuItem(
              value: ComposerAttachmentAction.voice,
              child: ListTile(
                leading: const Icon(Icons.mic_none),
                title: Text(l.chatVoiceTooltip),
              ),
            ),
          if (widget.onVideoNote != null)
            PopupMenuItem(
              value: ComposerAttachmentAction.videoNote,
              child: ListTile(
                leading: const Icon(Icons.video_camera_front_outlined),
                title: Text(l.chatVnoteTooltip),
              ),
            ),
          if (widget.onAttachmentAction != null) ...[
            PopupMenuItem(
              value: ComposerAttachmentAction.camera,
              child: ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: Text(l.composerCamera),
              ),
            ),
            PopupMenuItem(
              value: ComposerAttachmentAction.photo,
              child: ListTile(
                leading: const Icon(Icons.image_outlined),
                title: Text(l.composerUploadPhoto),
              ),
            ),
            PopupMenuItem(
              value: ComposerAttachmentAction.video,
              child: ListTile(
                leading: const Icon(Icons.video_file_outlined),
                title: Text(l.composerUploadVideo),
              ),
            ),
            PopupMenuItem(
              value: ComposerAttachmentAction.file,
              child: ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(l.composerUploadFile),
              ),
            ),
          ],
          PopupMenuItem(
            enabled: false,
            value: ComposerAttachmentAction.poll,
            child: ListTile(
              enabled: false,
              leading: const Icon(Icons.poll_outlined),
              title: Text(l.composerPoll),
              subtitle: Text(l.composerPlanned),
            ),
          ),
          PopupMenuItem(
            enabled: false,
            value: ComposerAttachmentAction.location,
            child: ListTile(
              enabled: false,
              leading: const Icon(Icons.location_on_outlined),
              title: Text(l.composerLocation),
              subtitle: Text(l.composerPlanned),
            ),
          ),
        ],
      );

  /// Tap-to-record mic button (hands-free): a tap starts recording; the
  /// recording bar's Send/Cancel then finish or discard — no hold required, so
  /// it works the same on desktop and mobile and the stop action is explicit.
  Widget _micButton(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton.filledTonal(
      key: const ValueKey('composer-voice-note'),
      tooltip: AppL10n.of(context).chatVoiceTooltip,
      onPressed: _startRecording,
      icon: const Icon(Icons.mic),
      color: scheme.onSecondaryContainer,
    );
  }

  /// While recording a video note: Cancel + live round self-preview + elapsed
  /// + Send. The preview repaints off the controller's frame notifier, not the
  /// widget state (12 fps repaints must not rebuild the whole composer).
  Widget _vnoteRecordingBar(
    BuildContext context,
    AppL10n l,
    VnoteRecordState rec,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final ctrl = ref.read(vnoteRecordControllerProvider.notifier);
    final elapsed = formatVoiceDuration(Duration(milliseconds: rec.elapsedMs));
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          tooltip: l.actionCancel,
          onPressed: ctrl.cancel,
        ),
        Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          child: Text(elapsed, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: Center(
            child: ClipOval(
              child: SizedBox(
                width: 96,
                height: 96,
                // Mirrored like a mirror: the vnote capture is always the
                // front-facing lens, and an unmirrored self-view reads as
                // "wrong way round" while framing. Recorded frames ship
                // unmirrored — this flip is preview-only.
                child: VnotePreview(
                  frameListenable: ctrl.preview,
                  mirror: true,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton.filled(
          onPressed: _sendVnoteRecording,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }

  /// While recording: Cancel (left) + record dot + elapsed + live waveform +
  /// a prominent Send (right) that stops and sends. Send is the clear "stop".
  Widget _recordingBar(BuildContext context, AppL10n l, VoiceRecordState rec) {
    final scheme = Theme.of(context).colorScheme;
    final elapsed = formatVoiceDuration(Duration(milliseconds: rec.elapsedMs));
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          tooltip: l.actionCancel,
          onPressed: () =>
              ref.read(voiceRecordControllerProvider.notifier).cancel(),
        ),
        // Pulsing record dot + elapsed time.
        Icon(Icons.fiber_manual_record, color: scheme.error, size: 14),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          child: Text(elapsed, style: Theme.of(context).textTheme.labelMedium),
        ),
        Expanded(
          child: SizedBox(
            height: 28,
            child: _liveLevels.isEmpty
                ? const SizedBox.shrink()
                : VoiceWaveform(
                    bars: _liveLevels,
                    playedColor: scheme.primary,
                    unplayedColor: scheme.primary,
                  ),
          ),
        ),
        const SizedBox(width: 4),
        // The explicit STOP + send.
        IconButton.filled(
          onPressed: _sendRecording,
          icon: const Icon(Icons.send),
        ),
      ],
    );
  }

  /// A brief, centered, translucent toast (an overlay, not a bottom snackbar so
  /// it never covers the composer). Auto-dismisses.
  void _showCenterToast(String msg) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    var removed = false;
    void remove() {
      if (removed) return;
      removed = true;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (ctx) => IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                msg,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 1600), remove);
  }
}

/// Edit-message dialog. A `StatefulWidget` so its [TextEditingController] is
/// disposed in [State.dispose] — which runs only once the dialog route is
/// fully removed (after the close transition), avoiding the disposed-controller
/// red screen when a teardown event forces a rebuild mid-animation.
class _EditMessageDialog extends StatefulWidget {
  const _EditMessageDialog({
    required this.initial,
    required this.title,
    required this.saveLabel,
    required this.cancelLabel,
  });

  final String initial;
  final String title;
  final String saveLabel;
  final String cancelLabel;

  @override
  State<_EditMessageDialog> createState() => _EditMessageDialogState();
}

class _EditMessageDialogState extends State<_EditMessageDialog> {
  late final TextEditingController _ctl = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        maxLines: null,
        textInputAction: TextInputAction.done,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctl.text),
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}

/// Edit an existing inline-custom-emoji message without degrading its images
/// to fallback glyphs. Sentinels remain one selectable character, so inserting
/// or deleting text naturally recalculates every sidecar offset on save.
class _EditCustomEmojiDialog extends StatefulWidget {
  const _EditCustomEmojiDialog({
    required this.message,
    required this.title,
    required this.saveLabel,
    required this.cancelLabel,
  });

  final Message message;
  final String title;
  final String saveLabel;
  final String cancelLabel;

  @override
  State<_EditCustomEmojiDialog> createState() => _EditCustomEmojiDialogState();
}

class _EditCustomEmojiDialogState extends State<_EditCustomEmojiDialog> {
  late final CustomEmojiEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = CustomEmojiEditingController()
      ..loadWireValue(widget.message.body, widget.message.customEmoji);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        maxLines: null,
        textInputAction: TextInputAction.done,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctl.toWireValue()),
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}
