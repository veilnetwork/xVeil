import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/profile_avatar.dart';
import '../../l10n/app_localizations.dart';
import '../../state/device_settings_sync.dart';
import '../../state/identity_guard.dart';
import '../../state/messaging.dart';
import '../../state/profile_avatar.dart';
import '../../state/self_presentation.dart';

class IdentityAvatar extends ConsumerWidget {
  const IdentityAvatar({
    super.key,
    this.peerHex = '',
    this.radius = 24,
    required this.fallback,
  });
  final String peerHex;
  final double radius;
  final Widget fallback;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref
        .watch(profileAvatarProvider(peerHex))
        .asData
        ?.value
        ?.bytes;
    return CircleAvatar(
      radius: radius,
      backgroundImage: bytes == null ? null : MemoryImage(bytes),
      child: bytes == null ? fallback : null,
    );
  }
}

class EditIdentityAvatar extends ConsumerStatefulWidget {
  const EditIdentityAvatar({super.key});
  @override
  ConsumerState<EditIdentityAvatar> createState() => _EditIdentityAvatarState();
}

class _EditIdentityAvatarState extends ConsumerState<EditIdentityAvatar> {
  bool _busy = false;
  Future<void> _change(bool remove) async {
    if (_busy) return;
    final lease = ref.leaseIdentity();
    final messaging = ref.read(messagingServiceProvider);
    final hub = ref.read(deviceSettingsSyncHubProvider);
    final l = AppL10n.of(context);
    setState(() => _busy = true);
    try {
      Uint8List? avatar;
      if (!remove) {
        final result = await FilePicker.pickFiles(type: FileType.image);
        if (!mounted || !ref.holdsIdentity(lease)) return;
        final picked = result?.files.firstOrNull;
        if (picked == null) return;
        // Enforce the cap using the actual file too; provider size can be stale.
        const cap = 8 * 1024 * 1024;
        if (picked.size > cap) throw const FormatException();
        final file = picked.path == null ? null : File(picked.path!);
        if (file != null && await file.length() > cap) {
          throw const FormatException();
        }
        final source =
            picked.bytes ??
            (file == null
                ? null
                : await file
                      .openRead(0, cap + 1)
                      .fold<BytesBuilder>(
                        BytesBuilder(),
                        (b, part) => b..add(part),
                      )
                      .then((b) => b.takeBytes()));
        if (source == null || source.isEmpty || source.length > cap) {
          throw const FormatException();
        }
        final buffer = await ui.ImmutableBuffer.fromUint8List(source);
        try {
          final descriptor = await ui.ImageDescriptor.encoded(buffer);
          try {
            if (descriptor.width <= 0 ||
                descriptor.height <= 0 ||
                descriptor.width * descriptor.height > 40000000) {
              throw const FormatException();
            }
            final scale =
                128 /
                (descriptor.width > descriptor.height
                    ? descriptor.width
                    : descriptor.height);
            final codec = await descriptor.instantiateCodec(
              targetWidth: scale < 1
                  ? (descriptor.width * scale).round().clamp(1, 128)
                  : descriptor.width,
              targetHeight: scale < 1
                  ? (descriptor.height * scale).round().clamp(1, 128)
                  : descriptor.height,
            );
            try {
              final frame = await codec.getNextFrame();
              try {
                final png = await frame.image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                if (png == null) throw const FormatException();
                avatar = await compute(
                  encodeAvatarPixels,
                  png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
                );
              } finally {
                frame.image.dispose();
              }
            } finally {
              codec.dispose();
            }
          } finally {
            descriptor.dispose();
          }
        } finally {
          buffer.dispose();
        }
        if (avatar == null) throw const FormatException();
      }
      if (!mounted || !ref.holdsIdentity(lease)) return;
      final raw = await messaging.setSelfAvatar(avatar);
      if (!mounted || !ref.holdsIdentity(lease)) return;
      hub.notifyLocalSet(kSyncProfileAvatar, raw);
      await messaging.announceSelfAvatar();
    } catch (_) {
      if (mounted && ref.holdsIdentity(lease)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.avatarFailed)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final presentation = ref.watch(selfPresentationProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const IdentityAvatar(
            radius: 28,
            fallback: Icon(Icons.person_outline),
          ),
          title: Text(presentation.label),
          subtitle: Text(l.avatarSharingHint),
        ),
        if (presentation.nodeId != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(presentation.nodeId!),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            children: [
              TextButton.icon(
                onPressed: _busy ? null : () => _change(false),
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(l.avatarChoose),
              ),
              TextButton(
                onPressed: _busy ? null : () => _change(true),
                child: Text(l.avatarRemove),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
