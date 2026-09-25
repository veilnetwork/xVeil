import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import 'group_service_providers.dart';
import 'messaging_core.dart';
import 'messaging_providers.dart';

/// Past this much silence a linked device is worth offering to unlink: long
/// enough that a phone in a drawer over a holiday does not trip it, short
/// enough that a handset replaced months ago is obvious. The same month at
/// which the durable queue drops to probing it once a week.
const kDeviceAwayLong = Duration(days: 30);

/// Whether a device silent since [silentSince] should be offered for
/// unlinking at [now]. Unknown silence is never a reason: a device this one
/// has neither heard nor had anything queued for is not known to be gone.
bool suggestUnlinking({required DateTime? silentSince, required DateTime now}) =>
    silentSince != null && now.difference(silentSince) >= kDeviceAwayLong;

/// The linked devices THIS device may unlink and should be offered to: the
/// device group's own members — only the owner signs a revocation, and it is
/// the one whose control log lists them — other than this device, silent for
/// [kDeviceAwayLong] or longer.
///
/// Silence is what the durable queue measures (see
/// [MessagingService.silentSince]). A device proves itself only over a direct
/// session, so a sibling that has reached this one solely through the
/// mailbox for a month reads as silent too — which is why this is an offer the
/// person decides on, never an action taken for them.
Future<List<NodeId>> devicesToSuggestUnlinking({
  required GroupService groups,
  required MessagingService messaging,
  required DateTime now,
}) async {
  final gidHex = await groups.deviceGroupIdHex();
  if (gidHex == null) return const [];
  final state = await groups.stateOf(NodeId.fromHex(gidHex));
  if (state == null) return const [];
  final self = await groups.resolveMyDevice();
  final out = <NodeId>[];
  for (final member in state.members.values) {
    final device = member.nodeId;
    if (device == self || device == groups.selfId) continue;
    final since = await messaging.silentSince(device);
    if (suggestUnlinking(silentSince: since, now: now)) out.add(device);
  }
  out.sort((a, b) => a.hex.compareTo(b.hex));
  return out;
}

/// [devicesToSuggestUnlinking] for the settings entry that leads to the
/// devices screen, so the offer is seen without opening it.
final devicesToSuggestUnlinkingProvider =
    FutureProvider.autoDispose<List<NodeId>>((ref) async {
      final groups = ref.watch(groupServiceProvider);
      if (groups == null) return const [];
      try {
        return await devicesToSuggestUnlinking(
          groups: groups,
          messaging: ref.watch(messagingServiceProvider),
          now: DateTime.now(),
        );
      } on StateError {
        // A locked store: nothing to offer, not a failure.
        return const [];
      }
    });
