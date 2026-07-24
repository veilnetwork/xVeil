import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:veil_flutter/veil_flutter.dart' as veil;

import '../../core/ids.dart';
import '../../domain/chat.dart';
import '../../state/app_controller.dart';
import '../../state/mention_identity.dart';
import '../../state/messaging.dart';
import '../../state/nickname_peers.dart';
import '../../state/providers.dart';
import 'custom_emoji_controller.dart';
import 'message_mentions.dart';

class MentionComposerRegion extends ConsumerStatefulWidget {
  const MentionComposerRegion({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.child,
    this.targets = const [],
    this.onChanged,
  });

  final CustomEmojiEditingController controller;
  final FocusNode focusNode;
  final Widget child;
  final Iterable<NodeId> targets;
  final VoidCallback? onChanged;

  @override
  ConsumerState<MentionComposerRegion> createState() =>
      _MentionComposerRegionState();
}

class _MentionChoice {
  const _MentionChoice({
    required this.nodeId,
    required this.label,
    this.localName,
    this.dhtName,
  });

  final NodeId nodeId;
  final String label;
  final String? localName;
  final String? dhtName;
}

class _MentionComposerRegionState extends ConsumerState<MentionComposerRegion> {
  ActiveMentionQuery? _active;
  Timer? _lookupDebounce;
  int _lookupGeneration = 0;
  bool _resolving = false;
  _MentionChoice? _remote;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _onControllerChanged();
  }

  @override
  void didUpdateWidget(MentionComposerRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _onControllerChanged();
    }
  }

  @override
  void dispose() {
    _lookupDebounce?.cancel();
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final next = activeMentionQuery(
      widget.controller.text,
      widget.controller.selection,
    );
    final old = _active;
    if (old?.start == next?.start &&
        old?.end == next?.end &&
        old?.query == next?.query) {
      return;
    }
    _lookupDebounce?.cancel();
    _lookupGeneration++;
    if (mounted) {
      setState(() {
        _active = next;
        _remote = null;
        _resolving = false;
      });
    } else {
      _active = next;
    }
    if (next != null) _scheduleDhtLookup(next.query);
  }

  void _scheduleDhtLookup(String raw) {
    if (raw.length < 3 || raw.length > 32) return;
    String normalized;
    try {
      normalized = veil.normalizeNickname(raw);
    } catch (_) {
      return;
    }
    final generation = _lookupGeneration;
    _lookupDebounce = Timer(const Duration(milliseconds: 320), () async {
      if (!mounted || generation != _lookupGeneration) return;
      setState(() => _resolving = true);
      try {
        final selfHex = await ref.read(messagingServiceProvider).savedSelfHex();
        final resolved = await veil.resolveNicknameAsync(
          selfNodeId: NodeId.fromHex(selfHex).bytes,
          name: normalized,
          timeoutMs: 4000,
        );
        if (!mounted || generation != _lookupGeneration) return;
        if (resolved == null) {
          setState(() => _resolving = false);
          return;
        }
        final nodeId = NodeId(resolved.ownerNodeId);
        await savePeerNickname(
          ref.read(storageProvider),
          nodeId.hex,
          normalized,
        );
        ref.invalidate(peerNicknameProvider(nodeId.hex));
        if (!mounted || generation != _lookupGeneration) return;
        setState(() {
          _remote = _MentionChoice(
            nodeId: nodeId,
            label: normalized,
            dhtName: normalized,
          );
          _resolving = false;
        });
      } catch (_) {
        if (mounted && generation == _lookupGeneration) {
          setState(() => _resolving = false);
        }
      }
    });
  }

  List<_MentionChoice> _choices() {
    final conversations =
        ref.watch(conversationsProvider).value ?? const <Conversation>[];
    final contacts = {
      for (final conversation in conversations)
        conversation.peer.nodeId.hex: conversation.peer,
    };
    final ids = <String>{
      for (final target in widget.targets) target.hex,
      ...contacts.keys,
      ...widget.controller.mentionNodeHexes,
    };
    final self = ref.watch(appControllerProvider).identity;
    if (self != null) ids.add(self.nodeId.hex);

    final choices = <String, _MentionChoice>{};
    final controllerLabels = <String, String>{};
    for (final hex in ids) {
      final nodeId = NodeId.fromHex(hex);
      final contact = contacts[hex];
      final localName = contact?.name?.trim();
      final identity = ref
          .watch(
            mentionIdentityProvider(
              MentionIdentityKey(
                hex,
                dhtHint: widget.controller.mentionDhtHint(hex),
              ),
            ),
          )
          .value;
      final binding = ref.watch(peerNicknameProvider(hex)).value;
      final dhtName =
          identity?.dhtName ??
          (binding != null && !binding.ownerChanged ? binding.name : null);
      final label = localName != null && localName.isNotEmpty
          ? localName
          : identity?.label ?? dhtName ?? nodeId.short;
      controllerLabels[hex] = label;
      choices[hex] = _MentionChoice(
        nodeId: nodeId,
        label: label,
        localName: localName,
        dhtName: dhtName,
      );
    }

    final remote = _remote;
    if (remote != null) {
      final existing = choices[remote.nodeId.hex];
      choices[remote.nodeId.hex] = existing == null
          ? remote
          : _MentionChoice(
              nodeId: existing.nodeId,
              label: existing.localName?.isNotEmpty == true
                  ? existing.localName!
                  : remote.label,
              localName: existing.localName,
              dhtName: remote.dhtName,
            );
    }

    final active = _active;
    if (active != null && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(active.query)) {
      final nodeId = NodeId.fromHex(active.query.toLowerCase());
      choices.putIfAbsent(
        nodeId.hex,
        () => _MentionChoice(nodeId: nodeId, label: nodeId.short),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.updateMentionLabels(controllerLabels);
    });

    final query = active?.query.trim().toLowerCase() ?? '';
    final filtered =
        choices.values.where((choice) {
          if (query.isEmpty) return true;
          return choice.label.toLowerCase().contains(query) ||
              (choice.localName?.toLowerCase().contains(query) ?? false) ||
              (choice.dhtName?.toLowerCase().contains(query) ?? false) ||
              choice.nodeId.hex.contains(query);
        }).toList()..sort((left, right) {
          final leftRank = left.localName?.isNotEmpty == true
              ? 0
              : left.dhtName != null
              ? 1
              : 2;
          final rightRank = right.localName?.isNotEmpty == true
              ? 0
              : right.dhtName != null
              ? 1
              : 2;
          final rank = leftRank.compareTo(rightRank);
          return rank != 0
              ? rank
              : left.label.toLowerCase().compareTo(right.label.toLowerCase());
        });
    return filtered.take(6).toList(growable: false);
  }

  void _select(_MentionChoice choice) {
    final active = _active;
    if (active == null) return;
    widget.controller.replaceRangeWithMention(
      active.start,
      active.end,
      choice.nodeId,
      label: choice.label,
      dhtName: choice.dhtName,
    );
    widget.onChanged?.call();
    widget.focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final resolvedChoices = _choices();
    final choices = active == null ? const <_MentionChoice>[] : resolvedChoices;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (active != null && (choices.isNotEmpty || _resolving))
          Container(
            key: const ValueKey('mention-suggestions'),
            constraints: const BoxConstraints(maxHeight: 272),
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 2),
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              elevation: 4,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_resolving) const LinearProgressIndicator(minHeight: 2),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: choices.length,
                      itemBuilder: (context, index) {
                        final choice = choices[index];
                        final publicDetail = choice.dhtName == null
                            ? choice.nodeId.short
                            : '@${choice.dhtName} · ${choice.nodeId.short}';
                        return ListTile(
                          key: ValueKey('mention-choice-${choice.nodeId.hex}'),
                          dense: true,
                          leading: const CircleAvatar(
                            radius: 17,
                            child: Icon(Icons.alternate_email, size: 18),
                          ),
                          title: Text(
                            '@${choice.label}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            publicDetail,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _select(choice),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        widget.child,
      ],
    );
  }
}
