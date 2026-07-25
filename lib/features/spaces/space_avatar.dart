import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ids.dart';
import '../../domain/group.dart';
import '../../domain/group_policy.dart';
import '../../state/group_service_providers.dart';
import '../../state/messaging.dart' show messagingServiceProvider;
import '../../state/providers.dart';
import '../../state/thumbnail.dart';

/// Longest side of a stored Space avatar/cover. Matches the top inline rung
/// so any picked photo lands as a small shared PNG, not a full camera frame.
const int kSpaceProfileImageRawMax = 256 * 1024;

/// Pick one image, downscale it to a bounded PNG and register the bytes in
/// the membership-authorized shared content store. Returns the content id, or
/// null when the user cancelled / the file is not a decodable image.
Future<String?> pickAndRegisterSpaceProfileImage(
  WidgetRef ref, {
  required String name,
}) async {
  final picked = await FilePicker.pickFiles();
  final file = picked?.files.firstOrNull;
  if (file == null) return null;
  final bytes =
      file.bytes ??
      (file.path == null ? null : await File(file.path!).readAsBytes());
  if (bytes == null || bytes.isEmpty) return null;
  final scaled = await makeInlineImageB64(
    bytes,
    rawMax: kSpaceProfileImageRawMax,
  );
  if (scaled == null) return null;
  return ref
      .read(messagingServiceProvider)
      .registerGroupContent(base64Decode(scaled.b64), name: name);
}

/// Preferred fetch source for profile images when the manifest is not at
/// hand: the folded owner is always a member and (as the genesis author)
/// almost always holds the blob.
NodeId? spaceOwnerOf(GroupState state) {
  for (final member in state.members.values) {
    if (member.role == GroupRole.owner) return member.nodeId;
  }
  return null;
}

/// Round Space avatar resolved from the shared content store by id, with the
/// caller's fallback while bytes are absent. When the blob is not local yet,
/// one bounded membership-authorized fetch from the Space owner is attempted;
/// non-members simply keep the fallback (the content path stays the ACL
/// boundary — this widget never bypasses it).
class SpaceAvatarImage extends ConsumerStatefulWidget {
  const SpaceAvatarImage({
    super.key,
    required this.spaceId,
    required this.contentId,
    required this.owner,
    required this.radius,
    required this.fallback,
  });

  final NodeId spaceId;
  final String? contentId;
  final NodeId? owner;
  final double radius;
  final Widget fallback;

  @override
  ConsumerState<SpaceAvatarImage> createState() => _SpaceAvatarImageState();
}

class _SpaceAvatarImageState extends ConsumerState<SpaceAvatarImage> {
  Uint8List? _bytes;
  String? _loadedCid;
  bool _fetchAttempted = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SpaceAvatarImage old) {
    super.didUpdateWidget(old);
    if (old.contentId != widget.contentId) {
      _bytes = null;
      _loadedCid = null;
      _fetchAttempted = false;
      _load();
    }
  }

  Future<void> _load() async {
    final cid = widget.contentId;
    if (cid == null) return;
    final local = await ref.read(storageProvider).loadFile(cid);
    if (!mounted || cid != widget.contentId) return;
    if (local != null) {
      setState(() {
        _bytes = local;
        _loadedCid = cid;
      });
      return;
    }
    final owner = widget.owner;
    if (owner == null || _fetchAttempted) return;
    _fetchAttempted = true;
    final service = ref.read(groupServiceProvider);
    if (service == null) return;
    try {
      if (await service.fetchGroupContent(widget.spaceId, cid, owner)) {
        final fetched = await ref.read(storageProvider).loadFile(cid);
        if (!mounted || cid != widget.contentId || fetched == null) return;
        setState(() {
          _bytes = fetched;
          _loadedCid = cid;
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (widget.contentId == null ||
        bytes == null ||
        _loadedCid != widget.contentId) {
      return CircleAvatar(radius: widget.radius, child: widget.fallback);
    }
    return CircleAvatar(
      radius: widget.radius,
      foregroundImage: MemoryImage(bytes),
      child: widget.fallback,
    );
  }
}
