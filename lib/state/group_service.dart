// Group service (groups epic, phase 0, brick 3): create groups, sign + append
// control-log ops and messages, persist everything in the deniable store, and
// expose the folded state + validated message list. No wire/DHT yet — this is
// the local substance a peer-sync brick will later drive.
//
// Persistence (settings JSON in the deniable store):
//   'groups.index'      -> ["<groupId hex>", ...]
//   'group:<id>'        -> manifest + control/messages/posts/reactions/epochs
//
// The identity crypto (native ed25519) sits behind an injectable [GroupSigner]
// so the whole service is unit-tested with a fake — the real signer wraps
// group_crypto + the app's deniable identity TOML.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:veil_flutter/veil_ffi.dart' as veil;

import '../core/ids.dart';
import '../core/log.dart';
import '../domain/chat.dart'
    show
        ContactStatus,
        NotificationMuteMode,
        NotificationMutePolicy,
        kMuteForever;
import '../domain/call_signal.dart';
import '../domain/device_sync.dart';
import '../domain/device_link.dart';
import '../domain/group.dart';
import '../domain/group_call.dart';
import '../domain/group_content.dart';
import '../domain/group_epoch.dart';
import '../domain/group_message.dart';
import '../domain/group_payload.dart';
import '../domain/group_policy.dart';
import '../domain/group_reaction.dart';
import '../domain/inline_custom_emoji.dart';
import '../domain/message_mention.dart';
import '../domain/space_abuse_report.dart';
import '../domain/space_channel.dart';
import '../domain/space_discovery.dart';
import '../domain/space_discovery_carrier.dart';
import '../domain/space_discovery_search.dart';
import '../domain/space_invite.dart';
import '../domain/space_join_request.dart';
import '../domain/space_lifecycle.dart';
import '../domain/space_membership.dart';
import '../domain/space_moderation.dart';
import '../domain/space_post.dart';
import '../domain/space_public_discussion.dart';
import '../domain/space_public_feed.dart';
import '../domain/space_public_feed_transport.dart';
import '../domain/space_policy_audit.dart';
import '../domain/space_recommendation.dart';
import '../domain/space_retention.dart';
import '../domain/space_rules.dart';
import '../data/transport/bootstrap_invite.dart';
import '../data/node/space_discovery_transport.dart';
import '../data/storage/storage.dart';
import 'group_crypto.dart';
import 'group_epoch_service.dart';
import 'space_observability.dart';

part 'group_service_types.dart';
part 'group_service_signers.dart';

bool _listEquals<T>(List<T>? left, List<T>? right) {
  if (identical(left, right)) return true;
  if (left == null || right == null || left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

final RegExp _channelKeyIdPattern = RegExp(r'^[0-9a-f]{64}:[1-9][0-9]*$');
final RegExp _spacePostIdPattern = RegExp(r'^[0-9a-f]{64}:[0-9]+$');
final RegExp _scheduledSpacePostIdPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _sharedContentIdPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _spaceReceiptPattern = RegExp(r'^[0-9a-f]{64}$');

/// A newly unreachable shared blob must survive at least one full day and two
/// independent scans. This is a storage-safety grace period, not a user-facing
/// retention/mute interval; the existing 7/30/90/365-day and notification
/// presets remain byte-for-byte unchanged.
const Duration kSharedContentGcGracePeriod = Duration(hours: 24);

String _channelKeyId(NodeId channelId, int epoch) => '${channelId.hex}:$epoch';

bool _validChannelKeyId(String value) {
  if (!_channelKeyIdPattern.hasMatch(value)) return false;
  final separator = value.lastIndexOf(':');
  final epoch = int.tryParse(value.substring(separator + 1));
  return epoch != null && epoch > 0 && epoch <= 0xffffffff;
}

/// SHA-256 here hashes only public manifests and encrypted credential blobs.
/// Keep this protocol primitive in the pure-Dart group core so ordinary group
/// and adoption tests do not require loading the native identity library.
Uint8List _sha256(List<int> bytes) =>
    Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

int _compareXorDistance(NodeId origin, NodeId left, NodeId right) {
  for (var i = 0; i < origin.bytes.length; i++) {
    final l = origin.bytes[i] ^ left.bytes[i];
    final r = origin.bytes[i] ^ right.bytes[i];
    if (l != r) return l.compareTo(r);
  }
  return left.hex.compareTo(right.hex);
}

/// Deterministically selects the [k] node ids closest to [self] by XOR
/// distance. Duplicate ids and [self] are ignored; callers do not need to
/// preserve any particular membership iteration order.
List<NodeId> nearestGroupNodesByXor(
  NodeId self,
  Iterable<NodeId> members, {
  int k = GroupService.kGroupSyncNeighbors,
}) {
  if (k <= 0) return const [];
  final unique = <String, NodeId>{
    for (final member in members)
      if (member != self) member.hex: member,
  }.values.toList();
  unique.sort((left, right) => _compareXorDistance(self, left, right));
  return unique.length <= k ? unique : unique.sublist(0, k);
}

/// Flutter-free change signal used by both the GUI provider and headless host.
/// It intentionally mirrors the tiny `ValueNotifier<int>` surface the group
/// list needs without pulling the Flutter engine into the group core.
final class GroupChangeSignal {
  int _value = 0;
  bool _disposed = false;
  final List<void Function()> _listeners = <void Function()>[];
  final StreamController<int> _controller = StreamController<int>.broadcast(
    sync: true,
  );

  int get value => _value;
  Stream<int> get stream => _controller.stream;

  set value(int next) {
    if (_disposed || next == _value) return;
    _value = next;
    _controller.add(next);
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    if (_disposed) return;
    if (!_listeners.contains(listener)) _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    unawaited(_controller.close());
  }
}

/// One group's stored data.
class GroupBundle {
  GroupBundle({
    required this.manifest,
    required this.control,
    required this.messages,
    this.posts = const [],
    this.reactions = const [],
    this.publicComments = const [],
    this.publicReactions = const [],
    this.epochEnvelopes = const [],
    this.localEpochKeys = const {},
    this.channelEpochEnvelopes = const [],
    this.localChannelEpochKeys = const {},
    this.sovereignBundle,
    this.retentionCuts = const {},
  });
  final GroupManifest manifest;
  final List<ControlEntry> control;
  final List<GroupMessage> messages;
  final List<SpacePost> posts;
  final List<GroupReaction> reactions;
  final List<SpacePublicComment> publicComments;
  final List<SpacePublicReaction> publicReactions;

  /// Recipient-specific ML-KEM records. A creator keeps every record it
  /// minted so direct fanout can be tailored per recipient; a receiver stores
  /// only records addressed to itself. These are sealed and safe to persist.
  final List<GroupEpochRecipientEnvelope> epochEnvelopes;

  /// Decrypted epoch keys live only in the deniable hidden-volume bundle.
  /// They are deliberately omitted from every wire snapshot/delta.
  final Map<int, Uint8List> localEpochKeys;

  /// Same recipient-specific ML-KEM primitive, scoped by channel id rather
  /// than Space id. Unauthorized members never receive one of these records.
  final List<GroupEpochRecipientEnvelope> channelEpochEnvelopes;

  /// `<channelId hex>:<epoch>` -> decrypted 32-byte key, hidden-volume only.
  final Map<String, Uint8List> localChannelEpochKeys;
  final Uint8List? sovereignBundle;

  /// `retentionCutKey(scope, author)` -> physically deleted chain prefix.
  /// Local fold state, never a signed wire object (see [SpaceRetentionCut]).
  final Map<String, SpaceRetentionCut> retentionCuts;

  GroupBundle copyWith({
    GroupManifest? manifest,
    List<ControlEntry>? control,
    List<GroupMessage>? messages,
    List<SpacePost>? posts,
    List<GroupReaction>? reactions,
    List<SpacePublicComment>? publicComments,
    List<SpacePublicReaction>? publicReactions,
    List<GroupEpochRecipientEnvelope>? epochEnvelopes,
    Map<int, Uint8List>? localEpochKeys,
    List<GroupEpochRecipientEnvelope>? channelEpochEnvelopes,
    Map<String, Uint8List>? localChannelEpochKeys,
    Uint8List? sovereignBundle,
    Map<String, SpaceRetentionCut>? retentionCuts,
  }) => GroupBundle(
    manifest: manifest ?? this.manifest,
    control: control ?? this.control,
    messages: messages ?? this.messages,
    posts: posts ?? this.posts,
    reactions: reactions ?? this.reactions,
    publicComments: publicComments ?? this.publicComments,
    publicReactions: publicReactions ?? this.publicReactions,
    epochEnvelopes: epochEnvelopes ?? this.epochEnvelopes,
    localEpochKeys: localEpochKeys ?? this.localEpochKeys,
    channelEpochEnvelopes: channelEpochEnvelopes ?? this.channelEpochEnvelopes,
    localChannelEpochKeys: localChannelEpochKeys ?? this.localChannelEpochKeys,
    sovereignBundle: sovereignBundle ?? this.sovereignBundle,
    retentionCuts: retentionCuts ?? this.retentionCuts,
  );
}

class GroupService {
  GroupService(
    this._storage,
    this._signer, {
    this._send,
    this.sendSpaceInvite,
    this.sendSpaceInviteDecision,
    this.sendSpaceJoinRequest,
    this.sendSpaceJoinDecision,
    this.sendSpaceModerationAppeal,
    this.sendSpaceModerationAppealDecision,
    this.sendSpaceAbuseReport,
    this.sendSpaceAbuseReportDecision,
    this.sendSpaceRecommendation,
    this.revokeSpaceRecommendation,
    this._epochService,
    this.ourCertVersion = 1,
    this.sendContentRequest,
    this.sendContentReceipt,
    this.sendPublicFeedRequest,
    this.sendPublicFeedChunk,
    this.sendPublicMediaGrantRequest,
    this.sendGroupCallFrame,
    this.grantContentServe,
    this.grantPublicContentServe,
    this.startContentPull,
    this.startContentPullFromAny,
    this.startPublicContentPullFromAny,
    this._activePeers,
    this._spaceDiscoveryTransport,
    this.contentRequestFanoutTimeout = const Duration(seconds: 8),
    this.contentGrantDelay = const Duration(seconds: 4),
    SpaceObservability? observability,
  }) : _observability = observability ?? SpaceObservability();
  final Storage _storage;
  final GroupSigner _signer;
  final GroupSnapshotSender? _send;
  final SpaceInviteSender? sendSpaceInvite;
  final SpaceInviteDecisionSender? sendSpaceInviteDecision;
  final SpaceJoinRequestSender? sendSpaceJoinRequest;
  final SpaceJoinDecisionSender? sendSpaceJoinDecision;
  final SpaceModerationAppealSender? sendSpaceModerationAppeal;
  final SpaceModerationAppealDecisionSender? sendSpaceModerationAppealDecision;
  final SpaceAbuseReportSender? sendSpaceAbuseReport;
  final SpaceAbuseReportDecisionSender? sendSpaceAbuseReportDecision;
  final SpaceRecommendationSender? sendSpaceRecommendation;
  final SpaceRecommendationRevoker? revokeSpaceRecommendation;
  final GroupEpochService? _epochService;
  final SpaceObservability _observability;
  final ActivePeerSnapshotReader? _activePeers;
  final SpaceDiscoveryTransport? _spaceDiscoveryTransport;
  final int ourCertVersion;

  /// Ships a signed content-fetch request to the holder (wire layer).
  final Future<void> Function(NodeId holder, String requestJson)?
  sendContentRequest;

  /// Ships a verified-store receipt live-only to the exact source. The wire
  /// layer must not outbox, stash or ACK this diagnostics-only frame.
  final Future<void> Function(NodeId holder, String receiptJson)?
  sendContentReceipt;

  /// Live-only request/response path for exact owner-committed public feed
  /// objects. Neither direction enters chat history or the durable outbox.
  final SpacePublicFeedRequestSender? sendPublicFeedRequest;
  final SpacePublicFeedChunkSender? sendPublicFeedChunk;

  /// Live-only public-media request. The messaging layer scopes the incoming
  /// content response to the exact holder/CID and never persists this frame.
  final SpacePublicMediaGrantRequestSender? sendPublicMediaGrantRequest;

  /// Ships a short-lived encrypted call-control frame to one current member.
  final GroupCallFrameSender? sendGroupCallFrame;

  /// Opens the serve gate for an authorized member (wire layer grant).
  final void Function(NodeId peer, String cid)? grantContentServe;

  /// Opens the same exact content-stream gate for a verified public reference,
  /// with a shorter public-request TTL chosen by the messaging host.
  final void Function(NodeId peer, String cid)? grantPublicContentServe;

  /// Starts the standard content pull of [cid] from a holder (wire layer).
  final Future<void> Function(NodeId holder, String cid)? startContentPull;

  /// Starts a membership-scoped pull from every current candidate member.
  /// The messaging layer tries holders until one actually has the verified
  /// blob; no persistent/read-receipt holder advertisement is created.
  final Future<void> Function(List<NodeId> holders, String cid)?
  startContentPullFromAny;

  /// Starts a public-projection-scoped pull with the shorter public grant TTL.
  final Future<void> Function(List<NodeId> holders, String cid)?
  startPublicContentPullFromAny;

  /// Bounds only the foreground wait for durable request fanout. The durable
  /// sends keep running after this deadline; an offline member must not delay
  /// a reachable seeder indefinitely.
  final Duration contentRequestFanoutTimeout;

  /// Gives durable membership requests time to reach candidate holders before
  /// the first stream open. Injectable so closed-loop tests need no wall clock.
  final Duration contentGrantDelay;

  /// Extra content ids a higher layer vouches for inside one group, on top of
  /// what a visible message attachment or post media already references.
  ///
  /// The rule this widens is deliberate: a member may pull only what something
  /// it can see points at, so a guessed id buys nothing. Some content is real
  /// and legitimately referenced, but by a row whose MEANING lives above this
  /// layer — a personal-cloud row naming its preview, for instance. Rather
  /// than teach group code to parse those payloads, the owning layer says
  /// which ids its own rows vouch for and this layer keeps the same rule.
  ///
  /// Consulted ONLY where the reference namespace is the ordinary one. A
  /// protected channel's namespace is never widened: it is exactly the set of
  /// attachments in that channel, and a voucher living outside the channel has
  /// no standing to add to it.
  Future<Set<String>> Function(NodeId groupId)? vouchedContent;

  Future<Set<String>> _vouched(NodeId groupId) async {
    final resolve = vouchedContent;
    if (resolve == null) return const <String>{};
    try {
      return await resolve(groupId);
    } catch (_) {
      // A voucher that cannot answer must not deny the ordinary references.
      return const <String>{};
    }
  }

  /// Bumped on every persisted mutation (local op/post OR an ingested
  /// snapshot) so open group screens re-fetch. Cheap: the UI reads on change.
  final GroupChangeSignal changes = GroupChangeSignal();

  /// A privacy-sensitive subset of [changes]. The merged Feed uses this to
  /// discard its last rendered snapshot before recalculating access, instead
  /// of briefly retaining content after a local block, leave, or remote ban.
  final GroupChangeSignal feedAccessChanges = GroupChangeSignal();
  final Map<String, int> _contactAccessGenerations = <String, int>{};
  static const Duration _spaceReceiptTtl = Duration(hours: 24);
  static const int _kMaxPendingSpaceReceipts = 2048;
  static const int _kMaxStalledSpaceReceipts = 2048;
  static const int _kMaxSpaceHolderProofs = 4096;
  static const int _kMaxPendingContentReceipts = 2048;
  static const int _kMaxOutboundContentRequests = 2048;
  static const int _kMaxContentHolderProofs = 8192;
  static const int _kMaxPendingPublicFeedObjects = 32;
  static const int _kPublicFeedServeRequestsPerWindow = 64;
  static const int _kMaxPublicFeedServeQuotaIdentities = 4096;
  static const int _kPublicMediaServeRequestsPerWindow = 128;
  static const int _kMaxPublicMediaServeQuotaIdentities = 4096;
  static const int _kMaxSeenPublicMediaRequests = 8192;
  static const int _kPublicMediaHolderFanout = 8;
  static const int _kMaxDurablePublicFeedPackages = 64;
  static const int _kMaxPublicSubscriptions = 4096;
  static const int _kPublicSubscriptionRefreshBatch = 16;
  static const int _kPublicSubscriptionIndexMaxBytes = 512 * 1024;
  static const String _publicFeedCacheIndexSetting =
      'space.public-feed-cache.index.v1';
  static const String _publicSubscriptionIndexFileId =
      'space.public-subscriptions.index.v1';
  final Map<String, _PendingSpaceReceipt> _pendingSpaceReceipts =
      <String, _PendingSpaceReceipt>{};
  final Map<String, _StalledSpaceReceipt> _stalledSpaceReceipts =
      <String, _StalledSpaceReceipt>{};
  final Map<String, _SpaceHolderProof> _spaceHolderProofs =
      <String, _SpaceHolderProof>{};
  final Map<String, _PendingContentReceipt> _pendingContentReceipts =
      <String, _PendingContentReceipt>{};
  final Map<String, _OutboundContentRequest> _outboundContentRequests =
      <String, _OutboundContentRequest>{};
  final Map<String, _ContentHolderProof> _contentHolderProofs =
      <String, _ContentHolderProof>{};
  final Map<String, _PendingPublicFeedObject> _pendingPublicFeedObjects =
      <String, _PendingPublicFeedObject>{};
  final Map<String, ({int windowStartedAtMs, int requests})>
  _publicFeedServeQuotas = <String, ({int windowStartedAtMs, int requests})>{};
  final Map<String, ({int windowStartedAtMs, int requests})>
  _publicMediaServeQuotas = <String, ({int windowStartedAtMs, int requests})>{};
  final Map<String, int> _seenPublicMediaRequests = <String, int>{};
  static const String _contentGcMarksKey = 'content.gc.marks.v1';
  Timer? _spaceDeletionMaintenanceTimer;
  bool _spaceDeletionMaintenanceRunning = false;
  Timer? _scheduledSpacePostTimer;
  Timer? _spaceDiscoveryPublishTimer;
  Timer? _spaceDiscoveryNudgeTimer;
  bool _spaceDiscoveryPublishRunning = false;
  bool _spaceDiscoveryPublishWakeRequested = false;
  bool _spaceDiscoveryChangesBound = false;
  final Map<String, ({String descriptorHash, int publishedAtMs})>
  _publishedPublicSpaceDescriptors =
      <String, ({String descriptorHash, int publishedAtMs})>{};
  final Map<
    String,
    ({
      SpacePublicDescriptor descriptor,
      SpacePublicFeedProjection feed,
      int retainedUntilMs,
    })
  >
  _verifiedPublicSpaceFeeds =
      <
        String,
        ({
          SpacePublicDescriptor descriptor,
          SpacePublicFeedProjection feed,
          int retainedUntilMs,
        })
      >{};
  final Map<String, SpacePublicSubscriptionSnapshot>
  _publicSubscriptionSnapshots = <String, SpacePublicSubscriptionSnapshot>{};
  Future<void> _publicFeedCacheMutationTail = Future<void>.value();
  int _publicSubscriptionRefreshCursor = 0;
  bool _scheduledSpacePostMaintenanceStarted = false;
  bool _scheduledSpacePostMaintenanceRunning = false;
  bool _scheduledSpacePostWakeRequested = false;
  int _scheduledSpacePostWakeGeneration = 0;
  bool _disposed = false;

  /// Our own node id — the composer uses it to align outgoing bubbles.
  NodeId get selfId => _signer.selfId;

  int _spaceReceiptNowMs() => DateTime.now().millisecondsSinceEpoch;

  String _spaceHolderProofKey(NodeId spaceId, NodeId peer) =>
      '${spaceId.hex}:${peer.hex}';

  String _pendingContentReceiptKey(NodeId requester, String nonce) =>
      '${requester.hex}:$nonce';

  String _outboundContentRequestKey(
    NodeId spaceId,
    String contentId,
    NodeId holder,
  ) => '${spaceId.hex}:$contentId:${holder.hex}';

  String _contentHolderProofKey(
    NodeId spaceId,
    String contentId,
    NodeId peer,
  ) => '${spaceId.hex}:$contentId:${peer.hex}';

  void _purgeSpaceReceiptState() {
    final nowMs = _spaceReceiptNowMs();
    final cutoff = nowMs - _spaceReceiptTtl.inMilliseconds;
    final contentRequestCutoff =
        nowMs - kGroupContentRequestWindow.inMilliseconds;
    final expiredReceipts = [
      for (final entry in _pendingSpaceReceipts.entries)
        if (entry.value.createdAtMs < cutoff) entry.key,
    ];
    for (final token in expiredReceipts) {
      _pendingSpaceReceipts.remove(token)?.elapsed.stop();
    }
    _stalledSpaceReceipts.removeWhere((_, value) => value.createdAtMs < cutoff);
    final expiredProofs = [
      for (final entry in _spaceHolderProofs.entries)
        if (entry.value.confirmedAtMs < cutoff) entry.key,
    ];
    for (final key in expiredProofs) {
      _spaceHolderProofs.remove(key);
    }
    final expiredContentReceipts = [
      for (final entry in _pendingContentReceipts.entries)
        if (entry.value.createdAtMs < contentRequestCutoff) entry.key,
    ];
    for (final key in expiredContentReceipts) {
      _pendingContentReceipts.remove(key)?.elapsed.stop();
    }
    _outboundContentRequests.removeWhere(
      (_, value) => value.createdAtMs < contentRequestCutoff,
    );
    _contentHolderProofs.removeWhere(
      (_, value) => value.confirmedAtMs < cutoff,
    );
  }

  void _rememberContentHolderProof(
    NodeId spaceId,
    String contentId,
    NodeId peer,
  ) {
    final key = _contentHolderProofKey(spaceId, contentId, peer);
    while (_contentHolderProofs.length >= _kMaxContentHolderProofs &&
        !_contentHolderProofs.containsKey(key)) {
      _contentHolderProofs.remove(_contentHolderProofs.keys.first);
    }
    _contentHolderProofs[key] = _ContentHolderProof(
      spaceId: spaceId,
      contentId: contentId,
      peer: peer,
      confirmedAtMs: _spaceReceiptNowMs(),
    );
  }

  String? _beginSpaceReceipt(
    GroupBundle bundle,
    NodeId peer, {
    String? repairFingerprint,
  }) {
    if (!bundle.manifest.isSpace) return null;
    _purgeSpaceReceiptState();
    while (_pendingSpaceReceipts.length >= _kMaxPendingSpaceReceipts) {
      _pendingSpaceReceipts
          .remove(_pendingSpaceReceipts.keys.first)
          ?.elapsed
          .stop();
    }
    final random = Random.secure();
    String token;
    do {
      token = List<int>.generate(
        32,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    } while (_pendingSpaceReceipts.containsKey(token));
    _pendingSpaceReceipts[token] = _PendingSpaceReceipt(
      spaceId: bundle.manifest.groupId,
      peer: peer,
      createdAtMs: _spaceReceiptNowMs(),
      repairFingerprint: repairFingerprint,
    );
    return token;
  }

  void _cancelSpaceReceipt(String? token) {
    if (token == null) return;
    _pendingSpaceReceipts.remove(token)?.elapsed.stop();
  }

  Object? _canonicalSpaceFrontierValue(Object? value) {
    if (value is List) {
      return [for (final item in value) _canonicalSpaceFrontierValue(item)];
    }
    if (value is Map) {
      final keys = value.keys.whereType<String>().toList()..sort();
      return {
        for (final key in keys) key: _canonicalSpaceFrontierValue(value[key]),
      };
    }
    return value;
  }

  Future<String?> _spaceSyncFrontier(
    NodeId spaceId, {
    GroupBundle? bundle,
  }) async {
    final loaded = bundle ?? await load(spaceId);
    if (loaded == null || loaded.manifest.groupId != spaceId) return null;
    final request = _buildGroupSyncRequest(loaded);
    final vector = Map<String, dynamic>.of(request)
      ..remove('sreq')
      ..remove('gid')
      ..remove('rack');
    return crypto.sha256
        .convert(utf8.encode(jsonEncode(_canonicalSpaceFrontierValue(vector))))
        .toString();
  }

  Future<_AcceptedSpaceReceipt?> _acceptSpaceReceipt(
    NodeId peer,
    GroupBundle bundle,
    Object? value, {
    required bool caughtUp,
  }) async {
    final spaceId = bundle.manifest.groupId;
    if (value == null) return null;
    if (value is! String || !_spaceReceiptPattern.hasMatch(value)) {
      _observeSpace(
        SpaceObservationType.p2pReceipt,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.invalidInput,
      );
      return null;
    }
    _purgeSpaceReceiptState();
    final pending = _pendingSpaceReceipts[value];
    final stalled = _stalledSpaceReceipts[value];
    if (pending == null &&
        stalled != null &&
        stalled.spaceId == spaceId &&
        stalled.peer == peer) {
      return _AcceptedSpaceReceipt(
        repairFingerprint: stalled.repairFingerprint,
      );
    }
    if (pending == null || pending.spaceId != spaceId || pending.peer != peer) {
      _observeSpace(
        SpaceObservationType.p2pReceipt,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.invalidState,
      );
      return null;
    }
    _pendingSpaceReceipts.remove(value);
    pending.elapsed.stop();
    _observeSpace(
      SpaceObservationType.p2pReceipt,
      SpaceObservationOutcome.succeeded,
      duration: pending.elapsed.elapsed,
    );

    final proofKey = _spaceHolderProofKey(spaceId, peer);
    if (!caughtUp) {
      _spaceHolderProofs.remove(proofKey);
      return _AcceptedSpaceReceipt(
        repairFingerprint: pending.repairFingerprint,
      );
    }
    final frontier = await _spaceSyncFrontier(spaceId, bundle: bundle);
    if (frontier == null) {
      return _AcceptedSpaceReceipt(
        repairFingerprint: pending.repairFingerprint,
      );
    }
    while (_spaceHolderProofs.length >= _kMaxSpaceHolderProofs &&
        !_spaceHolderProofs.containsKey(proofKey)) {
      _spaceHolderProofs.remove(_spaceHolderProofs.keys.first);
    }
    _spaceHolderProofs[proofKey] = _SpaceHolderProof(
      spaceId: spaceId,
      peer: peer,
      frontier: frontier,
      confirmedAtMs: _spaceReceiptNowMs(),
    );
    return _AcceptedSpaceReceipt(repairFingerprint: pending.repairFingerprint);
  }

  void _rememberStalledSpaceReceipt(
    String token,
    NodeId spaceId,
    NodeId peer,
    String repairFingerprint,
  ) {
    while (_stalledSpaceReceipts.length >= _kMaxStalledSpaceReceipts &&
        !_stalledSpaceReceipts.containsKey(token)) {
      _stalledSpaceReceipts.remove(_stalledSpaceReceipts.keys.first);
    }
    _stalledSpaceReceipts[token] = _StalledSpaceReceipt(
      spaceId: spaceId,
      peer: peer,
      repairFingerprint: repairFingerprint,
      createdAtMs: _spaceReceiptNowMs(),
    );
  }

  Future<void> _acknowledgeSpaceReceipt(NodeId peer, Map wire) async {
    final token = wire['rcpt'];
    if (token is! String || !_spaceReceiptPattern.hasMatch(token)) return;
    final manifest = GroupManifest.fromJson(wire['m']);
    if (manifest == null || !manifest.isSpace) return;
    final bundle = await load(manifest.groupId);
    if (bundle == null) return;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final acl = SpaceAcl(state);
    if (!acl.allows(peer, SpacePermission.distributeContent) ||
        !acl.allows(_signer.selfId, SpacePermission.distributeContent)) {
      return;
    }
    final request = _buildGroupSyncRequest(bundle);
    request['rack'] = token;
    final send = _send;
    if (send == null) {
      _observeSpace(
        SpaceObservationType.p2pReceipt,
        SpaceObservationOutcome.noOp,
        reason: SpaceObservationReason.transportUnavailable,
      );
      return;
    }
    try {
      await send(peer, manifest.groupId, jsonEncode(request));
    } catch (_) {
      _observeSpace(
        SpaceObservationType.p2pReceipt,
        SpaceObservationOutcome.failed,
        reason: SpaceObservationReason.transportFailed,
      );
    }
  }

  /// Bounded RAM-only counters/events with a compile-time privacy-safe schema.
  Future<SpaceObservabilitySnapshot> spaceObservabilitySnapshot() async =>
      _observability.snapshot(replication: await _spaceReplicationSnapshot());

  Future<SpaceReplicationObservability> _spaceReplicationSnapshot() async {
    _purgeSpaceReceiptState();
    Set<String>? activePeerIds;
    final reader = _activePeers;
    if (reader != null) {
      try {
        activePeerIds = {for (final peer in await reader()) peer.hex};
      } catch (_) {
        activePeerIds = null;
      }
    }

    var spaces = 0;
    var eligibleRemoteSpreaders = 0;
    var availableRemoteSpreaders = 0;
    var targetReplicationFactorTotal = 0;
    var confirmedRemoteHolderSlots = 0;
    var availableConfirmedRemoteHolderSlots = 0;
    var confirmedReplicationFactorTotal = 0;
    var confirmedReplicationFactorMin = 0;
    var confirmedReplicationFactorMax = 0;
    var confirmedUnderReplicatedSpaces = 0;
    var liveReplicationFactorTotal = 0;
    var liveReplicationFactorMin = 0;
    var liveReplicationFactorMax = 0;
    var underReplicatedSpaces = 0;
    var referencedContentBlobs = 0;
    var locallyHeldContentBlobs = 0;
    var targetContentHolderSlots = 0;
    var confirmedRemoteContentHolderSlots = 0;
    var availableConfirmedRemoteContentHolderSlots = 0;
    var confirmedContentHolderSlots = 0;
    var confirmedContentDeficitSlots = 0;
    var confirmedUnderReplicatedContentBlobs = 0;

    for (final hex in await _index()) {
      try {
        final bundle = await load(NodeId.fromHex(hex));
        if (bundle == null || !bundle.manifest.isSpace) continue;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        final acl = SpaceAcl(state);
        if (!acl.allows(_signer.selfId, SpacePermission.distributeContent)) {
          continue;
        }
        final eligible = <NodeId>[
          for (final member in state.members.values)
            if (member.nodeId != _signer.selfId &&
                acl.allows(member.nodeId, SpacePermission.distributeContent))
              member.nodeId,
        ];
        final neighborCount = await groupSyncNeighborCount(
          bundle.manifest.groupId,
        );
        final target =
            1 +
            (eligible.length < neighborCount ? eligible.length : neighborCount);
        spaces++;
        eligibleRemoteSpreaders += eligible.length;
        targetReplicationFactorTotal += target;
        final frontier = await _spaceSyncFrontier(
          bundle.manifest.groupId,
          bundle: bundle,
        );
        final confirmed = frontier == null
            ? const <NodeId>[]
            : [
                for (final peer in eligible)
                  if (_spaceHolderProofs[_spaceHolderProofKey(
                            bundle.manifest.groupId,
                            peer,
                          )]
                          ?.frontier ==
                      frontier)
                    peer,
              ];
        final confirmedFactor = confirmed.length + 1;
        confirmedRemoteHolderSlots += confirmed.length;
        confirmedReplicationFactorTotal += confirmedFactor;
        if (spaces == 1 || confirmedFactor < confirmedReplicationFactorMin) {
          confirmedReplicationFactorMin = confirmedFactor;
        }
        if (confirmedFactor > confirmedReplicationFactorMax) {
          confirmedReplicationFactorMax = confirmedFactor;
        }
        if (confirmedFactor < target) confirmedUnderReplicatedSpaces++;

        if (activePeerIds != null) {
          final available = eligible
              .where((peer) => activePeerIds!.contains(peer.hex))
              .length;
          final live = available + 1;
          availableRemoteSpreaders += available;
          availableConfirmedRemoteHolderSlots += confirmed
              .where((peer) => activePeerIds!.contains(peer.hex))
              .length;
          liveReplicationFactorTotal += live;
          if (spaces == 1 || live < liveReplicationFactorMin) {
            liveReplicationFactorMin = live;
          }
          if (live > liveReplicationFactorMax) {
            liveReplicationFactorMax = live;
          }
          if (live < target) underReplicatedSpaces++;
        }

        // Content is measured per referenced CID, not inferred from the Space
        // frontier. A peer may have every signed post/message row while still
        // missing its lazy media blob. Protected-channel references use their
        // narrower recipient set; ordinary references use current members with
        // distribute permission. No CID or member id leaves this method.
        final contentCandidates = await _contentReplicationCandidates(
          bundle,
          state,
        );
        final localContent = <String, bool>{
          for (final entry in await Future.wait(
            contentCandidates.keys.map(
              (contentId) async =>
                  MapEntry(contentId, await _storage.hasFile(contentId)),
            ),
          ))
            entry.key: entry.value,
        };
        for (final entry in contentCandidates.entries) {
          final contentId = entry.key;
          final contentEligible = [
            for (final peer in entry.value)
              if (acl.allows(peer, SpacePermission.distributeContent)) peer,
          ];
          final contentTarget =
              1 +
              (contentEligible.length < neighborCount
                  ? contentEligible.length
                  : neighborCount);
          final heldLocally = localContent[contentId] ?? false;
          final confirmedRemote = [
            for (final peer in contentEligible)
              if (_contentHolderProofs[_contentHolderProofKey(
                    bundle.manifest.groupId,
                    contentId,
                    peer,
                  )] !=
                  null)
                peer,
          ];
          final confirmed = (heldLocally ? 1 : 0) + confirmedRemote.length;
          final deficit = contentTarget > confirmed
              ? contentTarget - confirmed
              : 0;
          referencedContentBlobs++;
          if (heldLocally) locallyHeldContentBlobs++;
          targetContentHolderSlots += contentTarget;
          confirmedRemoteContentHolderSlots += confirmedRemote.length;
          confirmedContentHolderSlots += confirmed;
          confirmedContentDeficitSlots += deficit;
          if (deficit > 0) confirmedUnderReplicatedContentBlobs++;
          if (activePeerIds != null) {
            availableConfirmedRemoteContentHolderSlots += confirmedRemote
                .where((peer) => activePeerIds!.contains(peer.hex))
                .length;
          }
        }
      } catch (_) {
        // A corrupt/partially purged local row must not break diagnostics for
        // every other Space, and exposing the failing id would violate scope.
      }
    }

    final liveSourceAvailable = activePeerIds != null;
    return SpaceReplicationObservability(
      liveSourceAvailable: liveSourceAvailable,
      spaces: spaces,
      eligibleRemoteSpreaders: eligibleRemoteSpreaders,
      targetReplicationFactorTotal: targetReplicationFactorTotal,
      confirmedProofTtlMs: _spaceReceiptTtl.inMilliseconds,
      confirmedRemoteHolderSlots: confirmedRemoteHolderSlots,
      confirmedReplicationFactorTotal: confirmedReplicationFactorTotal,
      confirmedReplicationFactorMin: confirmedReplicationFactorMin,
      confirmedReplicationFactorMax: confirmedReplicationFactorMax,
      confirmedUnderReplicatedSpaces: confirmedUnderReplicatedSpaces,
      referencedContentBlobs: referencedContentBlobs,
      locallyHeldContentBlobs: locallyHeldContentBlobs,
      targetContentHolderSlots: targetContentHolderSlots,
      confirmedRemoteContentHolderSlots: confirmedRemoteContentHolderSlots,
      confirmedContentHolderSlots: confirmedContentHolderSlots,
      confirmedContentDeficitSlots: confirmedContentDeficitSlots,
      confirmedUnderReplicatedContentBlobs:
          confirmedUnderReplicatedContentBlobs,
      availableRemoteSpreaders: liveSourceAvailable
          ? availableRemoteSpreaders
          : null,
      availableConfirmedRemoteHolderSlots: liveSourceAvailable
          ? availableConfirmedRemoteHolderSlots
          : null,
      availableConfirmedRemoteContentHolderSlots: liveSourceAvailable
          ? availableConfirmedRemoteContentHolderSlots
          : null,
      estimatedLiveReplicationFactorTotal: liveSourceAvailable
          ? liveReplicationFactorTotal
          : null,
      estimatedLiveReplicationFactorMin: liveSourceAvailable
          ? liveReplicationFactorMin
          : null,
      estimatedLiveReplicationFactorMax: liveSourceAvailable
          ? liveReplicationFactorMax
          : null,
      estimatedUnderReplicatedSpaces: liveSourceAvailable
          ? underReplicatedSpaces
          : null,
    );
  }

  void _observeSpace(
    SpaceObservationType type,
    SpaceObservationOutcome outcome, {
    SpaceObservationReason? reason,
    int? amount,
    Duration? duration,
  }) => _observability.record(
    type,
    outcome,
    reason: reason,
    amount: amount,
    duration: duration,
  );

  bool _wasRevokedSpaceMember(GroupBundle bundle, NodeId peer) =>
      bundle.manifest.isSpace &&
      bundle.control.any(
        (entry) =>
            _validControlFor(bundle.manifest, entry) &&
            entry.op == ControlOp.addMember &&
            entry.target == peer,
      );

  /// Contact state belongs to [MessagingService], while feed materialization
  /// belongs here. The Flutter bridge calls this after a local or mirrored
  /// relationship transition so blocked-author filtering becomes visible
  /// without waiting for an unrelated group mutation.
  void notifyContactAccessChanged(NodeId peer) {
    if (peer == _signer.selfId) return;
    _contactAccessGenerations.update(
      peer.hex,
      (generation) => generation + 1,
      ifAbsent: () => 1,
    );
    _invalidateFeedAccess();
  }

  int _contactAccessGeneration(NodeId peer) =>
      _contactAccessGenerations[peer.hex] ?? 0;

  Future<bool> _contactConsentStillAllows(
    NodeId peer, {
    required int generation,
    required bool requireAccepted,
  }) async {
    if (_contactAccessGeneration(peer) != generation) return false;
    final status = (await _storage.getContact(peer))?.status;
    if (_contactAccessGeneration(peer) != generation) return false;
    return requireAccepted
        ? status == ContactStatus.accepted
        : status != ContactStatus.blocked;
  }

  void _invalidateFeedAccess() {
    feedAccessChanges.value++;
    changes.value++;
  }

  static const String _spaceInvitesSetting = 'spaces.invites.v1';
  static const int _maxSpaceInvites = 256;
  static const String _scheduledSpacePostIndexSetting =
      'space.scheduled-posts.index.v1';
  static const int _maxScheduledSpacePosts = 128;
  Future<void> _spaceInviteMutationTail = Future<void>.value();
  Future<void> _spacePostDraftMutationTail = Future<void>.value();
  Future<void> _scheduledSpacePostMutationTail = Future<void>.value();

  Future<T> _serializeSpaceInvites<T>(Future<T> Function() action) async {
    final previous = _spaceInviteMutationTail;
    final gate = Completer<void>();
    _spaceInviteMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<T> _serializeSpacePostDrafts<T>(Future<T> Function() action) async {
    final previous = _spacePostDraftMutationTail;
    final gate = Completer<void>();
    _spacePostDraftMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<T> _serializeScheduledSpacePosts<T>(
    Future<T> Function() action,
  ) async {
    final previous = _scheduledSpacePostMutationTail;
    final gate = Completer<void>();
    _scheduledSpacePostMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<({List<PendingSpaceInvite> incoming, List<SpaceInvite> outgoing})>
  _loadSpaceInvites() async {
    final raw = await _storage.getSetting(_spaceInvitesSetting);
    if (raw == null || raw.isEmpty) {
      return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) {
        return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
      }
      final incoming = (value['incoming'] as List? ?? const [])
          .map(PendingSpaceInvite.fromJson)
          .whereType<PendingSpaceInvite>()
          .take(_maxSpaceInvites)
          .toList();
      final outgoing = (value['outgoing'] as List? ?? const [])
          .map(SpaceInvite.fromJson)
          .whereType<SpaceInvite>()
          .take(_maxSpaceInvites)
          .toList();
      return (incoming: incoming, outgoing: outgoing);
    } catch (_) {
      return (incoming: <PendingSpaceInvite>[], outgoing: <SpaceInvite>[]);
    }
  }

  Future<void> _saveSpaceInvites({
    required List<PendingSpaceInvite> incoming,
    required List<SpaceInvite> outgoing,
  }) => _storage.putSetting(
    _spaceInvitesSetting,
    jsonEncode({
      'v': 1,
      'incoming': [
        for (final invite in incoming.take(_maxSpaceInvites)) invite.toJson(),
      ],
      'outgoing': [
        for (final invite in outgoing.take(_maxSpaceInvites)) invite.toJson(),
      ],
    }),
  );

  String _newSpaceInviteId() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Propose Space membership to one accepted contact. No membership state,
  /// history or epoch envelope is sent before the recipient explicitly accepts.
  Future<bool> inviteToSpace(
    NodeId spaceId,
    NodeId invitee, {
    GroupRole role = GroupRole.member,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace || role == GroupRole.owner) {
      return false;
    }
    if (invitee == selfId) return false;
    if ((await _storage.getContact(invitee))?.status !=
        ContactStatus.accepted) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (state.isMember(invitee) ||
        !SpaceAcl(state).allowsControl(
          selfId,
          ControlOp.addMember,
          target: invitee,
          newRole: role,
        )) {
      return false;
    }
    final sender = sendSpaceInvite;
    if (sender == null) return false;
    final now = _now();
    final invite = SpaceInvite(
      inviteId: _newSpaceInviteId(),
      spaceId: spaceId,
      inviter: selfId,
      invitee: invitee,
      spaceName: bundle.manifest.visibility == SpaceVisibility.secret
          ? ''
          : state.name,
      visibility: bundle.manifest.visibility!,
      role: role,
      createdAtMs: now,
      expiresAtMs: now + const Duration(days: 7).inMilliseconds,
    );
    await _serializeSpaceInvites(() async {
      final store = await _loadSpaceInvites();
      final outgoing = [
        invite,
        for (final old in store.outgoing)
          if (!(old.spaceId == spaceId && old.invitee == invitee)) old,
      ];
      await _saveSpaceInvites(incoming: store.incoming, outgoing: outgoing);
    });
    changes.value++;
    try {
      await sender(invitee, invite.inviteId, jsonEncode(invite.toJson()));
      return true;
    } catch (_) {
      // The proposal remains durable locally so a later explicit retry can use
      // the same consent id instead of silently adding the member.
      return false;
    }
  }

  /// Store a minimal proposal from the authenticated accepted contact.
  Future<bool> receiveSpaceInvite(NodeId peer, String inviteJson) async {
    final SpaceInvite? invite;
    try {
      invite = SpaceInvite.fromJson(jsonDecode(inviteJson));
    } catch (_) {
      return false;
    }
    final now = _now();
    if (invite == null ||
        (await _storage.getContact(peer))?.status != ContactStatus.accepted ||
        invite.inviter != peer ||
        invite.invitee != selfId ||
        invite.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        invite.isExpiredAt(now) ||
        !await _canStartSpaceMembershipProposal(invite.spaceId, now)) {
      return false;
    }
    final receivedInvite = invite;
    await _serializeSpaceInvites(() async {
      final store = await _loadSpaceInvites();
      PendingSpaceInvite? same;
      for (final old in store.incoming) {
        if (old.invite.inviteId == receivedInvite.inviteId) same = old;
      }
      final incoming = [
        same ?? PendingSpaceInvite(invite: receivedInvite),
        for (final old in store.incoming)
          if (old.invite.inviteId != receivedInvite.inviteId &&
              old.invite.spaceId != receivedInvite.spaceId)
            old,
      ];
      await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
    });
    changes.value++;
    return true;
  }

  Future<List<PendingSpaceInvite>> pendingSpaceInvites() async {
    return _serializeSpaceInvites(() async {
      final now = _now();
      final store = await _loadSpaceInvites();
      final incoming = <PendingSpaceInvite>[];
      for (final entry in store.incoming) {
        if (entry.invite.isExpiredAt(now) ||
            (await _storage.getContact(entry.invite.inviter))?.status !=
                ContactStatus.accepted) {
          continue;
        }
        incoming.add(entry);
      }
      if (incoming.length != store.incoming.length) {
        await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
        changes.value++;
      }
      incoming.sort(
        (left, right) =>
            right.invite.createdAtMs.compareTo(left.invite.createdAtMs),
      );
      return incoming;
    });
  }

  Future<bool> decideSpaceInvite(
    String inviteId, {
    required bool accept,
  }) async {
    final sender = sendSpaceInviteDecision;
    if (sender == null) return false;
    final prepared =
        await _serializeSpaceInvites<
          ({SpaceInvite invite, SpaceInviteDecision decision})?
        >(() async {
          final store = await _loadSpaceInvites();
          PendingSpaceInvite? pending;
          for (final candidate in store.incoming) {
            if (candidate.invite.inviteId == inviteId) pending = candidate;
          }
          if (pending == null) {
            return null;
          }
          final now = _now();
          if (pending.invite.isExpiredAt(now) ||
              (await _storage.getContact(pending.invite.inviter))?.status !=
                  ContactStatus.accepted) {
            await _saveSpaceInvites(
              incoming: [
                for (final entry in store.incoming)
                  if (entry.invite.inviteId != inviteId) entry,
              ],
              outgoing: store.outgoing,
            );
            changes.value++;
            return null;
          }
          final decidedAt = now;
          final decision = SpaceInviteDecision(
            inviteId: inviteId,
            spaceId: pending.invite.spaceId,
            accepted: accept,
            decidedAtMs: decidedAt,
          );
          final incoming = <PendingSpaceInvite>[
            for (final entry in store.incoming)
              if (entry.invite.inviteId != inviteId)
                entry
              else if (accept)
                PendingSpaceInvite(
                  invite: entry.invite,
                  acceptedAtMs: decidedAt,
                ),
          ];
          await _saveSpaceInvites(incoming: incoming, outgoing: store.outgoing);
          changes.value++;
          return (invite: pending.invite, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.invite.inviter,
        inviteId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Match an authenticated invitee decision to our durable proposal. Only a
  /// valid current control-log authority can turn acceptance into membership.
  Future<bool> receiveSpaceInviteDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceInviteDecision? decision;
    try {
      decision = SpaceInviteDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    if (decision == null) return false;
    final matchedDecision = decision;
    if ((await _storage.getContact(peer))?.status != ContactStatus.accepted) {
      return false;
    }
    final store = await _loadSpaceInvites();
    SpaceInvite? invite;
    for (final candidate in store.outgoing) {
      if (candidate.inviteId == matchedDecision.inviteId &&
          candidate.spaceId == matchedDecision.spaceId &&
          candidate.invitee == peer) {
        invite = candidate;
      }
    }
    final now = _now();
    if (invite == null ||
        invite.isExpiredAt(now) ||
        matchedDecision.decidedAtMs < invite.createdAtMs ||
        matchedDecision.decidedAtMs > invite.expiresAtMs ||
        matchedDecision.decidedAtMs >
            now + const Duration(minutes: 5).inMilliseconds) {
      return false;
    }
    final matchedInvite = invite;
    if (matchedDecision.accepted) {
      final added = await _addMemberFromConsent(
        matchedInvite.spaceId,
        peer,
        matchedInvite.role,
        requireAcceptedContact: true,
      );
      if (!added) {
        if ((await _storage.getContact(peer))?.status !=
            ContactStatus.accepted) {
          await _serializeSpaceInvites(() async {
            final latest = await _loadSpaceInvites();
            await _saveSpaceInvites(
              incoming: latest.incoming,
              outgoing: [
                for (final entry in latest.outgoing)
                  if (entry.inviteId != matchedInvite.inviteId) entry,
              ],
            );
          });
          changes.value++;
        }
        return false;
      }
    }
    await _serializeSpaceInvites(() async {
      final latest = await _loadSpaceInvites();
      await _saveSpaceInvites(
        incoming: latest.incoming,
        outgoing: [
          for (final entry in latest.outgoing)
            if (entry.inviteId != matchedDecision.inviteId) entry,
        ],
      );
    });
    changes.value++;
    return true;
  }

  static const String _spaceJoinRequestsSetting = 'spaces.join_requests.v1';
  static const int _maxSpaceJoinRecords = 256;
  Future<void> _spaceJoinMutationTail = Future<void>.value();

  Future<T> _serializeSpaceJoins<T>(Future<T> Function() action) async {
    final previous = _spaceJoinMutationTail;
    final gate = Completer<void>();
    _spaceJoinMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<
    ({
      List<SpaceJoinTicket> tickets,
      List<SpaceJoinInboxEntry> incoming,
      List<SpaceJoinOutboxEntry> outgoing,
    })
  >
  _loadSpaceJoins() async {
    final raw = await _storage.getSetting(_spaceJoinRequestsSetting);
    if (raw == null || raw.isEmpty) {
      return (
        tickets: <SpaceJoinTicket>[],
        incoming: <SpaceJoinInboxEntry>[],
        outgoing: <SpaceJoinOutboxEntry>[],
      );
    }
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) throw const FormatException();
      return (
        tickets: (value['tickets'] as List? ?? const [])
            .map(SpaceJoinTicket.fromJson)
            .whereType<SpaceJoinTicket>()
            .take(_maxSpaceJoinRecords)
            .toList(),
        incoming: (value['incoming'] as List? ?? const [])
            .map(SpaceJoinInboxEntry.fromJson)
            .whereType<SpaceJoinInboxEntry>()
            .take(_maxSpaceJoinRecords)
            .toList(),
        outgoing: (value['outgoing'] as List? ?? const [])
            .map(SpaceJoinOutboxEntry.fromJson)
            .whereType<SpaceJoinOutboxEntry>()
            .take(_maxSpaceJoinRecords)
            .toList(),
      );
    } catch (_) {
      return (
        tickets: <SpaceJoinTicket>[],
        incoming: <SpaceJoinInboxEntry>[],
        outgoing: <SpaceJoinOutboxEntry>[],
      );
    }
  }

  Future<void> _saveSpaceJoins({
    required List<SpaceJoinTicket> tickets,
    required List<SpaceJoinInboxEntry> incoming,
    required List<SpaceJoinOutboxEntry> outgoing,
  }) => _storage.putSetting(
    _spaceJoinRequestsSetting,
    jsonEncode({
      'v': 1,
      'tickets': [
        for (final ticket in tickets.take(_maxSpaceJoinRecords))
          ticket.toJson(),
      ],
      'incoming': [
        for (final entry in incoming.take(_maxSpaceJoinRecords)) entry.toJson(),
      ],
      'outgoing': [
        for (final entry in outgoing.take(_maxSpaceJoinRecords)) entry.toJson(),
      ],
    }),
  );

  /// Create or reuse a capability-bound join link for one active public Space.
  /// Only an actor who can currently add a member may issue it. The link itself
  /// grants no data and is useless after the local ticket is revoked/expired.
  Future<String?> createSpaceJoinCode(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return null;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(
      state,
    ).allowsControl(selfId, ControlOp.addMember, newRole: GroupRole.member)) {
      return null;
    }
    return _serializeSpaceJoins(() async {
      final now = _now();
      final store = await _loadSpaceJoins();
      SpaceJoinTicket? current;
      for (final ticket in store.tickets) {
        if (ticket.spaceId == spaceId &&
            ticket.approver == selfId &&
            !ticket.isExpiredAt(now)) {
          current = ticket;
          break;
        }
      }
      current ??= SpaceJoinTicket(
        ticketId: _newSpaceInviteId(),
        spaceId: spaceId,
        approver: selfId,
        spaceName: state.name,
        createdAtMs: now,
        expiresAtMs: now + kSpaceJoinTicketLifetime.inMilliseconds,
      );
      if (current.spaceName != state.name) {
        current = SpaceJoinTicket(
          ticketId: current.ticketId,
          spaceId: current.spaceId,
          approver: current.approver,
          spaceName: state.name,
          createdAtMs: current.createdAtMs,
          expiresAtMs: current.expiresAtMs,
        );
      }
      final tickets = <SpaceJoinTicket>[
        current,
        for (final ticket in store.tickets)
          if (ticket.spaceId != spaceId && !ticket.isExpiredAt(now)) ticket,
      ];
      final oldTickets = jsonEncode([
        for (final ticket in store.tickets) ticket.toJson(),
      ]);
      final newTickets = jsonEncode([
        for (final ticket in tickets) ticket.toJson(),
      ]);
      if (oldTickets == newTickets) return SpaceJoinCode.encode(current);
      await _saveSpaceJoins(
        tickets: tickets,
        incoming: store.incoming,
        outgoing: store.outgoing,
      );
      changes.value++;
      return SpaceJoinCode.encode(current);
    });
  }

  Future<
    ({
      List<SpacePostView> posts,
      List<SpacePublicComment> comments,
      List<SpacePublicReaction> reactions,
      int revision,
      int updatedAtMs,
    })?
  >
  _spacePublicFeedMaterial(GroupBundle bundle) async {
    final visible = [
      for (final post in await _postsOfBundle(bundle))
        if (post.visibility == SpacePostVisibility.public) post,
    ];
    if (visible.length >
        kSpacePublicFeedPageSize * kSpacePublicFeedPageMaxCount) {
      return null;
    }
    visible.sort(
      (left, right) => SpaceFeedCursor.fromView(
        right,
      ).compareTo(SpaceFeedCursor.fromView(left)),
    );
    final visibleById = {for (final post in visible) post.postId: post};

    // A public discussion statement is admitted only when the same member row
    // is still accepted and decrypts to the exact signed public content. This
    // keeps public opt-in independent from the private log without allowing a
    // relay to graft an otherwise valid statement onto unrelated membership
    // activity.
    final visibleMessages = await _messagesOfBundle(
      bundle,
      includeSpacePostComments: true,
      applyLocalRetention: false,
    );
    final commentsByRef = {
      for (final message in visibleMessages)
        if (message.spacePostId != null) message.ref: message,
    };
    bool sameMedia(MediaObject? left, MediaObject? right) =>
        jsonEncode(left?.toJson()) == jsonEncode(right?.toJson());
    final publicComments = <SpacePublicComment>[];
    for (final comment in bundle.publicComments) {
      final post = visibleById[comment.postId];
      final memberRow = commentsByRef['${comment.author.hex}:${comment.seq}'];
      if (post == null ||
          _postGeneration(post.root) != comment.lifecycleGeneration ||
          !comment.verify(_signer.verifyDetached) ||
          memberRow == null ||
          memberRow.author != comment.author ||
          memberRow.spacePostId != comment.postId ||
          (memberRow.lifecycleGeneration ??
                  _legacyPostGeneration(bundle.manifest.groupId)) !=
              comment.lifecycleGeneration) {
        continue;
      }
      final matches = switch (comment.operation) {
        SpacePublicCommentOperation.create =>
          memberRow.editOf == null &&
              memberRow.deleteOf == null &&
              memberRow.body == comment.body &&
              memberRow.replyTo == comment.replyTo &&
              sameMedia(memberRow.attachment, comment.media),
        SpacePublicCommentOperation.edit =>
          memberRow.editOf == comment.ref &&
              memberRow.deleteOf == null &&
              memberRow.body == comment.body &&
              memberRow.attachment == null &&
              memberRow.replyTo == null,
        SpacePublicCommentOperation.delete =>
          memberRow.editOf == null &&
              memberRow.deleteOf == comment.ref &&
              memberRow.body.isEmpty &&
              memberRow.attachment == null &&
              memberRow.replyTo == null,
      };
      if (matches) publicComments.add(comment);
    }

    final visibleReactions = <String, GroupReaction>{};
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    for (final reaction in _acceptedReactionsWithinLifecycle(bundle, state)) {
      final materialized = await _materializeEncryptedReaction(
        bundle,
        reaction,
      );
      if (materialized != null &&
          materialized.targetKind == ReactionTargetKind.spacePost) {
        visibleReactions['${reaction.author.hex}:${reaction.seq}'] =
            materialized;
      }
    }
    final publicReactions = <SpacePublicReaction>[];
    for (final reaction in bundle.publicReactions) {
      final post = visibleById[reaction.postId];
      final memberRow =
          visibleReactions['${reaction.author.hex}:${reaction.seq}'];
      if (post == null ||
          _postGeneration(post.root) != reaction.lifecycleGeneration ||
          !reaction.verify(_signer.verifyDetached) ||
          memberRow == null ||
          memberRow.author != reaction.author ||
          memberRow.target != reaction.postId ||
          memberRow.emoji != reaction.emoji ||
          (memberRow.lifecycleGeneration ??
                  _legacyPostGeneration(bundle.manifest.groupId)) !=
              reaction.lifecycleGeneration) {
        continue;
      }
      publicReactions.add(reaction);
    }
    if (publicComments.length + publicReactions.length >
        kSpacePublicDiscussionPageSize * kSpacePublicDiscussionPageMaxCount) {
      return null;
    }
    publicComments.sort((left, right) {
      final byTime = left.createdAtMs.compareTo(right.createdAtMs);
      if (byTime != 0) return byTime;
      final byAuthor = left.author.hex.compareTo(right.author.hex);
      return byAuthor != 0 ? byAuthor : left.seq.compareTo(right.seq);
    });
    publicReactions.sort((left, right) {
      final byTime = left.createdAtMs.compareTo(right.createdAtMs);
      if (byTime != 0) return byTime;
      final byAuthor = left.author.hex.compareTo(right.author.hex);
      return byAuthor != 0 ? byAuthor : left.seq.compareTo(right.seq);
    });

    var updatedAtMs = bundle.manifest.createdAtMs;
    final retainedPublicRows = [
      for (final post in _retainedPostRows(
        bundle.manifest.groupId,
        bundle.posts,
      ))
        if (post.visibility == SpacePostVisibility.public) post,
    ];
    for (final post in retainedPublicRows) {
      updatedAtMs = max(updatedAtMs, post.createdAtMs);
    }
    for (final comment in publicComments) {
      updatedAtMs = max(updatedAtMs, comment.createdAtMs);
    }
    for (final reaction in publicReactions) {
      updatedAtMs = max(updatedAtMs, reaction.createdAtMs);
    }
    return (
      posts: List<SpacePostView>.unmodifiable(visible),
      comments: List<SpacePublicComment>.unmodifiable(publicComments),
      reactions: List<SpacePublicReaction>.unmodifiable(publicReactions),
      // Distinct valid rows include fork evidence. This count therefore never
      // rolls back when a newly received equivocation quarantines a formerly
      // visible suffix; the newer fail-closed descriptor still supersedes the
      // older snapshot instead of losing a "highest revision" comparison.
      revision:
          retainedPublicRows.length +
          bundle.publicComments.length +
          bundle.publicReactions.length,
      updatedAtMs: updatedAtMs,
    );
  }

  String _verifiedPublicFeedKey(NodeId spaceId, String manifestHash) =>
      '${spaceId.hex}:$manifestHash';

  String _verifiedPublicFeedFileId(NodeId spaceId, String manifestHash) =>
      'space-public-feed:${spaceId.hex}:$manifestHash';

  Future<T> _serializePublicFeedCache<T>(Future<T> Function() action) async {
    final previous = _publicFeedCacheMutationTail;
    final gate = Completer<void>();
    _publicFeedCacheMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<void> _cacheVerifiedPublicFeed(
    SpacePublicDescriptor descriptor,
    SpacePublicFeedProjection feed,
  ) async {
    final key = _verifiedPublicFeedKey(
      descriptor.spaceId,
      descriptor.publicFeedManifestHash,
    );
    final nowMs = _now();
    final retainUntilMs = min(
      descriptor.expiresAtMs,
      nowMs + kSpacePublicHolderLifetime.inMilliseconds,
    );
    _verifiedPublicSpaceFeeds[key] = (
      descriptor: descriptor,
      feed: feed,
      retainedUntilMs: retainUntilMs,
    );
    final fileId = _verifiedPublicFeedFileId(
      descriptor.spaceId,
      descriptor.publicFeedManifestHash,
    );
    var alreadyDurable = false;
    try {
      alreadyDurable = await _storage.hasFile(fileId);
    } catch (_) {}
    Uint8List? bytes;
    if (!alreadyDurable) {
      var estimatedBytes =
          descriptor.canonicalBytes().length +
          feed.manifest.canonicalBytes().length +
          2 * 1024 * 1024;
      for (final page in feed.pages) {
        estimatedBytes += page.canonicalBytes().length;
        if (estimatedBytes > kSpacePublicFeedPackageMaxBytes) return;
      }
      final package = SpacePublicFeedPackage(
        descriptor: descriptor,
        projection: feed,
      );
      bytes = package.toBytes();
      if (bytes.length > kSpacePublicFeedPackageMaxBytes) return;
    }
    await _serializePublicFeedCache(() async {
      final retained =
          <({NodeId spaceId, String manifestHash, int retainUntilMs})>[];
      final discard = <({NodeId spaceId, String manifestHash})>[];
      final raw = await _storage.getSetting(_publicFeedCacheIndexSetting);
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            for (final item in decoded.take(
              _kMaxDurablePublicFeedPackages * 2,
            )) {
              if (item is! Map ||
                  item['space'] is! String ||
                  item['manifest'] is! String ||
                  item['retainUntil'] is! int) {
                continue;
              }
              try {
                final candidate = (
                  spaceId: NodeId.fromHex(item['space'] as String),
                  manifestHash: item['manifest'] as String,
                  retainUntilMs: item['retainUntil'] as int,
                );
                if (_sharedContentIdPattern.hasMatch(candidate.manifestHash)) {
                  if (candidate.retainUntilMs > nowMs &&
                      !(candidate.spaceId == descriptor.spaceId &&
                          candidate.manifestHash ==
                              descriptor.publicFeedManifestHash)) {
                    retained.add(candidate);
                  } else if (!(candidate.spaceId == descriptor.spaceId &&
                      candidate.manifestHash ==
                          descriptor.publicFeedManifestHash)) {
                    discard.add((
                      spaceId: candidate.spaceId,
                      manifestHash: candidate.manifestHash,
                    ));
                  }
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
      retained.add((
        spaceId: descriptor.spaceId,
        manifestHash: descriptor.publicFeedManifestHash,
        retainUntilMs: retainUntilMs,
      ));
      retained.sort(
        (left, right) => right.retainUntilMs.compareTo(left.retainUntilMs),
      );
      final keep = retained
          .take(_kMaxDurablePublicFeedPackages)
          .toList(growable: false);
      final keepKeys = {
        for (final item in keep)
          _verifiedPublicFeedKey(item.spaceId, item.manifestHash),
      };
      for (final item in [
        ...discard,
        for (final item in retained.skip(_kMaxDurablePublicFeedPackages))
          (spaceId: item.spaceId, manifestHash: item.manifestHash),
      ]) {
        final staleKey = _verifiedPublicFeedKey(
          item.spaceId,
          item.manifestHash,
        );
        _verifiedPublicSpaceFeeds.remove(staleKey);
        try {
          await _storage.deleteStoredFile(
            _verifiedPublicFeedFileId(item.spaceId, item.manifestHash),
          );
        } catch (_) {}
      }
      final staleInMemory = [
        for (final entry in _verifiedPublicSpaceFeeds.entries)
          if (!keepKeys.contains(entry.key) &&
              entry.value.retainedUntilMs <= nowMs)
            entry.key,
      ];
      for (final staleKey in staleInMemory) {
        _verifiedPublicSpaceFeeds.remove(staleKey);
      }
      if (bytes != null && !await _storage.hasFile(fileId)) {
        await _storage.storeFile(fileId, bytes);
      }
      await _storage.putSetting(
        _publicFeedCacheIndexSetting,
        jsonEncode([
          for (final item in keep)
            {
              'space': item.spaceId.hex,
              'manifest': item.manifestHash,
              'retainUntil': item.retainUntilMs,
            },
        ]),
      );
    });
  }

  Future<int?> _durablePublicFeedRetainedUntil(
    NodeId spaceId,
    String manifestHash,
  ) async {
    final raw = await _storage.getSetting(_publicFeedCacheIndexSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      for (final item in decoded.take(_kMaxDurablePublicFeedPackages * 2)) {
        if (item is Map &&
            item['space'] == spaceId.hex &&
            item['manifest'] == manifestHash &&
            item['retainUntil'] is int) {
          return item['retainUntil'] as int;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<
    ({
      SpacePublicDescriptor descriptor,
      SpacePublicFeedProjection feed,
      int retainedUntilMs,
    })?
  >
  _loadVerifiedPublicFeed(NodeId spaceId, String manifestHash) async {
    final key = _verifiedPublicFeedKey(spaceId, manifestHash);
    final memory = _verifiedPublicSpaceFeeds[key];
    final nowMs = _now();
    if (memory != null) {
      if (memory.retainedUntilMs > nowMs) return memory;
      _verifiedPublicSpaceFeeds.remove(key);
    }
    final retainedUntilMs = await _durablePublicFeedRetainedUntil(
      spaceId,
      manifestHash,
    );
    if (retainedUntilMs == null || retainedUntilMs <= nowMs) return null;
    final Uint8List? bytes;
    try {
      bytes = await _storage.loadFile(
        _verifiedPublicFeedFileId(spaceId, manifestHash),
      );
    } catch (_) {
      return null;
    }
    final package = bytes == null
        ? null
        : SpacePublicFeedPackage.fromBytes(bytes);
    if (package == null ||
        package.descriptor.spaceId != spaceId ||
        package.descriptor.publicFeedManifestHash != manifestHash ||
        !package.verifyAt(
          nowMs: nowMs,
          verifySignature: _signer.verifyDetached,
          verifyPost: _signer.verifyPost,
        )) {
      if (bytes != null) {
        try {
          await _storage.deleteStoredFile(
            _verifiedPublicFeedFileId(spaceId, manifestHash),
          );
        } catch (_) {}
      }
      return null;
    }
    final loaded = (
      descriptor: package.descriptor,
      feed: package.projection,
      retainedUntilMs: retainedUntilMs,
    );
    _verifiedPublicSpaceFeeds[key] = loaded;
    return loaded;
  }

  Future<
    ({
      SpacePublicDescriptor descriptor,
      SpacePublicFeedProjection feed,
      int retainedUntilMs,
    })?
  >
  _loadOrRebuildVerifiedPublicFeed({
    required NodeId spaceId,
    required String descriptorHash,
    required String manifestHash,
  }) async {
    var cached = await _loadVerifiedPublicFeed(spaceId, manifestHash);
    if (cached == null) {
      final rebuilt = await buildSpacePublicDiscoveryPublication(spaceId);
      if (rebuilt != null &&
          rebuilt.discovery.descriptor.descriptorHash == descriptorHash &&
          rebuilt.discovery.descriptor.publicFeedManifestHash == manifestHash) {
        cached = await _loadVerifiedPublicFeed(spaceId, manifestHash);
        cached ??= (
          descriptor: rebuilt.discovery.descriptor,
          feed: rebuilt.feed,
          retainedUntilMs: min(
            rebuilt.discovery.descriptor.expiresAtMs,
            _now() + kSpacePublicHolderLifetime.inMilliseconds,
          ),
        );
      }
    }
    if (cached == null ||
        cached.descriptor.descriptorHash != descriptorHash ||
        cached.descriptor.publicFeedManifestHash != manifestHash ||
        cached.feed.manifest.manifestHash != manifestHash) {
      return null;
    }
    return cached;
  }

  SpacePublicFeedProjection? _signSpacePublicFeedProjection({
    required GroupBundle bundle,
    required String controlHeadHash,
    required List<SpacePostView> posts,
    required List<SpacePublicComment> comments,
    required List<SpacePublicReaction> reactions,
    required int revision,
    required int updatedAtMs,
    required int issuedAtMs,
    required int expiresAtMs,
  }) {
    final pages = <SpacePublicFeedPage>[];
    for (
      var offset = 0;
      offset < posts.length;
      offset += kSpacePublicFeedPageSize
    ) {
      final end = min(offset + kSpacePublicFeedPageSize, posts.length);
      pages.add(
        SpacePublicFeedPage(
          spaceId: bundle.manifest.groupId,
          index: pages.length,
          posts: [
            for (final post in posts.sublist(offset, end))
              SpacePublicPostProjection.fromView(post),
          ],
        ),
      );
    }
    if (pages.any((page) => !page.isStructurallyValid)) return null;
    final discussionPages = <SpacePublicDiscussionPage>[];
    var commentOffset = 0;
    var reactionOffset = 0;
    while (commentOffset < comments.length ||
        reactionOffset < reactions.length) {
      final pageComments = comments
          .skip(commentOffset)
          .take(kSpacePublicDiscussionPageSize)
          .toList(growable: false);
      commentOffset += pageComments.length;
      final remaining = kSpacePublicDiscussionPageSize - pageComments.length;
      final pageReactions = reactions
          .skip(reactionOffset)
          .take(remaining)
          .toList(growable: false);
      reactionOffset += pageReactions.length;
      discussionPages.add(
        SpacePublicDiscussionPage(
          spaceId: bundle.manifest.groupId,
          index: discussionPages.length,
          comments: pageComments,
          reactions: pageReactions,
        ),
      );
    }
    if (discussionPages.any((page) => !page.isStructurallyValid)) return null;
    final hasDiscussion = discussionPages.isNotEmpty;
    final unsigned = SpacePublicFeedManifest(
      spaceId: bundle.manifest.groupId,
      publisher: selfId,
      controlHeadHash: controlHeadHash,
      revision: revision,
      updatedAtMs: updatedAtMs,
      issuedAtMs: issuedAtMs,
      expiresAtMs: expiresAtMs,
      itemCount: posts.length,
      pageHashes: [for (final page in pages) page.contentHash],
      wireVersion: hasDiscussion
          ? SpacePublicFeedManifest.discussionVersion
          : SpacePublicFeedManifest.version,
      discussionItemCount: comments.length + reactions.length,
      discussionPageHashes: [
        for (final page in discussionPages) page.contentHash,
      ],
    );
    final signed = _signer.signDetached(unsigned.canonicalBytes());
    if (!_listEquals(signed.publicKey, _signer.selfPubKey)) {
      return null;
    }
    final manifest = unsigned.withSignature(signed.signature);
    final projection = SpacePublicFeedProjection(
      manifest: manifest,
      pages: pages,
      discussionPages: discussionPages,
    );
    return projection.verifyAt(
          nowMs: issuedAtMs,
          expectedManifestHash: manifest.manifestHash,
          expectedSpaceId: bundle.manifest.groupId,
          expectedPublisher: selfId,
          publisherPublicKey: _signer.selfPubKey,
          expectedControlHeadHash: controlHeadHash,
          verifySignature: _signer.verifyDetached,
          verifyPost: _signer.verifyPost,
        )
        ? projection
        : null;
  }

  /// Build the strict public descriptor + holder attestation carried by the
  /// native discovery DHT. V3 proves the effective publisher through a
  /// genesis-rooted chain of exact signed V6 ownership hand-offs.
  Future<SpacePublicDiscoveryPayload?> buildSpacePublicDiscoveryPayload(
    NodeId spaceId,
  ) async => (await buildSpacePublicDiscoveryPublication(spaceId))?.discovery;

  Future<SpacePublicDiscoveryPublication?> buildSpacePublicDiscoveryPublication(
    NodeId spaceId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public ||
        bundle.manifest.discoverable != true) {
      return null;
    }
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    );
    final state = folded.state;
    final owners = [
      for (final member in state.members.values)
        if (member.role == GroupRole.owner) member.nodeId,
    ];
    if (!state.isActive || owners.length != 1 || owners.single != selfId) {
      return null;
    }
    final authorityChain = buildSpacePublicAuthorityChain(
      spaceId: spaceId,
      genesisOwner: bundle.manifest.owner,
      acceptedControl: folded.accepted,
    );
    if (authorityChain == null ||
        (authorityChain.isEmpty
            ? bundle.manifest.owner != selfId
            : authorityChain.last.nextOwner != selfId)) {
      return null;
    }
    final feedMaterial = await _spacePublicFeedMaterial(bundle);
    if (feedMaterial == null) return null;
    final joinCode = await createSpaceJoinCode(spaceId);
    if (joinCode == null) return null;
    final ticket = SpaceJoinCode.parse(joinCode);
    final wallNow = _now();
    final updatedAt = folded.accepted.fold<int>(
      bundle.manifest.createdAtMs,
      (latest, entry) =>
          entry.createdAtMs > latest ? entry.createdAtMs : latest,
    );
    if (updatedAt > wallNow + kSpacePublicClockSkew.inMilliseconds) {
      return null;
    }
    // Keep the owner descriptor stable across periodic DHT refreshes so
    // independent holders can attest the same hash. Availability freshness
    // belongs to the short-lived holder record below, not to owner metadata.
    final issuedAt = max(
      max(updatedAt, ticket.createdAtMs),
      feedMaterial.updatedAtMs,
    );
    final expiresAt = min(
      ticket.expiresAtMs,
      issuedAt + kSpacePublicDescriptorLifetime.inMilliseconds,
    );
    if (expiresAt <= wallNow || expiresAt <= issuedAt) return null;
    final controlHeadHash = crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final entry in folded.accepted) controlEntryHash(entry),
            ]),
          ),
        )
        .toString();
    final feed = _signSpacePublicFeedProjection(
      bundle: bundle,
      controlHeadHash: controlHeadHash,
      posts: feedMaterial.posts,
      comments: feedMaterial.comments,
      reactions: feedMaterial.reactions,
      revision: feedMaterial.revision,
      updatedAtMs: feedMaterial.updatedAtMs,
      issuedAtMs: issuedAt,
      expiresAtMs: expiresAt,
    );
    if (feed == null) return null;
    final unsignedDescriptor = SpacePublicDescriptor(
      spaceId: spaceId,
      publisher: selfId,
      publisherPublicKey: _signer.selfPubKey,
      authorityChain: authorityChain,
      genesisManifest: bundle.manifest,
      controlHeadHash: controlHeadHash,
      revision: folded.accepted.length,
      publicFeedManifestHash: feed.manifest.manifestHash,
      publicFeedRevision: feed.manifest.revision,
      publicFeedUpdatedAtMs: feed.manifest.updatedAtMs,
      publicPostCount: feed.manifest.itemCount,
      name: state.name,
      description: state.description,
      avatarContentId: bundle.manifest.avatarContentId,
      coverContentId: bundle.manifest.coverContentId,
      createdAtMs: bundle.manifest.createdAtMs,
      updatedAtMs: updatedAt,
      issuedAtMs: issuedAt,
      expiresAtMs: expiresAt,
      joinCode: joinCode,
    );
    final descriptorSignature = _signer.signDetached(
      unsignedDescriptor.canonicalBytes(),
    );
    if (!_listEquals(
      descriptorSignature.publicKey,
      unsignedDescriptor.publisherPublicKey,
    )) {
      return null;
    }
    final descriptor = unsignedDescriptor.withSignature(
      descriptorSignature.signature,
    );
    if (!descriptor.verifyAt(issuedAt, _signer.verifyDetached)) return null;

    final holderIssuedAt = wallNow;
    final holderExpiresAt = min(
      descriptor.expiresAtMs,
      holderIssuedAt + kSpacePublicHolderLifetime.inMilliseconds,
    );
    if (holderExpiresAt <= holderIssuedAt) return null;
    final unsignedHolder = SpacePublicHolderAnnouncement(
      spaceId: spaceId,
      descriptorHash: descriptor.descriptorHash,
      publicFeedManifestHash: descriptor.publicFeedManifestHash,
      holder: selfId,
      holderPublicKey: descriptorSignature.publicKey,
      issuedAtMs: holderIssuedAt,
      expiresAtMs: holderExpiresAt,
    );
    final holderSignature = _signer.signDetached(
      unsignedHolder.canonicalBytes(),
    );
    if (!_listEquals(
      holderSignature.publicKey,
      descriptorSignature.publicKey,
    )) {
      return null;
    }
    final holder = unsignedHolder.withSignature(holderSignature.signature);
    final payload = SpacePublicDiscoveryPayload(
      descriptor: descriptor,
      holder: holder,
    );
    if (payload.toBytes().length > kSpacePublicDiscoveryPayloadMaxBytes ||
        !payload.verifyAt(wallNow, _signer.verifyDetached) ||
        !feed.verifyAt(
          nowMs: wallNow,
          expectedManifestHash: descriptor.publicFeedManifestHash,
          expectedSpaceId: descriptor.spaceId,
          expectedPublisher: descriptor.publisher,
          publisherPublicKey: descriptor.publisherPublicKey,
          expectedControlHeadHash: descriptor.controlHeadHash,
          verifySignature: _signer.verifyDetached,
          verifyPost: _signer.verifyPost,
        )) {
      return null;
    }
    await _cacheVerifiedPublicFeed(descriptor, feed);
    return SpacePublicDiscoveryPublication(discovery: payload, feed: feed);
  }

  Future<bool> _localSpaceAcceptsPublicDescriptor(
    NodeId spaceId,
    SpacePublicDescriptor descriptor,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null) {
      // A public-only subscriber has no membership bundle by design. It may
      // still reseed the exact owner-signed package it durably verified; never
      // let a merely observed newer descriptor borrow that local trust.
      final snapshot = await _loadPublicSubscriptionSnapshot(spaceId);
      return snapshot != null &&
          snapshot.package.descriptor.descriptorHash ==
              descriptor.descriptorHash &&
          snapshot.package.descriptor.publicFeedManifestHash ==
              descriptor.publicFeedManifestHash &&
          snapshot.verifyStored(
            verifySignature: _signer.verifyDetached,
            verifyPost: _signer.verifyPost,
          );
    }
    if (!bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public ||
        bundle.manifest.discoverable != true ||
        descriptor.spaceId != spaceId ||
        jsonEncode(bundle.manifest.toJson()) !=
            jsonEncode(descriptor.genesisManifest.toJson())) {
      return false;
    }
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    );
    final owners = [
      for (final member in folded.state.members.values)
        if (member.role == GroupRole.owner) member.nodeId,
    ];
    if (!folded.state.isActive ||
        owners.length != 1 ||
        owners.single != descriptor.publisher) {
      return false;
    }
    final localControlHeadHash = crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final entry in folded.accepted) controlEntryHash(entry),
            ]),
          ),
        )
        .toString();
    if (localControlHeadHash != descriptor.controlHeadHash) return false;
    final localFeed = await _spacePublicFeedMaterial(bundle);
    return localFeed != null &&
        localFeed.revision <= descriptor.publicFeedRevision;
  }

  SpacePublicDiscoveryPublication? _signVerifiedPublicHolder({
    required SpacePublicDescriptor descriptor,
    required SpacePublicFeedProjection feed,
  }) {
    final nowMs = _now();
    if (!descriptor.verifyAt(nowMs, _signer.verifyDetached) ||
        !feed.verifyAt(
          nowMs: nowMs,
          expectedManifestHash: descriptor.publicFeedManifestHash,
          expectedSpaceId: descriptor.spaceId,
          expectedPublisher: descriptor.publisher,
          publisherPublicKey: descriptor.publisherPublicKey,
          expectedControlHeadHash: descriptor.controlHeadHash,
          verifySignature: _signer.verifyDetached,
          verifyPost: _signer.verifyPost,
        )) {
      return null;
    }
    final expiresAtMs = min(
      descriptor.expiresAtMs,
      nowMs + kSpacePublicHolderLifetime.inMilliseconds,
    );
    if (expiresAtMs <= nowMs) return null;
    final unsigned = SpacePublicHolderAnnouncement(
      spaceId: descriptor.spaceId,
      descriptorHash: descriptor.descriptorHash,
      publicFeedManifestHash: descriptor.publicFeedManifestHash,
      holder: selfId,
      holderPublicKey: _signer.selfPubKey,
      issuedAtMs: nowMs,
      expiresAtMs: expiresAtMs,
    );
    final signed = _signer.signDetached(unsigned.canonicalBytes());
    if (!_listEquals(signed.publicKey, _signer.selfPubKey)) return null;
    final holder = unsigned.withSignature(signed.signature);
    final payload = SpacePublicDiscoveryPayload(
      descriptor: descriptor,
      holder: holder,
    );
    return payload.verifyAt(nowMs, _signer.verifyDetached)
        ? SpacePublicDiscoveryPublication(discovery: payload, feed: feed)
        : null;
  }

  /// Download every bounded object committed by [descriptor], verify the owner
  /// manifest and all author signatures, then create this node's independent
  /// short-lived holder attestation. The caller chooses which public Spaces it
  /// is willing to seed; membership is deliberately not treated as authority.
  Future<SpacePublicDiscoveryPublication?>
  replicateVerifiedPublicSpaceDiscovery(
    SpacePublicDescriptor descriptor,
    Iterable<SpacePublicHolderAnnouncement> holders,
  ) async {
    final cached = await _loadVerifiedPublicFeed(
      descriptor.spaceId,
      descriptor.publicFeedManifestHash,
    );
    if (cached != null &&
        cached.descriptor.descriptorHash == descriptor.descriptorHash) {
      final publication = _signVerifiedPublicHolder(
        descriptor: cached.descriptor,
        feed: cached.feed,
      );
      if (publication != null) return publication;
    }
    final feed = await fetchVerifiedPublicSpaceFeed(descriptor, holders);
    return feed == null
        ? null
        : _signVerifiedPublicHolder(descriptor: descriptor, feed: feed);
  }

  Future<SpacePublicDiscoveryPublication?> _replicatePublicSpaceDiscovery(
    NodeId spaceId,
  ) async {
    ({
      SpacePublicDescriptor descriptor,
      SpacePublicFeedProjection feed,
      int retainedUntilMs,
    })?
    cached;
    for (final candidate in _verifiedPublicSpaceFeeds.values) {
      if (candidate.descriptor.spaceId != spaceId ||
          candidate.retainedUntilMs <= _now()) {
        continue;
      }
      if (cached == null ||
          compareSpacePublicDescriptors(
                candidate.descriptor,
                cached.descriptor,
              ) >
              0) {
        cached = candidate;
      }
    }
    if (cached != null &&
        await _localSpaceAcceptsPublicDescriptor(spaceId, cached.descriptor)) {
      final refreshed = _signVerifiedPublicHolder(
        descriptor: cached.descriptor,
        feed: cached.feed,
      );
      if (refreshed != null) return refreshed;
    }
    final route = SpaceDiscoveryCarrierRoute.direct(spaceId);
    final payloads = await _resolvePublicDiscoveryRoute(
      route,
      timeout: const Duration(seconds: 8),
    );
    final descriptors = mergeSpacePublicDiscovery(
      descriptors: [for (final payload in payloads) payload.descriptor],
      holders: [for (final payload in payloads) payload.holder],
      nowMs: _now(),
      verify: _signer.verifyDetached,
      minimumIndependentHolders: 1,
    );
    for (final descriptor in descriptors) {
      if (descriptor.spaceId != spaceId ||
          !await _localSpaceAcceptsPublicDescriptor(spaceId, descriptor)) {
        continue;
      }
      final publication = await replicateVerifiedPublicSpaceDiscovery(
        descriptor,
        [
          for (final payload in payloads)
            if (payload.descriptor.descriptorHash == descriptor.descriptorHash)
              payload.holder,
        ],
      );
      if (publication != null) return publication;
    }
    return null;
  }

  /// Publish every locally held `public + discoverable` Space through the
  /// native bounded DHT carrier. Owners build their current projection;
  /// public-only subscribers reseed only their exact durably verified package.
  /// A direct route supports exact links; hashed name/prefix routes support
  /// interactive search without publishing a plaintext side index.
  Future<SpaceDiscoveryPublishSweep> publishPublicSpaceDiscovery({
    bool forceHolderRefresh = true,
  }) async {
    final transport = _spaceDiscoveryTransport;
    if (transport == null) {
      return const SpaceDiscoveryPublishSweep(
        spacesScanned: 0,
        spacesPublished: 0,
        recordsPublished: 0,
        failures: 0,
        available: false,
      );
    }
    var spacesScanned = 0;
    var spacesPublished = 0;
    var recordsPublished = 0;
    var failures = 0;
    final candidates = <String, NodeId>{};
    for (final entry in await listSpaces()) {
      candidates[entry.groupId.hex] = entry.groupId;
    }
    for (final subscription in await publicSpaceSubscriptions()) {
      candidates[subscription.descriptor.spaceId.hex] =
          subscription.descriptor.spaceId;
    }
    for (final spaceId in candidates.values) {
      spacesScanned++;
      final publication =
          await buildSpacePublicDiscoveryPublication(spaceId) ??
          await _replicatePublicSpaceDiscovery(spaceId);
      if (publication == null) continue;
      final payload = publication.discovery;
      final lastPublished =
          _publishedPublicSpaceDescriptors[payload.descriptor.spaceId.hex];
      final publishNow = DateTime.now().millisecondsSinceEpoch;
      if (!forceHolderRefresh &&
          lastPublished?.descriptorHash == payload.descriptor.descriptorHash &&
          publishNow - lastPublished!.publishedAtMs <
              const Duration(minutes: 25).inMilliseconds) {
        continue;
      }
      final routes = <SpaceDiscoveryCarrierRoute>[
        SpaceDiscoveryCarrierRoute.direct(payload.descriptor.spaceId),
        for (final term in spaceDiscoveryPublishedSearchTerms(
          payload.descriptor.name,
        ))
          SpaceDiscoveryCarrierRoute.search(
            spaceDiscoverySearchTokenHash(term),
          ),
      ];
      final records = <Uint8List>[];
      try {
        for (final route in routes) {
          records.add(
            SpaceDiscoveryCarrier.sign(
              route: route,
              payload: payload,
              holder: selfId,
              holderPublicKey: _signer.selfPubKey,
              sign: _signer.signDetached,
            ).toBytes(),
          );
        }
      } catch (_) {
        failures += routes.length;
        continue;
      }
      var publishedForSpace = 0;
      // Four concurrent native calls keep the first publication responsive
      // without opening one runtime/fan-out for every prefix at once.
      for (var offset = 0; offset < records.length; offset += 4) {
        final end = min(offset + 4, records.length);
        final results = await Future.wait<bool>([
          for (final record in records.sublist(offset, end))
            () async {
              try {
                await transport.publish(record);
                return true;
              } catch (_) {
                return false;
              }
            }(),
        ]);
        for (final result in results) {
          if (result) {
            recordsPublished++;
            publishedForSpace++;
          } else {
            failures++;
          }
        }
      }
      if (publishedForSpace > 0) spacesPublished++;
      if (publishedForSpace == records.length) {
        _publishedPublicSpaceDescriptors[payload.descriptor.spaceId.hex] = (
          descriptorHash: payload.descriptor.descriptorHash,
          publishedAtMs: publishNow,
        );
        await _cacheVerifiedPublicFeed(payload.descriptor, publication.feed);
      }
    }
    return SpaceDiscoveryPublishSweep(
      spacesScanned: spacesScanned,
      spacesPublished: spacesPublished,
      recordsPublished: recordsPublished,
      failures: failures,
      available: true,
    );
  }

  /// Resolve a public Space by its exact id. Exact-link bootstrap needs one
  /// valid holder because the immutable owner signature is still authoritative.
  Future<SpacePublicDiscoveryResult?> resolvePublicSpaceDiscovery(
    NodeId spaceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final route = SpaceDiscoveryCarrierRoute.direct(spaceId);
    final records = await _resolvePublicDiscoveryRoute(route, timeout: timeout);
    final merged = _mergePublicDiscoveryResults(
      records,
      minimumIndependentHolders: 1,
    );
    for (final result in merged) {
      if (result.descriptor.spaceId == spaceId) return result;
    }
    return null;
  }

  Future<SpacePublicDescriptor?> resolvePublicSpace(
    NodeId spaceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async => (await resolvePublicSpaceDiscovery(
    spaceId,
    timeout: timeout,
  ))?.descriptor;

  /// Search the public index. Global results require the same owner descriptor
  /// hash to be observed from at least two independent holder identities.
  Future<List<SpacePublicDiscoveryResult>> searchPublicSpaceDiscovery(
    String query, {
    Duration timeout = const Duration(seconds: 8),
    int minimumIndependentHolders = 2,
  }) async {
    final outcome = await searchPublicSpaceDiscoveryOutcome(
      query,
      timeout: timeout,
      minimumIndependentHolders: minimumIndependentHolders,
    );
    return outcome.results;
  }

  /// Search plus a bounded availability/quorum diagnostic for interactive
  /// clients. One-holder matches never become results for global search; they
  /// only produce [SpacePublicDiscoverySearchStatus.partialQuorum].
  Future<SpacePublicDiscoverySearchOutcome> searchPublicSpaceDiscoveryOutcome(
    String query, {
    Duration timeout = const Duration(seconds: 8),
    int minimumIndependentHolders = 2,
  }) async {
    final terms = spaceDiscoveryQueryTerms(query);
    if (terms.isEmpty) {
      return SpacePublicDiscoverySearchOutcome(
        status: SpacePublicDiscoverySearchStatus.available,
        results: const [],
      );
    }
    if (_spaceDiscoveryTransport == null) {
      return SpacePublicDiscoverySearchOutcome(
        status: SpacePublicDiscoverySearchStatus.unavailable,
        results: const [],
      );
    }
    final payloads = <SpacePublicDiscoveryPayload>[];
    var routeAvailable = false;
    for (var offset = 0; offset < terms.length; offset += 2) {
      final end = min(offset + 2, terms.length);
      final batches = await Future.wait([
        for (final term in terms.sublist(offset, end))
          _resolvePublicDiscoveryRouteWithAvailability(
            SpaceDiscoveryCarrierRoute.search(
              spaceDiscoverySearchTokenHash(term),
            ),
            timeout: timeout,
          ),
      ]);
      for (final batch in batches) {
        routeAvailable = routeAvailable || batch.available;
        payloads.addAll(batch.payloads);
      }
    }
    if (!routeAvailable) {
      return SpacePublicDiscoverySearchOutcome(
        status: SpacePublicDiscoverySearchStatus.unavailable,
        results: const [],
      );
    }
    final results = _mergePublicDiscoveryResults(
      payloads,
      minimumIndependentHolders: minimumIndependentHolders,
      query: query,
    );
    final partial =
        results.isEmpty &&
        minimumIndependentHolders > 1 &&
        _mergePublicDiscoveryResults(
          payloads,
          minimumIndependentHolders: 1,
          query: query,
        ).isNotEmpty;
    return SpacePublicDiscoverySearchOutcome(
      status: partial
          ? SpacePublicDiscoverySearchStatus.partialQuorum
          : SpacePublicDiscoverySearchStatus.available,
      results: results,
    );
  }

  Future<List<SpacePublicDescriptor>> searchPublicSpaces(
    String query, {
    Duration timeout = const Duration(seconds: 8),
    int minimumIndependentHolders = 2,
  }) async => [
    for (final result in await searchPublicSpaceDiscovery(
      query,
      timeout: timeout,
      minimumIndependentHolders: minimumIndependentHolders,
    ))
      result.descriptor,
  ];

  List<SpacePublicDiscoveryResult> _mergePublicDiscoveryResults(
    Iterable<SpacePublicDiscoveryPayload> payloads, {
    required int minimumIndependentHolders,
    String? query,
  }) {
    final rows = payloads.toList(growable: false);
    final nowMs = _now();
    final descriptors = mergeSpacePublicDiscovery(
      descriptors: [for (final payload in rows) payload.descriptor],
      holders: [for (final payload in rows) payload.holder],
      nowMs: nowMs,
      verify: _signer.verifyDetached,
      minimumIndependentHolders: minimumIndependentHolders,
      query: query ?? '',
    );
    final results = <SpacePublicDiscoveryResult>[];
    for (final descriptor in descriptors) {
      final holders = <String, SpacePublicHolderAnnouncement>{};
      for (final payload in rows) {
        final holder = payload.holder;
        if (payload.descriptor.descriptorHash != descriptor.descriptorHash ||
            holder.spaceId != descriptor.spaceId ||
            holder.descriptorHash != descriptor.descriptorHash ||
            holder.publicFeedManifestHash !=
                descriptor.publicFeedManifestHash ||
            !holder.verifyAt(nowMs, _signer.verifyDetached)) {
          continue;
        }
        holders[holder.holder.hex] = holder;
      }
      final ordered = holders.values.toList()
        ..sort((left, right) => left.holder.hex.compareTo(right.holder.hex));
      if (ordered.length >= minimumIndependentHolders) {
        results.add(
          SpacePublicDiscoveryResult(descriptor: descriptor, holders: ordered),
        );
      }
    }
    return List<SpacePublicDiscoveryResult>.unmodifiable(results);
  }

  Future<List<SpacePublicDiscoveryPayload>> _resolvePublicDiscoveryRoute(
    SpaceDiscoveryCarrierRoute route, {
    required Duration timeout,
  }) async {
    final result = await _resolvePublicDiscoveryRouteWithAvailability(
      route,
      timeout: timeout,
    );
    return result.payloads;
  }

  Future<({List<SpacePublicDiscoveryPayload> payloads, bool available})>
  _resolvePublicDiscoveryRouteWithAvailability(
    SpaceDiscoveryCarrierRoute route, {
    required Duration timeout,
  }) async {
    final transport = _spaceDiscoveryTransport;
    if (transport == null) {
      return (
        payloads: const <SpacePublicDiscoveryPayload>[],
        available: false,
      );
    }
    final List<Uint8List> records;
    try {
      records = await transport.resolve(route, timeout: timeout);
    } catch (_) {
      return (
        payloads: const <SpacePublicDiscoveryPayload>[],
        available: false,
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final payloads = <SpacePublicDiscoveryPayload>[];
    final seen = <String>{};
    for (final bytes in records) {
      final carrier = SpaceDiscoveryCarrier.fromBytes(bytes);
      if (carrier == null ||
          !carrier.route.sameAs(route) ||
          !carrier.verifyAt(now, _signer.verifyDetached)) {
        continue;
      }
      final payload = SpacePublicDiscoveryPayload.fromBytes(carrier.payload);
      if (payload == null) continue;
      final identity =
          '${payload.descriptor.descriptorHash}:${payload.holder.holder.hex}';
      if (seen.add(identity)) payloads.add(payload);
      if (payloads.length >= 5) break;
    }
    return (
      payloads: List<SpacePublicDiscoveryPayload>.unmodifiable(payloads),
      available: true,
    );
  }

  void _purgePublicFeedTransportState() {
    final cutoff = _now() - kSpacePublicFeedRequestWindow.inMilliseconds;
    final expired = [
      for (final entry in _pendingPublicFeedObjects.entries)
        if (entry.value.createdAtMs < cutoff) entry.key,
    ];
    for (final nonce in expired) {
      final pending = _pendingPublicFeedObjects.remove(nonce);
      if (pending != null && !pending.completer.isCompleted) {
        pending.completer.complete(null);
      }
    }
    _publicFeedServeQuotas.removeWhere(
      (_, quota) => quota.windowStartedAtMs < cutoff,
    );
    _publicMediaServeQuotas.removeWhere(
      (_, quota) => quota.windowStartedAtMs < cutoff,
    );
    _seenPublicMediaRequests.removeWhere((_, seenAtMs) => seenAtMs < cutoff);
  }

  String _freshPublicFeedNonce() {
    final random = Random.secure();
    String nonce;
    do {
      nonce = List<int>.generate(
        32,
        (_) => random.nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    } while (_pendingPublicFeedObjects.containsKey(nonce));
    return nonce;
  }

  Future<Uint8List?> _requestPublicFeedObject({
    required NodeId holder,
    required SpacePublicDescriptor descriptor,
    required String objectHash,
    required Duration timeout,
  }) async {
    final send = sendPublicFeedRequest;
    if (send == null || holder == selfId) return null;
    _purgePublicFeedTransportState();
    if (_pendingPublicFeedObjects.length >= _kMaxPendingPublicFeedObjects) {
      return null;
    }
    final nonce = _freshPublicFeedNonce();
    final createdAtMs = _now();
    final unsigned = SpacePublicFeedObjectRequest(
      spaceId: descriptor.spaceId,
      descriptorHash: descriptor.descriptorHash,
      manifestHash: descriptor.publicFeedManifestHash,
      objectHash: objectHash,
      requester: selfId,
      requesterPublicKey: _signer.selfPubKey,
      nonce: nonce,
      createdAtMs: createdAtMs,
    );
    final signed = _signer.signDetached(unsigned.canonicalBytes());
    if (!_listEquals(signed.publicKey, _signer.selfPubKey)) return null;
    final request = unsigned.withSignature(signed.signature);
    if (!request.verifyAt(createdAtMs, selfId, _signer.verifyDetached)) {
      return null;
    }
    final pending = _PendingPublicFeedObject(
      spaceId: descriptor.spaceId,
      holder: holder,
      manifestHash: descriptor.publicFeedManifestHash,
      objectHash: objectHash,
      createdAtMs: createdAtMs,
    );
    _pendingPublicFeedObjects[nonce] = pending;
    try {
      await send(holder, jsonEncode(request.toJson()));
    } catch (_) {
      _pendingPublicFeedObjects.remove(nonce);
      return null;
    }
    final timedOut = Completer<Uint8List?>();
    final timeoutTimer = Timer(timeout, () => timedOut.complete(null));
    final result = await Future.any<Uint8List?>([
      pending.completer.future,
      timedOut.future,
    ]);
    timeoutTimer.cancel();
    _pendingPublicFeedObjects.remove(nonce);
    if (!pending.completer.isCompleted) pending.completer.complete(null);
    return result;
  }

  /// Holder-side live-only object service. Invalid, uncommitted or over-quota
  /// requests are silent so the path exposes neither membership nor cache
  /// state beyond the descriptor the requester already resolved from DHT.
  Future<void> handlePublicFeedObjectRequest(
    NodeId peer,
    String requestJson,
  ) async {
    final send = sendPublicFeedChunk;
    if (send == null) return;
    final SpacePublicFeedObjectRequest? request;
    try {
      request = SpacePublicFeedObjectRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      return;
    }
    final nowMs = _now();
    if (request == null ||
        request.requester != peer ||
        !request.isStructurallyValidAt(nowMs)) {
      return;
    }
    _purgePublicFeedTransportState();
    final quota = _publicFeedServeQuotas[peer.hex];
    final currentQuota =
        quota == null ||
            nowMs - quota.windowStartedAtMs >
                kSpacePublicFeedRequestWindow.inMilliseconds
        ? (windowStartedAtMs: nowMs, requests: 0)
        : quota;
    if (currentQuota.requests >= _kPublicFeedServeRequestsPerWindow) {
      return;
    }
    if (_publicFeedServeQuotas.length >= _kMaxPublicFeedServeQuotaIdentities &&
        !_publicFeedServeQuotas.containsKey(peer.hex)) {
      _publicFeedServeQuotas.remove(_publicFeedServeQuotas.keys.first);
    }
    _publicFeedServeQuotas[peer.hex] = (
      windowStartedAtMs: currentQuota.windowStartedAtMs,
      requests: currentQuota.requests + 1,
    );
    if (!request.verifyAt(nowMs, peer, _signer.verifyDetached)) return;

    final cached = await _loadOrRebuildVerifiedPublicFeed(
      spaceId: request.spaceId,
      descriptorHash: request.descriptorHash,
      manifestHash: request.manifestHash,
    );
    if (cached == null) return;
    final Uint8List? bytes;
    if (request.objectHash == request.manifestHash) {
      bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(cached.feed.manifest.toJson())),
      );
    } else {
      SpacePublicFeedPage? page;
      for (final candidate in cached.feed.pages) {
        if (candidate.contentHash == request.objectHash) {
          page = candidate;
          break;
        }
      }
      SpacePublicDiscussionPage? discussionPage;
      if (page == null) {
        for (final candidate in cached.feed.discussionPages) {
          if (candidate.contentHash == request.objectHash) {
            discussionPage = candidate;
            break;
          }
        }
      }
      bytes = page?.canonicalBytes() ?? discussionPage?.canonicalBytes();
    }
    if (bytes == null ||
        bytes.isEmpty ||
        bytes.length > kSpacePublicFeedObjectMaxBytes) {
      return;
    }
    for (final chunk in chunkSpacePublicFeedObject(
      spaceId: request.spaceId,
      manifestHash: request.manifestHash,
      objectHash: request.objectHash,
      nonce: request.nonce,
      bytes: bytes,
    )) {
      try {
        await send(peer, jsonEncode(chunk.toJson()));
      } catch (_) {
        return;
      }
    }
  }

  /// Holder-side public media gate. This never treats the requester as a
  /// member: the only authority is an exact, still-live verified public
  /// descriptor/feed package that names [SpacePublicMediaGrantRequest.contentId].
  /// Invalid, replayed, unreferenced and unavailable requests are all silent.
  Future<void> handlePublicMediaGrantRequest(
    NodeId peer,
    String requestJson,
  ) async {
    final grant = grantPublicContentServe;
    if (grant == null) return;
    final SpacePublicMediaGrantRequest? request;
    try {
      request = SpacePublicMediaGrantRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      return;
    }
    final nowMs = _now();
    if (request == null ||
        request.requester != peer ||
        !request.isStructurallyValidAt(nowMs)) {
      return;
    }

    _purgePublicFeedTransportState();
    final quota = _publicMediaServeQuotas[peer.hex];
    final currentQuota =
        quota == null ||
            nowMs - quota.windowStartedAtMs >
                kSpacePublicMediaGrantRequestWindow.inMilliseconds
        ? (windowStartedAtMs: nowMs, requests: 0)
        : quota;
    if (currentQuota.requests >= _kPublicMediaServeRequestsPerWindow) return;
    if (_publicMediaServeQuotas.length >=
            _kMaxPublicMediaServeQuotaIdentities &&
        !_publicMediaServeQuotas.containsKey(peer.hex)) {
      _publicMediaServeQuotas.remove(_publicMediaServeQuotas.keys.first);
    }
    _publicMediaServeQuotas[peer.hex] = (
      windowStartedAtMs: currentQuota.windowStartedAtMs,
      requests: currentQuota.requests + 1,
    );
    if (!request.verifyAt(nowMs, peer, _signer.verifyDetached)) return;

    final replayKey = '${peer.hex}:${request.nonce}';
    if (_seenPublicMediaRequests.containsKey(replayKey)) return;
    while (_seenPublicMediaRequests.length >= _kMaxSeenPublicMediaRequests) {
      _seenPublicMediaRequests.remove(_seenPublicMediaRequests.keys.first);
    }
    _seenPublicMediaRequests[replayKey] = nowMs;

    final cached = await _loadOrRebuildVerifiedPublicFeed(
      spaceId: request.spaceId,
      descriptorHash: request.descriptorHash,
      manifestHash: request.manifestHash,
    );
    if (cached == null) return;
    final descriptor = cached.descriptor;
    final referenced =
        cached.feed
            .verifiedReferencedContentIds(_signer.verifyDetached)
            .contains(request.contentId) ||
        descriptor.avatarContentId == request.contentId ||
        descriptor.coverContentId == request.contentId;
    if (!referenced) return;

    // The ordinary stream server remains the single byte-serving
    // implementation. Its exact `(peer, CID, TTL)` gate keeps this public
    // capability from becoming a generic stranger or membership permission.
    grant(peer, request.contentId);
  }

  /// Requester-side bounded reassembly. Unsolicited chunks and chunks from a
  /// different authenticated holder never allocate a slot.
  void handlePublicFeedObjectChunk(NodeId peer, String chunkJson) {
    final SpacePublicFeedObjectChunk? chunk;
    try {
      chunk = SpacePublicFeedObjectChunk.fromJson(jsonDecode(chunkJson));
    } catch (_) {
      return;
    }
    if (chunk == null) return;
    _purgePublicFeedTransportState();
    final pending = _pendingPublicFeedObjects[chunk.nonce];
    if (pending == null ||
        pending.holder != peer ||
        pending.spaceId != chunk.spaceId ||
        pending.manifestHash != chunk.manifestHash ||
        pending.objectHash != chunk.objectHash ||
        (pending.count != null && pending.count != chunk.count) ||
        (pending.totalBytes != null &&
            pending.totalBytes != chunk.totalBytes)) {
      return;
    }
    pending.count ??= chunk.count;
    pending.totalBytes ??= chunk.totalBytes;
    if (pending.parts.containsKey(chunk.index)) return;
    pending.parts[chunk.index] = Uint8List.fromList(chunk.data);
    if (pending.parts.length != chunk.count) return;
    final joined = BytesBuilder(copy: false);
    for (var index = 0; index < chunk.count; index++) {
      final part = pending.parts[index];
      if (part == null) return;
      joined.add(part);
    }
    final bytes = joined.toBytes();
    if (bytes.length != chunk.totalBytes) {
      if (!pending.completer.isCompleted) pending.completer.complete(null);
      return;
    }
    final hashMatches = chunk.objectHash == chunk.manifestHash
        ? SpacePublicFeedManifest.fromJson(
                _decodePublicFeedObjectJson(bytes),
              )?.manifestHash ==
              chunk.objectHash
        : crypto.sha256.convert(bytes).toString() == chunk.objectHash;
    if (!hashMatches) {
      if (!pending.completer.isCompleted) pending.completer.complete(null);
      return;
    }
    if (!pending.completer.isCompleted) pending.completer.complete(bytes);
  }

  /// Request one verified public media object without materializing a fake
  /// membership. The caller must already have fetched and verified this exact
  /// descriptor/feed pair. Every selected holder independently repeats that
  /// reference check before opening its stream gate.
  Future<bool> requestPublicSpaceMedia(
    SpacePublicDescriptor descriptor,
    Iterable<SpacePublicHolderAnnouncement> holders,
    String contentId,
  ) async {
    final send = sendPublicMediaGrantRequest;
    if (send == null ||
        (startPublicContentPullFromAny == null && startContentPull == null) ||
        !_sharedContentIdPattern.hasMatch(contentId)) {
      return false;
    }
    final nowMs = _now();
    if (!descriptor.verifyAt(nowMs, _signer.verifyDetached)) return false;
    final cached = await _loadOrRebuildVerifiedPublicFeed(
      spaceId: descriptor.spaceId,
      descriptorHash: descriptor.descriptorHash,
      manifestHash: descriptor.publicFeedManifestHash,
    );
    if (cached == null ||
        cached.descriptor.descriptorHash != descriptor.descriptorHash ||
        !(cached.feed
                .verifiedReferencedContentIds(_signer.verifyDetached)
                .contains(contentId) ||
            descriptor.avatarContentId == contentId ||
            descriptor.coverContentId == contentId)) {
      return false;
    }

    final candidates = <String, NodeId>{};
    for (final holder in holders) {
      if (holder.holder == selfId ||
          holder.spaceId != descriptor.spaceId ||
          holder.descriptorHash != descriptor.descriptorHash ||
          holder.publicFeedManifestHash != descriptor.publicFeedManifestHash ||
          !holder.verifyAt(nowMs, _signer.verifyDetached)) {
        continue;
      }
      candidates[holder.holder.hex] = holder.holder;
      if (candidates.length >= _kPublicMediaHolderFanout) break;
    }
    if (candidates.isEmpty) return false;

    final requested = <NodeId>[];
    for (final holder in candidates.values) {
      final createdAtMs = _now();
      final unsigned = SpacePublicMediaGrantRequest(
        spaceId: descriptor.spaceId,
        descriptorHash: descriptor.descriptorHash,
        manifestHash: descriptor.publicFeedManifestHash,
        contentId: contentId,
        requester: selfId,
        requesterPublicKey: _signer.selfPubKey,
        nonce: _freshPublicFeedNonce(),
        createdAtMs: createdAtMs,
      );
      final signed = _signer.signDetached(unsigned.canonicalBytes());
      if (!_listEquals(signed.publicKey, _signer.selfPubKey)) continue;
      final request = unsigned.withSignature(signed.signature);
      if (!request.verifyAt(createdAtMs, selfId, _signer.verifyDetached)) {
        continue;
      }
      try {
        await send(holder, jsonEncode(request.toJson()));
        requested.add(holder);
      } catch (_) {
        // Try the remaining independently verified holders.
      }
    }
    if (requested.isEmpty) return false;
    if (contentGrantDelay > Duration.zero) {
      await Future<void>.delayed(contentGrantDelay);
    }
    final pullAny = startPublicContentPullFromAny;
    if (pullAny != null) {
      await pullAny(List<NodeId>.unmodifiable(requested), contentId);
    } else {
      await startContentPull!(requested.first, contentId);
    }
    return true;
  }

  Object? _decodePublicFeedObjectJson(Uint8List bytes) {
    try {
      return jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } catch (_) {
      return null;
    }
  }

  /// Fetch and independently verify one exact descriptor's complete bounded
  /// public snapshot from any holder that signed that descriptor/feed pair.
  Future<SpacePublicFeedProjection?> fetchVerifiedPublicSpaceFeed(
    SpacePublicDescriptor descriptor,
    Iterable<SpacePublicHolderAnnouncement> holders, {
    Duration objectTimeout = const Duration(seconds: 8),
  }) async {
    final nowMs = _now();
    if (!descriptor.verifyAt(nowMs, _signer.verifyDetached)) return null;
    final candidates = <String, SpacePublicHolderAnnouncement>{};
    for (final holder in holders) {
      if (holder.holder == selfId ||
          holder.spaceId != descriptor.spaceId ||
          holder.descriptorHash != descriptor.descriptorHash ||
          holder.publicFeedManifestHash != descriptor.publicFeedManifestHash ||
          !holder.verifyAt(nowMs, _signer.verifyDetached)) {
        continue;
      }
      candidates[holder.holder.hex] = holder;
    }
    for (final holder in candidates.values) {
      final manifestBytes = await _requestPublicFeedObject(
        holder: holder.holder,
        descriptor: descriptor,
        objectHash: descriptor.publicFeedManifestHash,
        timeout: objectTimeout,
      );
      final manifest = manifestBytes == null
          ? null
          : SpacePublicFeedManifest.fromJson(
              _decodePublicFeedObjectJson(manifestBytes),
            );
      if (manifest == null ||
          manifest.manifestHash != descriptor.publicFeedManifestHash ||
          manifest.controlHeadHash != descriptor.controlHeadHash ||
          manifest.revision != descriptor.publicFeedRevision ||
          manifest.updatedAtMs != descriptor.publicFeedUpdatedAtMs ||
          manifest.itemCount != descriptor.publicPostCount ||
          manifest.pageHashes.length + manifest.discussionPageHashes.length >
              _kPublicFeedServeRequestsPerWindow - 1 ||
          !manifest.verifyAt(
            nowMs: _now(),
            expectedSpaceId: descriptor.spaceId,
            expectedPublisher: descriptor.publisher,
            publisherPublicKey: descriptor.publisherPublicKey,
            verify: _signer.verifyDetached,
          )) {
        continue;
      }
      final pages = <SpacePublicFeedPage>[];
      var totalBytes = manifestBytes!.length;
      var failed = false;
      for (var offset = 0; offset < manifest.pageHashes.length; offset += 4) {
        final end = min(offset + 4, manifest.pageHashes.length);
        final batch = await Future.wait([
          for (final hash in manifest.pageHashes.sublist(offset, end))
            _requestPublicFeedObject(
              holder: holder.holder,
              descriptor: descriptor,
              objectHash: hash,
              timeout: objectTimeout,
            ),
        ]);
        for (var index = 0; index < batch.length; index++) {
          final bytes = batch[index];
          final expectedIndex = offset + index;
          final page = bytes == null
              ? null
              : SpacePublicFeedPage.fromBytes(bytes);
          if (page == null ||
              page.index != expectedIndex ||
              !page.verify(
                expectedHash: manifest.pageHashes[expectedIndex],
                verifyPost: _signer.verifyPost,
              )) {
            failed = true;
            break;
          }
          totalBytes += bytes!.length;
          if (totalBytes > kSpacePublicFeedProjectionMaxBytes) {
            failed = true;
            break;
          }
          pages.add(page);
        }
        if (failed) break;
      }
      if (failed) continue;
      final discussionPages = <SpacePublicDiscussionPage>[];
      for (
        var offset = 0;
        offset < manifest.discussionPageHashes.length;
        offset += 4
      ) {
        final end = min(offset + 4, manifest.discussionPageHashes.length);
        final batch = await Future.wait([
          for (final hash in manifest.discussionPageHashes.sublist(offset, end))
            _requestPublicFeedObject(
              holder: holder.holder,
              descriptor: descriptor,
              objectHash: hash,
              timeout: objectTimeout,
            ),
        ]);
        for (var index = 0; index < batch.length; index++) {
          final bytes = batch[index];
          final expectedIndex = offset + index;
          final page = bytes == null
              ? null
              : SpacePublicDiscussionPage.fromBytes(bytes);
          if (page == null ||
              page.index != expectedIndex ||
              !page.verify(
                expectedHash: manifest.discussionPageHashes[expectedIndex],
                verifySignature: _signer.verifyDetached,
              )) {
            failed = true;
            break;
          }
          totalBytes += bytes!.length;
          if (totalBytes > kSpacePublicFeedProjectionMaxBytes) {
            failed = true;
            break;
          }
          discussionPages.add(page);
        }
        if (failed) break;
      }
      if (failed) continue;
      final projection = SpacePublicFeedProjection(
        manifest: manifest,
        pages: pages,
        discussionPages: discussionPages,
      );
      if (!projection.verifyAt(
        nowMs: _now(),
        expectedManifestHash: descriptor.publicFeedManifestHash,
        expectedSpaceId: descriptor.spaceId,
        expectedPublisher: descriptor.publisher,
        publisherPublicKey: descriptor.publisherPublicKey,
        expectedControlHeadHash: descriptor.controlHeadHash,
        verifySignature: _signer.verifyDetached,
        verifyPost: _signer.verifyPost,
      )) {
        continue;
      }
      await _cacheVerifiedPublicFeed(descriptor, projection);
      return projection;
    }
    return null;
  }

  /// Periodically refresh only the short holder layer. The owner descriptor is
  /// stable until signed profile/control state changes, preserving quorum.
  void startPublicSpaceDiscoveryMaintenance() {
    if (_spaceDiscoveryTransport == null ||
        _spaceDiscoveryPublishTimer != null ||
        _disposed) {
      return;
    }
    if (!_spaceDiscoveryChangesBound) {
      _spaceDiscoveryChangesBound = true;
      changes.addListener(_nudgePublicSpaceDiscovery);
    }
    unawaited(_runPublicSpaceDiscoveryMaintenance());
    _spaceDiscoveryPublishTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(_runPublicSpaceDiscoveryMaintenance()),
    );
  }

  void _nudgePublicSpaceDiscovery() {
    if (_disposed || _spaceDiscoveryTransport == null) return;
    _spaceDiscoveryNudgeTimer?.cancel();
    _spaceDiscoveryNudgeTimer = Timer(
      const Duration(seconds: 2),
      () => unawaited(
        _runPublicSpaceDiscoveryMaintenance(forceHolderRefresh: false),
      ),
    );
  }

  Future<void> _runPublicSpaceDiscoveryMaintenance({
    bool forceHolderRefresh = true,
  }) async {
    if (_spaceDiscoveryPublishRunning) {
      _spaceDiscoveryPublishWakeRequested = true;
      return;
    }
    if (_disposed) return;
    _spaceDiscoveryPublishRunning = true;
    try {
      final sweep = await publishPublicSpaceDiscovery(
        forceHolderRefresh: forceHolderRefresh,
      );
      devLog(
        () =>
            'xVeil[space-discovery]: scanned=${sweep.spacesScanned} '
            'spaces=${sweep.spacesPublished} records=${sweep.recordsPublished} '
            'failures=${sweep.failures}',
      );
      await _refreshPublicSubscriptionsSweep();
    } catch (_) {
      devLog(() => 'xVeil[space-discovery]: publication sweep failed');
    } finally {
      _spaceDiscoveryPublishRunning = false;
    }
    if (_spaceDiscoveryPublishWakeRequested && !_disposed) {
      _spaceDiscoveryPublishWakeRequested = false;
      unawaited(_runPublicSpaceDiscoveryMaintenance(forceHolderRefresh: false));
    }
  }

  Future<void> _refreshPublicSubscriptionsSweep() async {
    final subscriptions = await publicSpaceSubscriptions();
    if (subscriptions.isEmpty) {
      _publicSubscriptionRefreshCursor = 0;
      return;
    }
    final count = min(_kPublicSubscriptionRefreshBatch, subscriptions.length);
    final selected = <NodeId>[];
    for (var offset = 0; offset < count; offset++) {
      selected.add(
        subscriptions[(_publicSubscriptionRefreshCursor + offset) %
                subscriptions.length]
            .descriptor
            .spaceId,
      );
    }
    _publicSubscriptionRefreshCursor =
        (_publicSubscriptionRefreshCursor + count) % subscriptions.length;
    // Four exact lookups in flight keep refresh bounded without serially
    // multiplying the native timeout across every local subscription.
    for (var offset = 0; offset < selected.length; offset += 4) {
      final end = min(offset + 4, selected.length);
      await Future.wait([
        for (final spaceId in selected.sublist(offset, end))
          refreshPublicSpaceSubscription(spaceId).catchError((_) => null),
      ]);
    }
  }

  Future<bool> revokeSpaceJoinCode(NodeId spaceId) => _serializeSpaceJoins(
    () async {
      final store = await _loadSpaceJoins();
      final revokedTicketIds = <String>{
        for (final ticket in store.tickets)
          if (ticket.spaceId == spaceId && ticket.approver == selfId)
            ticket.ticketId,
      };
      final tickets = [
        for (final ticket in store.tickets)
          if (!(ticket.spaceId == spaceId && ticket.approver == selfId)) ticket,
      ];
      if (tickets.length == store.tickets.length) return false;
      await _saveSpaceJoins(
        tickets: tickets,
        incoming: [
          for (final entry in store.incoming)
            if (!entry.pending ||
                !revokedTicketIds.contains(entry.request.ticketId))
              entry,
        ],
        outgoing: store.outgoing,
      );
      changes.value++;
      return true;
    },
  );

  /// Create a signed, public recommendation campaign. The capability is
  /// issued by an admin, while any current member with distribute permission
  /// may later carry the resulting card to explicitly selected contacts.
  Future<SpaceRecommendationCampaign?> createSpaceRecommendationCampaign(
    NodeId spaceId,
    String text,
  ) async {
    final normalized = text.trim();
    if (normalized.isEmpty || normalized.length > 1000) return null;
    return _serialized(spaceId, () async {
      final bundle = await load(spaceId);
      if (bundle == null ||
          !bundle.manifest.isSpace ||
          bundle.manifest.visibility != SpaceVisibility.public) {
        return null;
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      if (!state.isActive ||
          !state.recommendationsEnabled ||
          !SpaceAcl(
            state,
          ).allows(selfId, SpacePermission.manageRecommendations)) {
        return null;
      }
      final joinCode = await createSpaceJoinCode(spaceId);
      if (joinCode == null) return null;
      try {
        final ticket = SpaceJoinCode.parse(joinCode);
        if (ticket.isExpiredAt(_now())) return null;
      } catch (_) {
        return null;
      }
      final now = _now();
      final campaign = SpaceRecommendationCampaign(
        campaignId: _newSpaceInviteId(),
        spaceId: spaceId,
        createdBy: selfId,
        text: normalized,
        joinCode: joinCode,
        createdAtMs: now,
        changedAtMs: now,
        active: true,
      );
      final applied = await _addControlOp(
        spaceId,
        ControlOp.setRecommendationCampaign,
        recommendationCampaign: campaign,
        createdAtMs: now,
      );
      return applied ? campaign : null;
    });
  }

  /// Publish one complete signed Space-wide recommendation posture.
  ///
  /// The optimistic revision prevents two administrative devices from
  /// silently overwriting each other. Fixed sender rate limits deliberately
  /// remain outside this policy and cannot be weakened by a Space admin.
  Future<SpaceRecommendationPolicy?> setSpaceRecommendationPolicy(
    NodeId spaceId, {
    required int expectedRevision,
    required bool enabled,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final current = state.recommendationPolicy;
    if (!state.isActive ||
        (current?.revision ?? 0) != expectedRevision ||
        !SpaceAcl(
          state,
        ).allows(selfId, SpacePermission.manageRecommendations)) {
      return null;
    }
    final policy = SpaceRecommendationPolicy(
      spaceId: spaceId,
      revision: expectedRevision + 1,
      previousPolicyHash: current?.policyHash ?? '',
      changedBy: selfId,
      changedAtMs: _now(),
      enabled: enabled,
    );
    final applied = await _addControlOp(
      spaceId,
      ControlOp.setRecommendationPolicy,
      recommendationPolicy: policy,
      createdAtMs: policy.changedAtMs,
    );
    return applied ? policy : null;
  });

  Future<List<SpaceRecommendationCampaign>> spaceRecommendationCampaigns(
    NodeId spaceId, {
    bool includeRevoked = false,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allows(selfId, SpacePermission.view)) return const [];
    final now = _now();
    final campaigns = state.recommendationCampaigns.values.where((campaign) {
      if (includeRevoked) return true;
      if (!campaign.active) return false;
      try {
        return !SpaceJoinCode.parse(campaign.joinCode).isExpiredAt(now);
      } catch (_) {
        return false;
      }
    }).toList();
    campaigns.sort((a, b) => b.changedAtMs.compareTo(a.changedAtMs));
    return List.unmodifiable(campaigns);
  }

  Future<bool> revokeSpaceRecommendationCampaign(
    NodeId spaceId,
    String campaignId,
  ) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(
          state,
        ).allows(selfId, SpacePermission.manageRecommendations) ||
        !state.isActive) {
      return false;
    }
    final current = state.recommendationCampaignFor(campaignId);
    if (current == null || !current.active) return false;
    final now = _now();
    return _addControlOp(
      spaceId,
      ControlOp.setRecommendationCampaign,
      recommendationCampaign: SpaceRecommendationCampaign(
        campaignId: current.campaignId,
        spaceId: current.spaceId,
        createdBy: current.createdBy,
        text: current.text,
        joinCode: '',
        createdAtMs: current.createdAtMs,
        changedAtMs: now,
        active: false,
      ),
      createdAtMs: now,
    );
  });

  static const String _spaceRecommendationAuditSetting =
      'spaces.recommendations.audit.v1';
  static const int _maxSpaceRecommendationAudit = 512;
  static const int _spaceRecommendationCampaignHourlyLimit = 5;
  static const int _spaceRecommendationDailyLimit = 20;
  static const Duration _spaceRecommendationDuplicateWindow = Duration(days: 7);
  Future<void> _spaceRecommendationMutationTail = Future<void>.value();

  Future<T> _serializeSpaceRecommendations<T>(
    Future<T> Function() action,
  ) async {
    final previous = _spaceRecommendationMutationTail;
    final gate = Completer<void>();
    _spaceRecommendationMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<List<SpaceRecommendationShareAudit>> spaceRecommendationShareAudit({
    NodeId? spaceId,
  }) async {
    final raw = await _storage.getSetting(_spaceRecommendationAuditSetting);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! Map ||
          (value['v'] != 1 && value['v'] != 2) ||
          value['records'] is! List) {
        return const [];
      }
      return List.unmodifiable(
        (value['records'] as List)
            .map(SpaceRecommendationShareAudit.fromJson)
            .whereType<SpaceRecommendationShareAudit>()
            .where((record) => spaceId == null || record.spaceId == spaceId)
            .take(_maxSpaceRecommendationAudit),
      );
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveSpaceRecommendationShareAudit(
    List<SpaceRecommendationShareAudit> records,
  ) => _storage.putSetting(
    _spaceRecommendationAuditSetting,
    jsonEncode({
      'v': 2,
      'records': [
        for (final record in records.take(_maxSpaceRecommendationAudit))
          record.toJson(),
      ],
    }),
  );

  /// Explicitly share one current public campaign with one accepted contact.
  /// Membership/role is never included in the card, so a member's hidden role
  /// cannot leak through recommendation metadata.
  Future<SpaceRecommendationShareResult> shareSpaceRecommendation(
    NodeId spaceId,
    String campaignId,
    NodeId recipient,
  ) async {
    final result = await _serializeSpaceRecommendations(() async {
      final sender = sendSpaceRecommendation;
      if (sender == null || recipient == selfId) {
        return SpaceRecommendationShareResult.invalidRecipient;
      }
      final contact = await _storage.getContact(recipient);
      if (contact == null || contact.status != ContactStatus.accepted) {
        return SpaceRecommendationShareResult.invalidRecipient;
      }
      final bundle = await load(spaceId);
      if (bundle == null ||
          !bundle.manifest.isSpace ||
          bundle.manifest.visibility != SpaceVisibility.public) {
        return SpaceRecommendationShareResult.invalidCampaign;
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      if (!state.isActive ||
          !state.recommendationsEnabled ||
          !SpaceAcl(state).allows(selfId, SpacePermission.distributeContent)) {
        return SpaceRecommendationShareResult.notAllowed;
      }
      if (state.isMember(recipient)) {
        return SpaceRecommendationShareResult.alreadyMember;
      }
      final campaign = state.recommendationCampaignFor(campaignId);
      if (campaign == null || !campaign.active) {
        return SpaceRecommendationShareResult.invalidCampaign;
      }
      final now = _now();
      try {
        final ticket = SpaceJoinCode.parse(campaign.joinCode);
        if (ticket.spaceId != spaceId || ticket.isExpiredAt(now)) {
          return SpaceRecommendationShareResult.invalidCampaign;
        }
      } catch (_) {
        return SpaceRecommendationShareResult.invalidCampaign;
      }
      final records = await spaceRecommendationShareAudit();
      final duplicateCutoff =
          now - _spaceRecommendationDuplicateWindow.inMilliseconds;
      if (records.any(
        (record) =>
            record.campaignId == campaignId &&
            record.recipient == recipient &&
            record.sentAtMs >= duplicateCutoff,
      )) {
        return SpaceRecommendationShareResult.duplicate;
      }
      final hourlyCutoff = now - const Duration(hours: 1).inMilliseconds;
      final dailyCutoff = now - const Duration(days: 1).inMilliseconds;
      if (records.where((record) => record.sentAtMs >= dailyCutoff).length >=
              _spaceRecommendationDailyLimit ||
          records
                  .where(
                    (record) =>
                        record.campaignId == campaignId &&
                        record.sentAtMs >= hourlyCutoff,
                  )
                  .length >=
              _spaceRecommendationCampaignHourlyLimit) {
        return SpaceRecommendationShareResult.rateLimited;
      }
      final card = SpaceRecommendationCard(
        campaignId: campaignId,
        spaceId: spaceId,
        name: state.name,
        description: state.description,
        text: campaign.text,
        joinCode: campaign.joinCode,
      );
      final String? messageId;
      try {
        messageId = await sender(recipient, card);
        if (messageId == null || messageId.isEmpty || messageId.length > 256) {
          return SpaceRecommendationShareResult.failed;
        }
      } catch (_) {
        return SpaceRecommendationShareResult.failed;
      }
      final updated = <SpaceRecommendationShareAudit>[
        SpaceRecommendationShareAudit(
          campaignId: campaignId,
          spaceId: spaceId,
          recipient: recipient,
          sentAtMs: now,
          messageId: messageId,
        ),
        for (final record in records)
          if (record.sentAtMs >= duplicateCutoff) record,
      ];
      await _saveSpaceRecommendationShareAudit(updated);
      changes.value++;
      return SpaceRecommendationShareResult.sent;
    });
    final reason = switch (result) {
      SpaceRecommendationShareResult.invalidRecipient =>
        SpaceObservationReason.invalidInput,
      SpaceRecommendationShareResult.invalidCampaign =>
        SpaceObservationReason.invalidState,
      SpaceRecommendationShareResult.notAllowed =>
        SpaceObservationReason.permissionDenied,
      SpaceRecommendationShareResult.alreadyMember =>
        SpaceObservationReason.alreadyMember,
      SpaceRecommendationShareResult.duplicate =>
        SpaceObservationReason.duplicate,
      SpaceRecommendationShareResult.rateLimited =>
        SpaceObservationReason.rateLimited,
      SpaceRecommendationShareResult.failed =>
        SpaceObservationReason.transportFailed,
      SpaceRecommendationShareResult.sent => null,
    };
    final outcome = switch (result) {
      SpaceRecommendationShareResult.sent => SpaceObservationOutcome.succeeded,
      SpaceRecommendationShareResult.failed => SpaceObservationOutcome.failed,
      _ => SpaceObservationOutcome.rejected,
    };
    _observeSpace(
      SpaceObservationType.recommendationShared,
      outcome,
      reason: reason,
    );
    if (result == SpaceRecommendationShareResult.notAllowed) {
      _observeSpace(
        SpaceObservationType.aclDenied,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.permissionDenied,
      );
    }
    return result;
  }

  /// Revoke one already-sent recommendation by its durable message id.
  ///
  /// Revocation is intentionally independent of current Space membership or
  /// campaign state: the sender still owns the 1:1 message and must be able to
  /// retract it after leaving, archiving or deleting the Space. Legacy v1
  /// audit rows have no message id and therefore remain visible but unavailable
  /// for addressable revocation.
  Future<SpaceRecommendationRevokeResult> revokeSentSpaceRecommendation(
    String auditId,
  ) async {
    final result = await _serializeSpaceRecommendations(() async {
      final records = await spaceRecommendationShareAudit();
      final index = records.indexWhere((record) => record.stableId == auditId);
      if (index < 0) return SpaceRecommendationRevokeResult.notFound;
      final record = records[index];
      if (record.revokedAtMs != null) {
        return SpaceRecommendationRevokeResult.alreadyRevoked;
      }
      final revoker = revokeSpaceRecommendation;
      if (record.messageId == null || revoker == null) {
        return SpaceRecommendationRevokeResult.unavailable;
      }
      try {
        if (!await revoker(record.recipient, record.messageId!)) {
          return SpaceRecommendationRevokeResult.failed;
        }
      } catch (_) {
        return SpaceRecommendationRevokeResult.failed;
      }
      final updated = List<SpaceRecommendationShareAudit>.of(records);
      updated[index] = record.revokedAt(_now());
      await _saveSpaceRecommendationShareAudit(updated);
      changes.value++;
      return SpaceRecommendationRevokeResult.revoked;
    });
    final reason = switch (result) {
      SpaceRecommendationRevokeResult.notFound =>
        SpaceObservationReason.notFound,
      SpaceRecommendationRevokeResult.alreadyRevoked =>
        SpaceObservationReason.conflict,
      SpaceRecommendationRevokeResult.unavailable =>
        SpaceObservationReason.unavailable,
      SpaceRecommendationRevokeResult.failed =>
        SpaceObservationReason.transportFailed,
      SpaceRecommendationRevokeResult.revoked => null,
    };
    _observeSpace(
      SpaceObservationType.recommendationRevoked,
      result == SpaceRecommendationRevokeResult.revoked
          ? SpaceObservationOutcome.succeeded
          : result == SpaceRecommendationRevokeResult.failed
          ? SpaceObservationOutcome.failed
          : SpaceObservationOutcome.rejected,
      reason: reason,
    );
    return result;
  }

  /// Receiver-side card suppression. A current or restricted membership cannot
  /// start another proposal; a retained signed `left` state may deliberately
  /// rejoin. The recommendation card never becomes authority by itself.
  Future<bool> acceptsSpaceRecommendationCard(
    NodeId sender,
    SpaceRecommendationCard card,
  ) async {
    if (sender == selfId) return false;
    final contact = await _storage.getContact(sender);
    if (contact == null || contact.status != ContactStatus.accepted) {
      return false;
    }
    try {
      final ticket = SpaceJoinCode.parse(card.joinCode);
      if (ticket.spaceId != card.spaceId || ticket.isExpiredAt(_now())) {
        return false;
      }
    } catch (_) {
      return false;
    }
    return _canStartSpaceMembershipProposal(card.spaceId, _now());
  }

  Future<String?> currentSpaceJoinCode(NodeId spaceId) async {
    final now = _now();
    for (final ticket in (await _loadSpaceJoins()).tickets) {
      if (ticket.spaceId == spaceId &&
          ticket.approver == selfId &&
          !ticket.isExpiredAt(now)) {
        return SpaceJoinCode.encode(ticket);
      }
    }
    return null;
  }

  /// Send a requester-authenticated intent using a public bearer link. No
  /// contact relationship is required; blocked peers are still rejected.
  Future<bool> requestToJoinSpace(String code) async {
    final SpaceJoinTicket ticket;
    try {
      ticket = SpaceJoinCode.parse(code);
    } catch (_) {
      return false;
    }
    final now = _now();
    if (ticket.approver == selfId ||
        ticket.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        ticket.isExpiredAt(now) ||
        !await _canStartSpaceMembershipProposal(ticket.spaceId, now) ||
        (await _storage.getContact(ticket.approver))?.status ==
            ContactStatus.blocked ||
        sendSpaceJoinRequest == null) {
      return false;
    }
    final prepared = await _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      for (final existing in store.outgoing) {
        if (existing.ticket.spaceId == ticket.spaceId &&
            !existing.declined &&
            !existing.ticket.isExpiredAt(now)) {
          return existing;
        }
      }
      final request = SpaceJoinRequest(
        requestId: _newSpaceInviteId(),
        ticketId: ticket.ticketId,
        ticketHash: spaceJoinTicketHash(ticket),
        spaceId: ticket.spaceId,
        requester: selfId,
        approver: ticket.approver,
        createdAtMs: now < ticket.createdAtMs ? ticket.createdAtMs : now,
      );
      final entry = SpaceJoinOutboxEntry(ticket: ticket, request: request);
      if (!entry.isStructurallyValid) return null;
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: store.incoming,
        outgoing: [
          entry,
          for (final old in store.outgoing)
            if (old.ticket.spaceId != ticket.spaceId) old,
        ],
      );
      changes.value++;
      return entry;
    });
    if (prepared == null) return false;
    try {
      await sendSpaceJoinRequest!(
        prepared.request.approver,
        prepared.request.requestId,
        jsonEncode(prepared.request.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<SpaceJoinOutboxEntry>> outgoingSpaceJoinRequests() async {
    return _serializeSpaceJoins(() async {
      final now = _now();
      final store = await _loadSpaceJoins();
      final outgoing = <SpaceJoinOutboxEntry>[];
      for (final entry in store.outgoing) {
        if (entry.ticket.isExpiredAt(now) ||
            (await _storage.getContact(entry.request.approver))?.status ==
                ContactStatus.blocked) {
          continue;
        }
        final bundle = await load(entry.ticket.spaceId);
        if (bundle != null &&
            (!_validSpaceBundle(bundle) ||
                _spaceMembershipForBundle(bundle, now).status !=
                    SpaceMembershipStatus.left)) {
          continue;
        }
        if (entry.declined &&
            now - entry.decision!.decidedAtMs >
                kSpaceJoinRequestRetryDelay.inMilliseconds) {
          continue;
        }
        outgoing.add(entry);
      }
      if (outgoing.length != store.outgoing.length) {
        await _saveSpaceJoins(
          tickets: store.tickets,
          incoming: store.incoming,
          outgoing: outgoing,
        );
        changes.value++;
      }
      outgoing.sort(
        (left, right) =>
            right.request.createdAtMs.compareTo(left.request.createdAtMs),
      );
      return outgoing;
    });
  }

  bool _validSpaceBundle(GroupBundle bundle) =>
      bundle.manifest.isSpace && bundle.manifest.visibility != null;

  SpaceMembershipProjection _spaceMembershipForBundle(
    GroupBundle bundle,
    int now,
  ) {
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    );
    final state = folded.state;
    final member = state.memberOf(selfId);

    ControlEntry? latestMembershipEntry;
    ControlEntry? latestMuteEntry;
    for (final entry in folded.accepted) {
      final affectsMembership =
          (entry.op == ControlOp.addMember && entry.target == selfId) ||
          (entry.op == ControlOp.removeMember && entry.target == selfId) ||
          (entry.op == ControlOp.ban && entry.target == selfId) ||
          (entry.op == ControlOp.leave && entry.author == selfId) ||
          (entry.op == ControlOp.moderate &&
              entry.moderationAction?.target == selfId &&
              entry.moderationAction?.kind.removesMembership == true);
      if (affectsMembership) latestMembershipEntry = entry;
      if ((entry.op == ControlOp.mute || entry.op == ControlOp.unmute) &&
          entry.target == selfId) {
        latestMuteEntry = entry;
      }
    }

    SpaceModerationRecord? permanentBan;
    SpaceModerationRecord? suspension;
    for (final record in state.activeModerationFor(selfId, now)) {
      switch (record.action.kind) {
        case SpaceModerationKind.permanentBan:
          if (permanentBan == null ||
              record.action.createdAtMs > permanentBan.action.createdAtMs) {
            permanentBan = record;
          }
          break;
        case SpaceModerationKind.temporaryBan:
        case SpaceModerationKind.timeout:
          if (suspension == null ||
              record.action.createdAtMs > suspension.action.createdAtMs) {
            suspension = record;
          }
          break;
        case _:
          break;
      }
    }

    SpaceMembershipProjection fromModeration(
      SpaceModerationRecord record,
      SpaceMembershipStatus status,
    ) => SpaceMembershipProjection(
      spaceId: bundle.manifest.spaceId,
      name: state.name,
      visibility: bundle.manifest.visibility!,
      status: status,
      source: SpaceMembershipSource.moderation,
      isMember: member != null,
      changedAtMs: record.action.createdAtMs,
      untilMs: record.action.expiresAtMs,
      reason: record.action.reason,
      sourceId: record.actionId,
    );

    if (permanentBan != null) {
      return fromModeration(permanentBan, SpaceMembershipStatus.banned);
    }
    if (suspension != null) {
      return fromModeration(suspension, SpaceMembershipStatus.suspended);
    }
    if (member != null) {
      if (member.muted) {
        return SpaceMembershipProjection(
          spaceId: bundle.manifest.spaceId,
          name: state.name,
          visibility: bundle.manifest.visibility!,
          status: SpaceMembershipStatus.suspended,
          source: SpaceMembershipSource.controlLog,
          isMember: true,
          changedAtMs: latestMuteEntry?.createdAtMs ?? member.joinedAtMs,
          sourceId: latestMuteEntry == null
              ? null
              : '${latestMuteEntry.author.hex}:${latestMuteEntry.seq}',
        );
      }
      final joinedByControl = latestMembershipEntry?.op == ControlOp.addMember
          ? latestMembershipEntry
          : null;
      return SpaceMembershipProjection(
        spaceId: bundle.manifest.spaceId,
        name: state.name,
        visibility: bundle.manifest.visibility!,
        status: SpaceMembershipStatus.active,
        source: joinedByControl == null
            ? SpaceMembershipSource.manifest
            : SpaceMembershipSource.controlLog,
        isMember: true,
        changedAtMs: member.joinedAtMs == 0
            ? bundle.manifest.createdAtMs
            : member.joinedAtMs,
        sourceId: joinedByControl == null
            ? null
            : '${joinedByControl.author.hex}:${joinedByControl.seq}',
      );
    }

    final legacyBan =
        latestMembershipEntry?.op == ControlOp.ban &&
        latestMembershipEntry?.target == selfId;
    return SpaceMembershipProjection(
      spaceId: bundle.manifest.spaceId,
      name: state.name,
      visibility: bundle.manifest.visibility!,
      status: legacyBan
          ? SpaceMembershipStatus.banned
          : SpaceMembershipStatus.left,
      source: SpaceMembershipSource.controlLog,
      isMember: false,
      changedAtMs:
          latestMembershipEntry?.createdAtMs ?? bundle.manifest.createdAtMs,
      sourceId: latestMembershipEntry == null
          ? null
          : '${latestMembershipEntry.author.hex}:${latestMembershipEntry.seq}',
    );
  }

  Future<bool> _canStartSpaceMembershipProposal(NodeId spaceId, int now) async {
    final bundle = await load(spaceId);
    if (bundle == null) return true;
    if (!_validSpaceBundle(bundle)) return false;
    return _spaceMembershipForBundle(bundle, now).status ==
        SpaceMembershipStatus.left;
  }

  /// One projection over the signed control/moderation fold and the existing
  /// durable consent stores. It creates no membership row; invalidated
  /// invite/join proposals may be pruned so unblock cannot revive old consent.
  Future<List<SpaceMembershipProjection>> spaceMemberships() async {
    final now = _now();
    final bySpace = <String, SpaceMembershipProjection>{};
    for (final hex in await _index()) {
      try {
        final bundle = await load(NodeId.fromHex(hex));
        if (bundle == null || !_validSpaceBundle(bundle)) continue;
        bySpace[hex] = _spaceMembershipForBundle(bundle, now);
      } catch (_) {
        // A malformed/unverifiable bundle must not become a positive
        // membership claim or erase another independently durable proposal.
      }
    }

    void addPending({
      required NodeId spaceId,
      required String name,
      required SpaceVisibility visibility,
      required SpaceMembershipSource source,
      required int changedAtMs,
      required String sourceId,
    }) {
      final current = bySpace[spaceId.hex];
      if (current != null && current.status != SpaceMembershipStatus.left) {
        return;
      }
      bySpace[spaceId.hex] = SpaceMembershipProjection(
        spaceId: spaceId,
        name: current?.name ?? name,
        visibility: current?.visibility ?? visibility,
        status: SpaceMembershipStatus.pending,
        source: source,
        isMember: false,
        changedAtMs: changedAtMs,
        sourceId: sourceId,
      );
    }

    for (final entry in await outgoingSpaceJoinRequests()) {
      if (entry.declined) continue;
      addPending(
        spaceId: entry.ticket.spaceId,
        name: entry.ticket.spaceName,
        visibility: SpaceVisibility.public,
        source: SpaceMembershipSource.joinRequest,
        changedAtMs: entry.decision?.decidedAtMs ?? entry.request.createdAtMs,
        sourceId: entry.request.requestId,
      );
    }
    for (final entry in await pendingSpaceInvites()) {
      if (!entry.accepted) continue;
      addPending(
        spaceId: entry.invite.spaceId,
        name: entry.invite.spaceName,
        visibility: entry.invite.visibility,
        source: SpaceMembershipSource.invite,
        changedAtMs: entry.acceptedAtMs!,
        sourceId: entry.invite.inviteId,
      );
    }

    final result = bySpace.values.toList(growable: false)
      ..sort((left, right) {
        final changed = right.changedAtMs.compareTo(left.changedAtMs);
        if (changed != 0) return changed;
        return left.spaceId.hex.compareTo(right.spaceId.hex);
      });
    return result;
  }

  Future<bool> dismissSpaceJoinRequest(String requestId) =>
      _serializeSpaceJoins(() async {
        final store = await _loadSpaceJoins();
        final outgoing = [
          for (final entry in store.outgoing)
            if (entry.request.requestId != requestId) entry,
        ];
        if (outgoing.length == store.outgoing.length) return false;
        await _saveSpaceJoins(
          tickets: store.tickets,
          incoming: store.incoming,
          outgoing: outgoing,
        );
        changes.value++;
        return true;
      });

  /// Validate and durably persist one capability-bound request from an
  /// authenticated Veil sender. The ticket, current public Space policy and
  /// per-requester cooldown all have to pass before an ACK is permitted.
  Future<bool> receiveSpaceJoinRequest(NodeId peer, String requestJson) async {
    final SpaceJoinRequest? request;
    try {
      request = SpaceJoinRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      return false;
    }
    final now = _now();
    if (request == null ||
        request.requester != peer ||
        request.approver != selfId ||
        request.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final bundle = await load(request.spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (state.isMember(peer) ||
        !SpaceAcl(state).allowsControl(
          selfId,
          ControlOp.addMember,
          target: peer,
          newRole: GroupRole.member,
        )) {
      return false;
    }
    final acceptedRequest = request;
    return _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      if (_liveTicketForSpaceJoinRequest(store.tickets, acceptedRequest, now) ==
          null) {
        return false;
      }
      for (final old in store.incoming) {
        if (old.request.requestId == acceptedRequest.requestId) {
          return old.request.requester == peer &&
              old.request.spaceId == acceptedRequest.spaceId;
        }
        if (old.request.requester == peer &&
            old.request.spaceId == acceptedRequest.spaceId &&
            (old.pending ||
                now - old.decision!.decidedAtMs <
                    kSpaceJoinRequestRetryDelay.inMilliseconds)) {
          return false;
        }
      }
      final entry = SpaceJoinInboxEntry(
        request: acceptedRequest,
        receivedAtMs: now < acceptedRequest.createdAtMs
            ? acceptedRequest.createdAtMs
            : now,
      );
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: [
          entry,
          for (final old in store.incoming)
            if (!(old.request.requester == peer &&
                old.request.spaceId == acceptedRequest.spaceId))
              old,
        ],
        outgoing: store.outgoing,
      );
      changes.value++;
      return true;
    });
  }

  SpaceJoinTicket? _liveTicketForSpaceJoinRequest(
    List<SpaceJoinTicket> tickets,
    SpaceJoinRequest request,
    int now,
  ) {
    for (final ticket in tickets) {
      if (ticket.ticketId == request.ticketId &&
          ticket.spaceId == request.spaceId &&
          ticket.approver == selfId &&
          request.approver == selfId &&
          !ticket.isExpiredAt(now) &&
          request.ticketHash == spaceJoinTicketHash(ticket) &&
          request.createdAtMs >= ticket.createdAtMs &&
          request.createdAtMs < ticket.expiresAtMs) {
        return ticket;
      }
    }
    return null;
  }

  Future<List<SpaceJoinInboxEntry>> pendingSpaceJoinRequests(
    NodeId spaceId,
  ) async {
    return _serializeSpaceJoins(() async {
      final now = _now();
      final store = await _loadSpaceJoins();
      final incoming = <SpaceJoinInboxEntry>[];
      final result = <SpaceJoinInboxEntry>[];
      for (final entry in store.incoming) {
        if (entry.pending &&
            ((await _storage.getContact(entry.request.requester))?.status ==
                    ContactStatus.blocked ||
                _liveTicketForSpaceJoinRequest(
                      store.tickets,
                      entry.request,
                      now,
                    ) ==
                    null)) {
          continue;
        }
        incoming.add(entry);
        if (entry.pending && entry.request.spaceId == spaceId) {
          result.add(entry);
        }
      }
      if (incoming.length != store.incoming.length) {
        await _saveSpaceJoins(
          tickets: store.tickets,
          incoming: incoming,
          outgoing: store.outgoing,
        );
        changes.value++;
      }
      result.sort(
        (left, right) => right.receivedAtMs.compareTo(left.receivedAtMs),
      );
      return result;
    });
  }

  Future<bool> decideSpaceJoinRequest(
    String requestId, {
    required bool accept,
  }) async {
    final sender = sendSpaceJoinDecision;
    if (sender == null) return false;
    final prepared =
        await _serializeSpaceJoins<
          ({SpaceJoinRequest request, SpaceJoinDecision decision})?
        >(() async {
          final store = await _loadSpaceJoins();
          SpaceJoinInboxEntry? pending;
          for (final candidate in store.incoming) {
            if (candidate.request.requestId == requestId && candidate.pending) {
              pending = candidate;
              break;
            }
          }
          if (pending == null) return null;
          final now = _now();
          if ((await _storage.getContact(pending.request.requester))?.status ==
                  ContactStatus.blocked ||
              _liveTicketForSpaceJoinRequest(
                    store.tickets,
                    pending.request,
                    now,
                  ) ==
                  null) {
            await _saveSpaceJoins(
              tickets: store.tickets,
              incoming: [
                for (final entry in store.incoming)
                  if (entry.request.requestId != requestId) entry,
              ],
              outgoing: store.outgoing,
            );
            changes.value++;
            return null;
          }
          if (accept) {
            final added = await _addMemberFromConsent(
              pending.request.spaceId,
              pending.request.requester,
              GroupRole.member,
              requireAcceptedContact: false,
            );
            if (!added) {
              if ((await _storage.getContact(
                    pending.request.requester,
                  ))?.status ==
                  ContactStatus.blocked) {
                await _saveSpaceJoins(
                  tickets: store.tickets,
                  incoming: [
                    for (final entry in store.incoming)
                      if (entry.request.requestId != requestId) entry,
                  ],
                  outgoing: store.outgoing,
                );
                changes.value++;
              }
              return null;
            }
          }
          final decision = SpaceJoinDecision(
            requestId: requestId,
            spaceId: pending.request.spaceId,
            accepted: accept,
            decidedAtMs: now < pending.receivedAtMs
                ? pending.receivedAtMs
                : now,
          );
          await _saveSpaceJoins(
            tickets: store.tickets,
            incoming: [
              for (final entry in store.incoming)
                if (entry.request.requestId == requestId)
                  SpaceJoinInboxEntry(
                    request: entry.request,
                    receivedAtMs: entry.receivedAtMs,
                    decision: decision,
                  )
                else
                  entry,
            ],
            outgoing: store.outgoing,
          );
          changes.value++;
          return (request: pending.request, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.request.requester,
        prepared.request.requestId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> receiveSpaceJoinDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceJoinDecision? decision;
    try {
      decision = SpaceJoinDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    if (decision == null ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final acceptedDecision = decision;
    return _serializeSpaceJoins(() async {
      final store = await _loadSpaceJoins();
      SpaceJoinOutboxEntry? matched;
      for (final entry in store.outgoing) {
        if (entry.request.requestId == acceptedDecision.requestId &&
            entry.request.spaceId == acceptedDecision.spaceId &&
            entry.request.approver == peer) {
          matched = entry;
          break;
        }
      }
      if (matched == null ||
          acceptedDecision.decidedAtMs < matched.request.createdAtMs ||
          acceptedDecision.decidedAtMs >
              matched.ticket.expiresAtMs +
                  const Duration(minutes: 5).inMilliseconds) {
        return false;
      }
      if (matched.decision != null) {
        return matched.decision!.accepted == acceptedDecision.accepted &&
            matched.decision!.decidedAtMs == acceptedDecision.decidedAtMs;
      }
      await _saveSpaceJoins(
        tickets: store.tickets,
        incoming: store.incoming,
        outgoing: [
          for (final entry in store.outgoing)
            if (entry.request.requestId == acceptedDecision.requestId)
              SpaceJoinOutboxEntry(
                ticket: entry.ticket,
                request: entry.request,
                decision: acceptedDecision,
              )
            else
              entry,
        ],
      );
      changes.value++;
      return true;
    });
  }

  static const String _spaceModerationAppealsSetting =
      'spaces.moderation_appeals.v1';
  static const int _maxSpaceModerationAppealRecords = 256;
  Future<void> _spaceModerationAppealMutationTail = Future<void>.value();

  Future<T> _serializeSpaceModerationAppeals<T>(
    Future<T> Function() action,
  ) async {
    final previous = _spaceModerationAppealMutationTail;
    final gate = Completer<void>();
    _spaceModerationAppealMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<
    ({
      List<SpaceModerationAppealInboxEntry> incoming,
      List<SpaceModerationAppealOutboxEntry> outgoing,
    })
  >
  _loadSpaceModerationAppeals() async {
    final blob = await _storage.loadFile(_spaceModerationAppealsSetting);
    if (blob == null || blob.isEmpty) {
      return (
        incoming: <SpaceModerationAppealInboxEntry>[],
        outgoing: <SpaceModerationAppealOutboxEntry>[],
      );
    }
    try {
      final value = jsonDecode(utf8.decode(blob, allowMalformed: false));
      if (value is! Map || value['v'] != 1) throw const FormatException();
      return (
        incoming: (value['incoming'] as List? ?? const [])
            .map(SpaceModerationAppealInboxEntry.fromJson)
            .whereType<SpaceModerationAppealInboxEntry>()
            .take(_maxSpaceModerationAppealRecords)
            .toList(),
        outgoing: (value['outgoing'] as List? ?? const [])
            .map(SpaceModerationAppealOutboxEntry.fromJson)
            .whereType<SpaceModerationAppealOutboxEntry>()
            .take(_maxSpaceModerationAppealRecords)
            .toList(),
      );
    } catch (_) {
      return (
        incoming: <SpaceModerationAppealInboxEntry>[],
        outgoing: <SpaceModerationAppealOutboxEntry>[],
      );
    }
  }

  Future<void> _saveSpaceModerationAppeals({
    required List<SpaceModerationAppealInboxEntry> incoming,
    required List<SpaceModerationAppealOutboxEntry> outgoing,
  }) {
    final raw = jsonEncode({
      'v': 1,
      'incoming': [
        for (final entry in incoming.take(_maxSpaceModerationAppealRecords))
          entry.toJson(),
      ],
      'outgoing': [
        for (final entry in outgoing.take(_maxSpaceModerationAppealRecords))
          entry.toJson(),
      ],
    });
    return _storage.storeFile(
      _spaceModerationAppealsSetting,
      Uint8List.fromList(utf8.encode(raw)),
      name: 'moderation-appeals',
    );
  }

  Future<List<SpaceModerationRecord>> _moderationRecordsOfBundle(
    GroupBundle bundle,
    GroupState state,
  ) async {
    final records =
        <SpaceModerationRecord>[
          ...state.moderationRecords.values,
          ...await _protectedModerationRecordsOf(bundle, state),
        ]..sort((left, right) {
          final time = right.action.createdAtMs.compareTo(
            left.action.createdAtMs,
          );
          return time != 0 ? time : right.actionId.compareTo(left.actionId);
        });
    return records;
  }

  Future<SpaceModerationRecord?> _moderationRecord(
    GroupBundle bundle,
    GroupState state,
    String actionId,
  ) async {
    final clear = state.moderationRecords[actionId];
    if (clear != null) return clear;
    for (final record in await _protectedModerationRecordsOf(bundle, state)) {
      if (record.actionId == actionId) return record;
    }
    return null;
  }

  NodeId? _effectiveSpaceOwner(GroupState state) {
    for (final member in state.members.values) {
      if (member.role == GroupRole.owner) return member.nodeId;
    }
    return null;
  }

  /// Returns self-targeted actions even when the Space itself is hidden after
  /// a ban. Already appealed actions live in [outgoingSpaceModerationAppeals].
  Future<List<SpaceModerationAppealCandidate>>
  appealableSpaceModerationActions() async {
    final outgoing = (await _loadSpaceModerationAppeals()).outgoing;
    final result = <SpaceModerationAppealCandidate>[];
    for (final hex in await _index()) {
      try {
        final bundle = await load(NodeId.fromHex(hex));
        if (bundle == null || !bundle.manifest.isSpace) continue;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        final reviewer = _effectiveSpaceOwner(state);
        for (final record in await _moderationRecordsOfBundle(bundle, state)) {
          final appealed = outgoing.any(
            (entry) =>
                entry.appeal.spaceId == bundle.manifest.groupId &&
                entry.appeal.actionId == record.actionId &&
                (entry.decision != null || entry.appeal.reviewer == reviewer),
          );
          if (record.action.target == selfId &&
              record.revokedAtMs == null &&
              !appealed) {
            result.add(
              SpaceModerationAppealCandidate(
                spaceId: bundle.manifest.groupId,
                spaceName: state.name,
                record: record,
              ),
            );
          }
        }
      } catch (_) {}
    }
    result.sort(
      (left, right) => right.record.action.createdAtMs.compareTo(
        left.record.action.createdAtMs,
      ),
    );
    return result;
  }

  Future<List<SpaceModerationAppealOutboxEntry>>
  outgoingSpaceModerationAppeals() async {
    final result = (await _loadSpaceModerationAppeals()).outgoing.toList()
      ..sort(
        (left, right) =>
            right.appeal.createdAtMs.compareTo(left.appeal.createdAtMs),
      );
    return result;
  }

  Future<Map<String, String>> moderationAppealSpaceNames() async {
    final store = await _loadSpaceModerationAppeals();
    final ids = <String>{
      for (final entry in store.incoming) entry.appeal.spaceId.hex,
      for (final entry in store.outgoing) entry.appeal.spaceId.hex,
    };
    final result = <String, String>{};
    for (final hex in ids) {
      try {
        final bundle = await load(NodeId.fromHex(hex));
        if (bundle == null || !bundle.manifest.isSpace) continue;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        result[hex] = state.name;
      } catch (_) {}
    }
    return result;
  }

  Future<List<SpaceModerationAppealInboxEntry>> incomingSpaceModerationAppeals({
    NodeId? spaceId,
    bool pendingOnly = false,
  }) async {
    final result =
        (await _loadSpaceModerationAppeals()).incoming
            .where(
              (entry) =>
                  (spaceId == null || entry.appeal.spaceId == spaceId) &&
                  (!pendingOnly || entry.pending),
            )
            .toList()
          ..sort(
            (left, right) => right.receivedAtMs.compareTo(left.receivedAtMs),
          );
    return result;
  }

  /// Persist before enqueueing the external proposal. A second call for the
  /// same immutable action and current reviewer retransmits the exact signed
  /// row. An ownership transfer may create one replacement routed to the new
  /// effective owner; neither path introduces a time window.
  Future<bool> appealSpaceModeration(
    NodeId spaceId,
    String actionId, {
    required String text,
  }) async {
    final sender = sendSpaceModerationAppeal;
    if (sender == null) return false;
    final normalized = text.trim();
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final record = await _moderationRecord(bundle, state, actionId);
    final reviewer = _effectiveSpaceOwner(state);
    if (record == null ||
        record.revokedAtMs != null ||
        record.action.target != selfId ||
        reviewer == null ||
        reviewer == selfId) {
      return false;
    }
    final appeal = await _serializeSpaceModerationAppeals(() async {
      final store = await _loadSpaceModerationAppeals();
      for (final entry in store.outgoing) {
        if (entry.appeal.spaceId == spaceId &&
            entry.appeal.actionId == actionId &&
            (entry.decision != null || entry.appeal.reviewer == reviewer)) {
          return entry.decision == null ? entry.appeal : null;
        }
      }
      final now = _now();
      final unsigned = SpaceModerationAppeal(
        appealId: _newSpaceInviteId(),
        spaceId: spaceId,
        actionAuthor: record.actor,
        actionSeq: record.actionSeq,
        appellant: selfId,
        reviewer: reviewer,
        text: normalized,
        createdAtMs: now < record.action.createdAtMs
            ? record.action.createdAtMs
            : now,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      if (!unsigned.isStructurallyValid) return null;
      final signed = _signer.signModerationAppeal(unsigned);
      if (!_signer.verifyModerationAppeal(signed)) return null;
      await _saveSpaceModerationAppeals(
        incoming: store.incoming,
        outgoing: [
          SpaceModerationAppealOutboxEntry(appeal: signed),
          ...store.outgoing,
        ],
      );
      changes.value++;
      return signed;
    });
    if (appeal == null) return false;
    try {
      await sender(
        appeal.reviewer,
        appeal.appealId,
        jsonEncode(appeal.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Authenticated-source, signature, owner route and exact action checks all
  /// pass before durable persistence allows the transport ACK.
  Future<bool> receiveSpaceModerationAppeal(
    NodeId peer,
    String appealJson,
  ) async {
    final SpaceModerationAppeal? appeal;
    try {
      appeal = SpaceModerationAppeal.fromJson(jsonDecode(appealJson));
    } catch (_) {
      return false;
    }
    final now = _now();
    if (appeal == null ||
        appeal.appellant != peer ||
        appeal.reviewer != selfId ||
        appeal.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        !_signer.verifyModerationAppeal(appeal) ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final acceptedAppeal = appeal;
    final bundle = await load(acceptedAppeal.spaceId);
    if (bundle == null || !bundle.manifest.isSpace) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (_effectiveSpaceOwner(state) != selfId) return false;
    final record = await _moderationRecord(
      bundle,
      state,
      acceptedAppeal.actionId,
    );
    if (record == null ||
        record.action.target != peer ||
        acceptedAppeal.createdAtMs < record.action.createdAtMs) {
      return false;
    }
    return _serializeSpaceModerationAppeals(() async {
      final store = await _loadSpaceModerationAppeals();
      for (final old in store.incoming) {
        if (old.appeal.appealId == acceptedAppeal.appealId) {
          return jsonEncode(old.appeal.toJson()) ==
              jsonEncode(acceptedAppeal.toJson());
        }
        if (old.appeal.spaceId == acceptedAppeal.spaceId &&
            old.appeal.actionId == acceptedAppeal.actionId &&
            old.appeal.appellant == peer) {
          return false;
        }
      }
      final entry = SpaceModerationAppealInboxEntry(
        appeal: acceptedAppeal,
        receivedAtMs: now < acceptedAppeal.createdAtMs
            ? acceptedAppeal.createdAtMs
            : now,
      );
      await _saveSpaceModerationAppeals(
        incoming: [entry, ...store.incoming],
        outgoing: store.outgoing,
      );
      changes.value++;
      return true;
    });
  }

  Future<bool> decideSpaceModerationAppeal(
    String appealId, {
    required SpaceModerationAppealOutcome outcome,
    required String reason,
  }) async {
    final sender = sendSpaceModerationAppealDecision;
    if (sender == null) return false;
    final normalized = reason.trim();
    final prepared =
        await _serializeSpaceModerationAppeals<
          ({
            SpaceModerationAppeal appeal,
            SpaceModerationAppealDecision decision,
          })?
        >(() async {
          final store = await _loadSpaceModerationAppeals();
          SpaceModerationAppealInboxEntry? pending;
          for (final entry in store.incoming) {
            if (entry.appeal.appealId == appealId && entry.pending) {
              pending = entry;
              break;
            }
          }
          if (pending == null) return null;
          final bundle = await load(pending.appeal.spaceId);
          if (bundle == null || !bundle.manifest.isSpace) return null;
          final state = foldControlLog(
            owner: bundle.manifest.owner,
            entries: bundle.control,
            verify: (entry) => _validControlFor(bundle.manifest, entry),
            initialName: bundle.manifest.name,
            initialDescription: bundle.manifest.description ?? '',
          ).state;
          if (_effectiveSpaceOwner(state) != selfId) return null;
          var record = await _moderationRecord(
            bundle,
            state,
            pending.appeal.actionId,
          );
          if (record == null ||
              record.action.target != pending.appeal.appellant) {
            return null;
          }
          final irreversible = {
            SpaceModerationKind.deleteMessage,
            SpaceModerationKind.deletePost,
          }.contains(record.action.kind);
          if (outcome ==
                  SpaceModerationAppealOutcome.acknowledgedIrreversible &&
              !irreversible) {
            return null;
          }
          if (outcome == SpaceModerationAppealOutcome.actionRevoked) {
            if (irreversible) return null;
            if (record.revokedAtMs == null &&
                !await revokeSpaceModeration(
                  pending.appeal.spaceId,
                  pending.appeal.actionId,
                  reason: normalized,
                )) {
              return null;
            }
            final current = await load(pending.appeal.spaceId);
            if (current == null) return null;
            final currentState = foldControlLog(
              owner: current.manifest.owner,
              entries: current.control,
              verify: (entry) => _validControlFor(current.manifest, entry),
              initialName: current.manifest.name,
              initialDescription: current.manifest.description ?? '',
            ).state;
            record = await _moderationRecord(
              current,
              currentState,
              pending.appeal.actionId,
            );
            if (record?.revokedAtMs == null) return null;
          }
          final now = _now();
          final unsigned = SpaceModerationAppealDecision(
            appealId: appealId,
            spaceId: pending.appeal.spaceId,
            appellant: pending.appeal.appellant,
            reviewer: selfId,
            outcome: outcome,
            reason: normalized,
            decidedAtMs: now < pending.receivedAtMs
                ? pending.receivedAtMs
                : now,
            signature: Uint8List(0),
            authorPubKey: Uint8List(0),
          );
          if (!unsigned.isStructurallyValid) return null;
          final decision = _signer.signModerationAppealDecision(unsigned);
          if (!_signer.verifyModerationAppealDecision(decision)) return null;
          await _saveSpaceModerationAppeals(
            incoming: [
              for (final entry in store.incoming)
                if (entry.appeal.appealId == appealId)
                  SpaceModerationAppealInboxEntry(
                    appeal: entry.appeal,
                    receivedAtMs: entry.receivedAtMs,
                    decision: decision,
                  )
                else
                  entry,
            ],
            outgoing: store.outgoing,
          );
          changes.value++;
          return (appeal: pending.appeal, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.appeal.appellant,
        prepared.appeal.appealId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> receiveSpaceModerationAppealDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    final SpaceModerationAppealDecision? decision;
    try {
      decision = SpaceModerationAppealDecision.fromJson(
        jsonDecode(decisionJson),
      );
    } catch (_) {
      return false;
    }
    final now = _now();
    if (decision == null ||
        decision.reviewer != peer ||
        decision.appellant != selfId ||
        decision.decidedAtMs >
            now + const Duration(minutes: 5).inMilliseconds ||
        !_signer.verifyModerationAppealDecision(decision) ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final acceptedDecision = decision;
    return _serializeSpaceModerationAppeals(() async {
      final store = await _loadSpaceModerationAppeals();
      SpaceModerationAppealOutboxEntry? matched;
      for (final entry in store.outgoing) {
        if (entry.appeal.appealId == acceptedDecision.appealId &&
            entry.appeal.spaceId == acceptedDecision.spaceId &&
            entry.appeal.reviewer == peer) {
          matched = entry;
          break;
        }
      }
      if (matched == null ||
          acceptedDecision.decidedAtMs < matched.appeal.createdAtMs) {
        return false;
      }
      if (matched.decision != null) {
        return jsonEncode(matched.decision!.toJson()) ==
            jsonEncode(acceptedDecision.toJson());
      }
      await _saveSpaceModerationAppeals(
        incoming: store.incoming,
        outgoing: [
          for (final entry in store.outgoing)
            if (entry.appeal.appealId == acceptedDecision.appealId)
              SpaceModerationAppealOutboxEntry(
                appeal: entry.appeal,
                decision: acceptedDecision,
              )
            else
              entry,
        ],
      );
      changes.value++;
      return true;
    });
  }

  static const String _spaceAbuseReportsSetting = 'spaces.abuse_reports.v1';
  static const int _maxSpaceAbuseReportRecords = 256;
  static const int _maxPendingSpaceAbuseReportsPerReporter = 16;
  static const int _maxSpaceAbuseReportsPerReporterPerDay = 32;
  static const Duration _spaceAbuseReportMaxTransitAge = Duration(days: 30);
  Future<void> _spaceAbuseReportMutationTail = Future<void>.value();

  Future<T> _serializeSpaceAbuseReports<T>(Future<T> Function() action) async {
    final previous = _spaceAbuseReportMutationTail;
    final gate = Completer<void>();
    _spaceAbuseReportMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {}
      return await action();
    } finally {
      gate.complete();
    }
  }

  Future<
    ({
      List<SpaceAbuseReportInboxEntry> incoming,
      List<SpaceAbuseReportOutboxEntry> outgoing,
    })
  >
  _loadSpaceAbuseReports() async {
    final blob = await _storage.loadFile(_spaceAbuseReportsSetting);
    if (blob == null || blob.isEmpty) {
      return (
        incoming: <SpaceAbuseReportInboxEntry>[],
        outgoing: <SpaceAbuseReportOutboxEntry>[],
      );
    }
    try {
      final value = jsonDecode(utf8.decode(blob, allowMalformed: false));
      if (value is! Map || value['v'] != 1) throw const FormatException();
      return (
        incoming: (value['incoming'] as List? ?? const [])
            .map(SpaceAbuseReportInboxEntry.fromJson)
            .whereType<SpaceAbuseReportInboxEntry>()
            .take(_maxSpaceAbuseReportRecords)
            .toList(),
        outgoing: (value['outgoing'] as List? ?? const [])
            .map(SpaceAbuseReportOutboxEntry.fromJson)
            .whereType<SpaceAbuseReportOutboxEntry>()
            .take(_maxSpaceAbuseReportRecords)
            .toList(),
      );
    } catch (_) {
      return (
        incoming: <SpaceAbuseReportInboxEntry>[],
        outgoing: <SpaceAbuseReportOutboxEntry>[],
      );
    }
  }

  Future<void> _saveSpaceAbuseReports({
    required List<SpaceAbuseReportInboxEntry> incoming,
    required List<SpaceAbuseReportOutboxEntry> outgoing,
  }) {
    final raw = jsonEncode({
      'v': 1,
      'incoming': [
        for (final entry in incoming.take(_maxSpaceAbuseReportRecords))
          entry.toJson(),
      ],
      'outgoing': [
        for (final entry in outgoing.take(_maxSpaceAbuseReportRecords))
          entry.toJson(),
      ],
    });
    return _storage.storeFile(
      _spaceAbuseReportsSetting,
      Uint8List.fromList(utf8.encode(raw)),
      name: 'space-abuse-reports',
    );
  }

  SpaceAbuseReport? _signSpaceAbuseReport(SpaceAbuseReport unsigned) {
    try {
      final signed = _signer.signDetached(unsigned.canonicalBytes());
      final report = unsigned.withSignature(signed.signature, signed.publicKey);
      return _verifySpaceAbuseReport(report) ? report : null;
    } catch (_) {
      return null;
    }
  }

  bool _verifySpaceAbuseReport(SpaceAbuseReport report) =>
      report.isStructurallyValid &&
      report.signature.length == 64 &&
      report.authorPubKey.length == 32 &&
      _signer.verifyDetached(
        signer: report.reporter,
        publicKey: report.authorPubKey,
        message: report.canonicalBytes(),
        signature: report.signature,
      );

  SpaceAbuseReportDecision? _signSpaceAbuseReportDecision(
    SpaceAbuseReportDecision unsigned,
  ) {
    try {
      final signed = _signer.signDetached(unsigned.canonicalBytes());
      final decision = unsigned.withSignature(
        signed.signature,
        signed.publicKey,
      );
      return _verifySpaceAbuseReportDecision(decision) ? decision : null;
    } catch (_) {
      return null;
    }
  }

  bool _verifySpaceAbuseReportDecision(SpaceAbuseReportDecision decision) =>
      decision.isStructurallyValid &&
      decision.signature.length == 64 &&
      decision.authorPubKey.length == 32 &&
      _signer.verifyDetached(
        signer: decision.reviewer,
        publicKey: decision.authorPubKey,
        message: decision.canonicalBytes(),
        signature: decision.signature,
      );

  Future<
    ({
      NodeId reviewer,
      SpaceModerationReference post,
      SpaceModerationReference target,
    })?
  >
  _resolveReportableSpaceContent(
    NodeId spaceId,
    String postId,
    String? commentRef,
  ) async {
    final bundle = await load(spaceId);
    if (bundle != null && bundle.manifest.isSpace) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      final reviewer = _effectiveSpaceOwner(state);
      final posts = await _postsOfBundle(bundle, applyLocalRetention: true);
      final post = posts.where((value) => value.postId == postId).firstOrNull;
      if (reviewer != null && post != null) {
        final postReference = SpaceModerationReference(
          kind: SpaceModerationReferenceKind.spacePost,
          author: post.author,
          seq: post.seq,
        );
        if (commentRef == null) {
          return (
            reviewer: reviewer,
            post: postReference,
            target: postReference,
          );
        }
        final comments = await spacePostCommentsOf(spaceId, postId);
        final comment = comments
            .where((value) => value.ref == commentRef)
            .firstOrNull;
        if (comment != null) {
          return (
            reviewer: reviewer,
            post: postReference,
            target: SpaceModerationReference(
              kind: SpaceModerationReferenceKind.spacePostComment,
              author: comment.author,
              seq: comment.root.seq,
            ),
          );
        }
      }
    }

    final public = await publicSpaceSubscription(spaceId);
    if (public == null) return null;
    final post = public.feed.posts
        .where((value) => value.postId == postId)
        .firstOrNull;
    if (post == null) return null;
    final postReference = SpaceModerationReference(
      kind: SpaceModerationReferenceKind.spacePost,
      author: post.author,
      seq: post.seq,
    );
    if (commentRef == null) {
      return (
        reviewer: public.descriptor.publisher,
        post: postReference,
        target: postReference,
      );
    }
    final comments = await publicSpacePostComments(spaceId, postId);
    final comment = comments
        .where((value) => value.ref == commentRef)
        .firstOrNull;
    if (comment == null) return null;
    return (
      reviewer: public.descriptor.publisher,
      post: postReference,
      target: SpaceModerationReference(
        kind: SpaceModerationReferenceKind.spacePostComment,
        author: comment.author,
        seq: comment.root.seq,
      ),
    );
  }

  Future<bool> _spaceAbuseReportContentExists(
    GroupBundle bundle,
    SpaceAbuseReport report,
  ) async {
    final post = (await _postsOfBundle(
      bundle,
      applyLocalRetention: false,
    )).where((value) => value.postId == report.postId).firstOrNull;
    if (post == null ||
        post.author != report.post.author ||
        post.seq != report.post.seq) {
      return false;
    }
    if (report.target.kind == SpaceModerationReferenceKind.spacePost) {
      return report.target.author == post.author &&
          report.target.seq == post.seq;
    }
    final memberComments = await _messagesOfBundle(
      bundle,
      spacePostId: report.postId,
      includeSpacePostComments: true,
      applyLocalRetention: false,
    );
    if (memberComments.any(
      (message) =>
          message.editOf == null &&
          message.deleteOf == null &&
          message.ref == report.target.contentId,
    )) {
      return true;
    }
    return foldSpacePublicComments(
      comments: bundle.publicComments,
      spaceId: report.spaceId,
      postId: report.postId,
      verifySignature: _signer.verifyDetached,
    ).any((comment) => comment.ref == report.target.contentId);
  }

  List<T>? _prependBoundedSpaceAbuseEntry<T>(
    T value,
    List<T> current,
    bool Function(T value) pending,
  ) {
    final result = <T>[value, ...current];
    while (result.length > _maxSpaceAbuseReportRecords) {
      final decided = result.lastIndexWhere((entry) => !pending(entry));
      if (decided < 0) return null;
      result.removeAt(decided);
    }
    return result;
  }

  Future<List<SpaceAbuseReportInboxEntry>> incomingSpaceAbuseReports({
    NodeId? spaceId,
    bool pendingOnly = false,
  }) async {
    final result =
        (await _loadSpaceAbuseReports()).incoming
            .where(
              (entry) =>
                  (spaceId == null || entry.report.spaceId == spaceId) &&
                  (!pendingOnly || entry.pending),
            )
            .toList()
          ..sort(
            (left, right) => right.receivedAtMs.compareTo(left.receivedAtMs),
          );
    return result;
  }

  Future<List<SpaceAbuseReportOutboxEntry>> outgoingSpaceAbuseReports() async {
    final result = (await _loadSpaceAbuseReports()).outgoing.toList()
      ..sort(
        (left, right) =>
            right.report.createdAtMs.compareTo(left.report.createdAtMs),
      );
    return result;
  }

  /// Persist before enqueueing a private external report. Repeating the same
  /// visible content/reviewer tuple retransmits the exact signed row instead
  /// of producing a second complaint. Ownership transfer permits one
  /// replacement addressed to the new current owner.
  Future<bool> reportSpaceContent(
    NodeId spaceId,
    String postId, {
    String? commentRef,
    required SpaceAbuseCategory category,
    String details = '',
  }) async {
    final sender = sendSpaceAbuseReport;
    if (sender == null) return false;
    final resolved = await _resolveReportableSpaceContent(
      spaceId,
      postId,
      commentRef,
    );
    if (resolved == null ||
        resolved.reviewer == selfId ||
        resolved.target.author == selfId) {
      return false;
    }
    final normalized = details.trim();
    final report = await _serializeSpaceAbuseReports(() async {
      final store = await _loadSpaceAbuseReports();
      final contentKey =
          '${spaceId.hex}|${resolved.post.contentId}|'
          '${resolved.target.kind.name}|${resolved.target.contentId}';
      for (final entry in store.outgoing) {
        if (entry.report.contentKey == contentKey &&
            (entry.decision != null ||
                entry.report.reviewer == resolved.reviewer)) {
          return entry.decision == null ? entry.report : null;
        }
      }
      final now = _now();
      final unsigned = SpaceAbuseReport(
        reportId: _newSpaceInviteId(),
        spaceId: spaceId,
        post: resolved.post,
        target: resolved.target,
        reporter: selfId,
        reviewer: resolved.reviewer,
        category: category,
        details: normalized,
        createdAtMs: now,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      if (!unsigned.isStructurallyValid) return null;
      final signed = _signSpaceAbuseReport(unsigned);
      if (signed == null) return null;
      final outgoing = _prependBoundedSpaceAbuseEntry(
        SpaceAbuseReportOutboxEntry(report: signed),
        store.outgoing,
        (entry) => entry.pending,
      );
      if (outgoing == null) return null;
      await _saveSpaceAbuseReports(
        incoming: store.incoming,
        outgoing: outgoing,
      );
      changes.value++;
      return signed;
    });
    if (report == null) return false;
    try {
      await sender(
        report.reviewer,
        report.reportId,
        jsonEncode(report.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The durable transport ACK is withheld until source binding, signature,
  /// current-owner routing, exact content and bounded per-reporter quotas all
  /// pass and the immutable inbox row is persisted.
  Future<bool> receiveSpaceAbuseReport(NodeId peer, String reportJson) async {
    if (utf8.encode(reportJson).length > kSpaceAbuseReportWireMaxBytes) {
      return false;
    }
    final SpaceAbuseReport? report;
    try {
      report = SpaceAbuseReport.fromJson(jsonDecode(reportJson));
    } catch (_) {
      return false;
    }
    final now = _now();
    if (report == null ||
        report.reporter != peer ||
        report.reviewer != selfId ||
        report.createdAtMs > now + const Duration(minutes: 5).inMilliseconds ||
        report.createdAtMs <
            now - _spaceAbuseReportMaxTransitAge.inMilliseconds ||
        !_verifySpaceAbuseReport(report) ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final accepted = report;
    final bundle = await load(accepted.spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (_effectiveSpaceOwner(state) != selfId) return false;

    return _serializeSpaceAbuseReports(() async {
      final store = await _loadSpaceAbuseReports();
      for (final old in store.incoming) {
        if (old.report.reportId == accepted.reportId) {
          return jsonEncode(old.report.toJson()) ==
              jsonEncode(accepted.toJson());
        }
        if (old.report.reporter == peer &&
            old.report.contentKey == accepted.contentKey) {
          return false;
        }
      }
      final pendingFromReporter = store.incoming
          .where((entry) => entry.pending && entry.report.reporter == peer)
          .length;
      final recentCutoff = now - const Duration(days: 1).inMilliseconds;
      final recentFromReporter = store.incoming
          .where(
            (entry) =>
                entry.report.reporter == peer &&
                entry.receivedAtMs >= recentCutoff,
          )
          .length;
      if (pendingFromReporter >= _maxPendingSpaceAbuseReportsPerReporter ||
          recentFromReporter >= _maxSpaceAbuseReportsPerReporterPerDay ||
          !await _spaceAbuseReportContentExists(bundle, accepted)) {
        return false;
      }
      final entry = SpaceAbuseReportInboxEntry(
        report: accepted,
        receivedAtMs: now < accepted.createdAtMs ? accepted.createdAtMs : now,
      );
      final incoming = _prependBoundedSpaceAbuseEntry(
        entry,
        store.incoming,
        (value) => value.pending,
      );
      if (incoming == null) return false;
      await _saveSpaceAbuseReports(
        incoming: incoming,
        outgoing: store.outgoing,
      );
      changes.value++;
      return true;
    });
  }

  Future<bool> decideSpaceAbuseReport(
    String reportId, {
    required SpaceAbuseReportOutcome outcome,
    required String reason,
  }) async {
    final sender = sendSpaceAbuseReportDecision;
    if (sender == null) return false;
    final normalized = reason.trim();
    final prepared =
        await _serializeSpaceAbuseReports<
          ({SpaceAbuseReport report, SpaceAbuseReportDecision decision})?
        >(() async {
          final store = await _loadSpaceAbuseReports();
          final pending = store.incoming
              .where(
                (entry) => entry.report.reportId == reportId && entry.pending,
              )
              .firstOrNull;
          if (pending == null) return null;
          final bundle = await load(pending.report.spaceId);
          if (bundle == null || !bundle.manifest.isSpace) return null;
          final state = foldControlLog(
            owner: bundle.manifest.owner,
            entries: bundle.control,
            verify: (entry) => _validControlFor(bundle.manifest, entry),
            initialName: bundle.manifest.name,
            initialDescription: bundle.manifest.description ?? '',
          ).state;
          if (_effectiveSpaceOwner(state) != selfId) return null;

          String? moderationActionId;
          if (outcome == SpaceAbuseReportOutcome.contentRemoved) {
            final target = pending.report.target;
            moderationActionId = await moderateSpace(
              pending.report.spaceId,
              kind: target.kind == SpaceModerationReferenceKind.spacePostComment
                  ? SpaceModerationKind.deleteMessage
                  : SpaceModerationKind.deletePost,
              target: target.author,
              scope: SpaceModerationScope.posts,
              reason: normalized,
              reference: target,
            );
            if (moderationActionId == null) return null;
          }
          final now = _now();
          final unsigned = SpaceAbuseReportDecision(
            reportId: pending.report.reportId,
            spaceId: pending.report.spaceId,
            reporter: pending.report.reporter,
            reviewer: selfId,
            outcome: outcome,
            reason: normalized,
            decidedAtMs: now < pending.receivedAtMs
                ? pending.receivedAtMs
                : now,
            moderationActionId: moderationActionId,
            signature: Uint8List(0),
            authorPubKey: Uint8List(0),
          );
          if (!unsigned.isStructurallyValid) return null;
          final decision = _signSpaceAbuseReportDecision(unsigned);
          if (decision == null) return null;
          await _saveSpaceAbuseReports(
            incoming: [
              for (final entry in store.incoming)
                if (entry.report.reportId == reportId)
                  SpaceAbuseReportInboxEntry(
                    report: entry.report,
                    receivedAtMs: entry.receivedAtMs,
                    decision: decision,
                  )
                else
                  entry,
            ],
            outgoing: store.outgoing,
          );
          changes.value++;
          return (report: pending.report, decision: decision);
        });
    if (prepared == null) return false;
    try {
      await sender(
        prepared.report.reporter,
        prepared.report.reportId,
        jsonEncode(prepared.decision.toJson()),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> receiveSpaceAbuseReportDecision(
    NodeId peer,
    String decisionJson,
  ) async {
    if (utf8.encode(decisionJson).length > kSpaceAbuseReportWireMaxBytes) {
      return false;
    }
    final SpaceAbuseReportDecision? decision;
    try {
      decision = SpaceAbuseReportDecision.fromJson(jsonDecode(decisionJson));
    } catch (_) {
      return false;
    }
    final now = _now();
    if (decision == null ||
        decision.reviewer != peer ||
        decision.reporter != selfId ||
        decision.decidedAtMs >
            now + const Duration(minutes: 5).inMilliseconds ||
        !_verifySpaceAbuseReportDecision(decision) ||
        (await _storage.getContact(peer))?.status == ContactStatus.blocked) {
      return false;
    }
    final accepted = decision;
    return _serializeSpaceAbuseReports(() async {
      final store = await _loadSpaceAbuseReports();
      final matched = store.outgoing
          .where(
            (entry) =>
                entry.report.reportId == accepted.reportId &&
                entry.report.spaceId == accepted.spaceId &&
                entry.report.reviewer == peer,
          )
          .firstOrNull;
      if (matched == null ||
          accepted.decidedAtMs < matched.report.createdAtMs) {
        return false;
      }
      if (matched.decision != null) {
        return jsonEncode(matched.decision!.toJson()) ==
            jsonEncode(accepted.toJson());
      }
      await _saveSpaceAbuseReports(
        incoming: store.incoming,
        outgoing: [
          for (final entry in store.outgoing)
            if (entry.report.reportId == accepted.reportId)
              SpaceAbuseReportOutboxEntry(
                report: entry.report,
                decision: accepted,
              )
            else
              entry,
        ],
      );
      changes.value++;
      return true;
    });
  }

  final Map<String, Future<void>> _mutationTails = <String, Future<void>>{};

  // Overlay deltas are flooded transitively across each node's sparse XOR
  // links. This bounded RAM set makes the flood exactly-once per live process;
  // the underlying log merge remains the durable/idempotent safety net.
  static const int _kSeenOverlayDeltaLimit = 4096;
  final Set<String> _seenOverlayDeltas = <String>{};

  final StreamController<GroupCallSignal> _groupCallIncomingCtl =
      StreamController.broadcast();
  Stream<GroupCallSignal> get groupCallIncoming => _groupCallIncomingCtl.stream;

  /// Replay ids are RAM-only: wire frame dedup is the first line, while this
  /// signed-signal set also catches a malicious re-wrapping under a fresh AEAD
  /// nonce/frame id. Signals expire quickly, so restart persistence is neither
  /// useful nor desirable.
  final Map<String, int> _seenGroupCallSignals = <String, int>{};

  /// Serialize every read-modify-write of one group. Wire ingest and local UI
  /// actions share this gate, so a concurrently arriving delta cannot restore
  /// an older bundle and erase a freshly persisted message/epoch key.
  Future<T> _serialized<T>(NodeId groupId, Future<T> Function() action) async {
    final id = groupId.hex;
    final previous = _mutationTails[id] ?? Future<void>.value();
    final gate = Completer<void>();
    _mutationTails[id] = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A prior mutation reports its own failure; the queue must keep moving.
      }
      return await action();
    } finally {
      gate.complete();
      if (identical(_mutationTails[id], gate.future)) {
        _mutationTails.remove(id);
      }
    }
  }

  int _lastTimestampMs = -1;

  /// Signed entries created by one service instance must retain local causal
  /// order even when several mutations land in one wall-clock millisecond (or
  /// the OS clock steps backwards). Distributed fold still uses author/seq;
  /// this monotonic timestamp additionally makes `fromJoin` boundaries exact.
  int _now() {
    final wall =
        debugWallClockMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    _lastTimestampMs = wall > _lastTimestampMs ? wall : _lastTimestampMs + 1;
    return _lastTimestampMs;
  }

  /// Test seam: retention expiry spans days, so deterministic tests drive the
  /// wall clock instead of waiting it out. Never set in production code.
  int Function()? debugWallClockMs;

  bool _validManifest(GroupManifest manifest) {
    if (manifest.isLegacyGroup) return manifest.genesisPubKey.length == 32;
    if (manifest.version == SpaceManifest.spaceVersion) {
      return manifest.isSpace && _signer.verifySpaceManifest(manifest);
    }
    if (!manifest.isSovereignDevice ||
        manifest.name != kDeviceGroupName ||
        manifest.signatureAlgorithm == null) {
      return false;
    }
    if (manifest.signatureAlgorithm != 'ed25519' &&
        manifest.sovereignBundleHash == null) {
      return false;
    }
    return _signer.verifySovereign(
      algorithm: manifest.signatureAlgorithm!,
      nodeId: manifest.owner,
      publicKey: manifest.genesisPubKey,
      message: manifest.canonicalBytes(),
      signature: manifest.signature,
    );
  }

  bool _validSovereignBundle(
    GroupManifest manifest,
    Uint8List? encryptedBundle,
  ) {
    final expected = manifest.sovereignBundleHash;
    if (expected == null) return encryptedBundle == null;
    if (encryptedBundle == null || encryptedBundle.length > 16 * 1024) {
      return false;
    }
    return _listEquals(_sha256(encryptedBundle), expected);
  }

  /// Select the one authoritative manifest during snapshot merge. The only
  /// permitted change is an owner-signed v1 -> Space v3 upgrade over exactly
  /// the same immutable root. Signed Spaces never downgrade or fork.
  GroupManifest? _mergeManifest(
    GroupManifest existing,
    GroupManifest incoming,
  ) {
    if (existing.isSovereignDevice || incoming.isSovereignDevice) {
      return existing.isSovereignDevice &&
              incoming.isSovereignDevice &&
              existing.sameGenesis(incoming)
          ? existing
          : null;
    }
    if (!existing.sameImmutableRoot(incoming)) return null;
    if (existing.isSpace) {
      if (incoming.isSpace && !existing.sameGenesis(incoming)) return null;
      return existing;
    }
    if (!existing.isLegacyGroup) return null;
    if (incoming.isSpace) return incoming;
    return incoming.isLegacyGroup ? existing : null;
  }

  bool _validControlFor(GroupManifest manifest, ControlEntry e) {
    if (!e.isStructurallyValid) return false;
    if ((e.version == 17 ||
            e.version == 18 ||
            e.version == 19 ||
            e.version == 20) &&
        !manifest.isSpace) {
      return false;
    }
    if ((e.op == ControlOp.transferOwnership ||
            e.op == ControlOp.setDescription ||
            e.op == ControlOp.publishRules ||
            e.op == ControlOp.acceptRules ||
            e.op == ControlOp.setRetention) &&
        !manifest.isSpace) {
      return false;
    }
    if (manifest.isSovereignDevice) {
      final membershipOp =
          e.op == ControlOp.addMember || e.op == ControlOp.removeMember;
      final shapeOk =
          e.target != null &&
          (e.op != ControlOp.addMember || e.role == GroupRole.member) &&
          (e.op != ControlOp.removeMember || e.role == null);
      return _validManifest(manifest) &&
          e.groupId == manifest.groupId &&
          e.author == manifest.owner &&
          _listEquals(e.authorPubKey, manifest.genesisPubKey) &&
          membershipOp &&
          shapeOk &&
          _signer.verifySovereign(
            algorithm: manifest.signatureAlgorithm!,
            nodeId: e.author,
            publicKey: e.authorPubKey,
            message: e.canonicalBytes(),
            signature: e.signature,
          );
    }
    return (e.groupId == null || e.groupId == manifest.groupId) &&
        _signer.verifyControl(e);
  }

  bool _validMessageFor(NodeId groupId, GroupMessage m) =>
      m.groupId == groupId &&
      (m.spacePostId == null ||
          (_spacePostIdPattern.hasMatch(m.spacePostId!) &&
              m.channelId == null &&
              m.isEncrypted &&
              !m.isChannelEncrypted &&
              m.attachment == null)) &&
      _signer.verifyMessage(m);

  bool _validReactionFor(NodeId groupId, GroupReaction r) =>
      r.groupId == groupId &&
      r.isStructurallyValid &&
      _signer.verifyReaction(r);

  bool _validPostFor(NodeId spaceId, SpacePost post) =>
      post.spaceId == spaceId &&
      post.isStructurallyValid &&
      _signer.verifyPost(post);

  bool _validGroupCallShape(GroupCallSignal signal) {
    switch (signal.type) {
      case GroupCallSignalType.announce:
      case GroupCallSignalType.join:
        // These establish the room capability for a newly-seeing peer.
        if (signal.media == null || signal.media!.isEmpty) return false;
        break;
      case GroupCallSignalType.renegotiate:
        // Current posture is required but may be all-off.
        if (signal.media == null) return false;
        break;
      case GroupCallSignalType.heartbeat:
        // Legacy heartbeats omit media; new ones repeat current posture so a
        // lost live renegotiation converges at the next tick.
        break;
      case GroupCallSignalType.leave:
      case GroupCallSignalType.end:
      case GroupCallSignalType.busy:
      case GroupCallSignalType.unknown:
        if (signal.media != null) return false;
        break;
    }
    return signal.isStructurallyValid;
  }

  String _freshGroupCallNonce() {
    final random = Random.secure();
    return List<int>.generate(
      12,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  void _pruneSeenGroupCallSignals(int nowMs) {
    _seenGroupCallSignals.removeWhere(
      (_, seenAt) => nowMs - seenAt > const Duration(minutes: 3).inMilliseconds,
    );
    while (_seenGroupCallSignals.length > 2048) {
      _seenGroupCallSignals.remove(_seenGroupCallSignals.keys.first);
    }
  }

  /// Sign, epoch-encrypt and fan one ephemeral call-control event. Open rooms
  /// use the Space membership epoch and every current member; restricted voice
  /// rooms use their independent channel epoch and explicit current ACL. No
  /// call plaintext or key is persisted.
  Future<GroupCallSignal?> broadcastGroupCallSignal(
    NodeId groupId, {
    NodeId? channelId,
    required String callId,
    required GroupCallSignalType type,
    CallMedia? media,
    CallEndReason? reason,
  }) => _serialized(groupId, () async {
    final sender = sendGroupCallFrame;
    final bundle = await load(groupId);
    if (sender == null || bundle == null || bundle.manifest.isSovereignDevice) {
      return null;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    SpaceChannelControlCleartext? protectedChannel;
    SpaceChannelControlEnvelope? protectedEnvelope;
    if (bundle.manifest.isSpace && channelId != null) {
      final channel = state.channels[channelId.hex];
      if (channel != null) {
        if (channel.kind != SpaceChannelKind.voice || channel.archived) {
          return null;
        }
      } else {
        protectedEnvelope = state.protectedChannels[channelId.hex];
        if (protectedEnvelope == null) return null;
        protectedChannel = await _materializeProtectedChannel(
          bundle,
          state,
          protectedEnvelope,
        );
        if (protectedChannel == null ||
            protectedChannel.channel.kind != SpaceChannelKind.voice ||
            protectedChannel.channel.archived ||
            !protectedChannel.recipients.contains(_signer.selfId)) {
          return null;
        }
      }
    } else if (!bundle.manifest.isSpace && channelId != null) {
      return null;
    }
    final acl = SpaceAcl(state);
    if (!acl.allows(_signer.selfId, SpacePermission.view) ||
        !acl.allows(
          _signer.selfId,
          SpacePermission.enterVoice,
          channelId: channelId,
        ) ||
        !_encryptionEstablished(bundle.manifest, bundle.control)) {
      return null;
    }
    Uint8List? key;
    if (protectedEnvelope == null) {
      final descriptor = state.epochDescriptor;
      key = bundle.localEpochKeys[state.epoch];
      if (descriptor == null ||
          descriptor.epoch != state.epoch ||
          key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            state.epoch,
            key,
          )) {
        return null;
      }
    } else {
      key =
          bundle.localChannelEpochKeys[_channelKeyId(
            channelId!,
            protectedEnvelope.channelEpoch,
          )];
      if (key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            channelId,
            protectedEnvelope.channelEpoch,
            key,
          )) {
        return null;
      }
    }
    final unsigned = GroupCallSignal(
      groupId: groupId,
      channelId: channelId,
      channelEpoch: protectedEnvelope?.channelEpoch,
      callId: callId,
      author: _signer.selfId,
      membershipEpoch: state.epoch,
      type: type,
      media: media,
      reason: reason,
      sentAtMs: _now(),
      nonce: _freshGroupCallNonce(),
      signature: Uint8List(0),
      authorPubKey: Uint8List(0),
      protocolVersion: protectedEnvelope != null
          ? kProtectedSpaceVoiceSessionProtocolVersion
          : channelId == null
          ? kLegacyGroupCallProtocolVersion
          : kSpaceVoiceSessionProtocolVersion,
    );
    if (!_validGroupCallShape(unsigned)) return null;
    final signed = _signer.signCallSignal(unsigned);
    if (!_validGroupCallShape(signed) || !_signer.verifyCallSignal(signed)) {
      return null;
    }
    final clear = Uint8List.fromList(utf8.encode(signed.encode()));
    try {
      late final GroupEncryptedPayload encrypted;
      late final GroupCallWireFrame frame;
      if (protectedEnvelope != null) {
        encrypted = await encryptSpaceChannelCallPayload(
          spaceId: groupId,
          channelId: channelId!,
          channelEpoch: protectedEnvelope.channelEpoch,
          author: _signer.selfId,
          clearText: clear,
          channelKey: key,
        );
        frame = GroupCallWireFrame(
          groupId: groupId,
          channelId: channelId,
          channelEpoch: protectedEnvelope.channelEpoch,
          payload: encrypted,
        );
      } else {
        encrypted = await encryptGroupCallPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          clearText: clear,
          epochKey: key,
        );
        frame = GroupCallWireFrame(
          groupId: groupId,
          membershipEpoch: state.epoch,
          payload: encrypted,
        );
      }
      final frameJson = frame.encode();
      final recipients = protectedChannel == null
          ? state.members.values.map((member) => member.nodeId)
          : protectedChannel.recipients.where(
              (recipient) =>
                  state.isMember(recipient) &&
                  acl.allows(recipient, SpacePermission.view) &&
                  acl.allows(
                    recipient,
                    SpacePermission.enterVoice,
                    channelId: channelId,
                  ),
            );
      for (final recipient in recipients) {
        if (recipient == _signer.selfId) continue;
        await sender(recipient, signed, frameJson);
      }
      return signed;
    } catch (_) {
      return null;
    } finally {
      clear.fillRange(0, clear.length, 0);
    }
  });

  /// Authenticate and decrypt an inbound group-call frame. Every refusal is a
  /// silent false: callers must not learn whether a gid, member or epoch exists.
  Future<bool> ingestGroupCallFrame(NodeId peer, String frameJson) async {
    final frame = GroupCallWireFrame.tryDecode(frameJson);
    if (frame == null) return false;
    return _serialized(frame.groupId, () async {
      final bundle = await load(frame.groupId);
      if (bundle == null || bundle.manifest.isSovereignDevice) return false;
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      ).state;
      if (!SpaceAcl(state).allows(peer, SpacePermission.view)) return false;
      SpaceChannelControlCleartext? protectedChannel;
      late final Uint8List key;
      if (frame.isChannelEncrypted) {
        if (!bundle.manifest.isSpace) return false;
        final channelId = frame.channelId!;
        final opaque = state.protectedChannels[channelId.hex];
        if (opaque == null || opaque.channelEpoch != frame.channelEpoch) {
          return false;
        }
        protectedChannel = await _materializeProtectedChannel(
          bundle,
          state,
          opaque,
        );
        if (protectedChannel == null ||
            protectedChannel.channel.kind != SpaceChannelKind.voice ||
            protectedChannel.channel.archived ||
            !protectedChannel.recipients.contains(peer) ||
            !protectedChannel.recipients.contains(_signer.selfId)) {
          return false;
        }
        final candidate =
            bundle.localChannelEpochKeys[_channelKeyId(
              channelId,
              frame.channelEpoch!,
            )];
        if (candidate == null ||
            !_validLocalChannelEpochKey(
              bundle.manifest,
              bundle.control,
              channelId,
              frame.channelEpoch!,
              candidate,
            )) {
          return false;
        }
        key = candidate;
      } else {
        if (!frame.isMembershipEncrypted ||
            frame.membershipEpoch != state.epoch ||
            state.epochDescriptor?.epoch != state.epoch) {
          return false;
        }
        final candidate = bundle.localEpochKeys[state.epoch];
        if (candidate == null ||
            !_validLocalEpochKey(
              bundle.manifest,
              bundle.control,
              state.epoch,
              candidate,
            )) {
          return false;
        }
        key = candidate;
      }
      Uint8List? clear;
      try {
        clear = frame.isChannelEncrypted
            ? await decryptSpaceChannelCallPayload(
                spaceId: frame.groupId,
                channelId: frame.channelId!,
                channelEpoch: frame.channelEpoch!,
                author: peer,
                payload: frame.payload,
                channelKey: key,
              )
            : await decryptGroupCallPayload(
                groupId: frame.groupId,
                membershipEpoch: frame.membershipEpoch!,
                author: peer,
                payload: frame.payload,
                epochKey: key,
              );
        if (clear.length > maxGroupCallSignalBytes) return false;
        final signal = GroupCallSignal.tryDecode(utf8.decode(clear));
        final signalAcl = SpaceAcl(state);
        if (signal == null ||
            signal.groupId != frame.groupId ||
            signal.membershipEpoch != state.epoch ||
            signal.author != peer ||
            !signalAcl.allows(
              peer,
              SpacePermission.enterVoice,
              channelId: signal.channelId,
            ) ||
            !signalAcl.allows(
              _signer.selfId,
              SpacePermission.enterVoice,
              channelId: signal.channelId,
            ) ||
            !_validGroupCallShape(signal) ||
            !_signer.verifyCallSignal(signal) ||
            !SpaceAcl(state).allows(
              peer,
              SpacePermission.enterVoice,
              atMs: signal.sentAtMs,
              channelId: signal.channelId,
            )) {
          return false;
        }
        if (bundle.manifest.isSpace) {
          if (frame.isChannelEncrypted) {
            if (signal.protocolVersion !=
                    kProtectedSpaceVoiceSessionProtocolVersion ||
                signal.channelId != frame.channelId ||
                signal.channelEpoch != frame.channelEpoch ||
                protectedChannel == null ||
                !protectedChannel.recipients.contains(signal.author)) {
              return false;
            }
          } else if (signal.channelId == null) {
            if (signal.protocolVersion != kLegacyGroupCallProtocolVersion) {
              return false;
            }
          } else {
            final channel = state.channels[signal.channelId!.hex];
            if (signal.protocolVersion != kSpaceVoiceSessionProtocolVersion ||
                channel == null ||
                channel.kind != SpaceChannelKind.voice ||
                channel.archived) {
              return false;
            }
          }
        } else if (frame.isChannelEncrypted ||
            signal.channelId != null ||
            signal.protocolVersion != kLegacyGroupCallProtocolVersion) {
          return false;
        }
        final nowMs = _now();
        final ageMs = nowMs - signal.sentAtMs;
        if (ageMs < -const Duration(seconds: 30).inMilliseconds ||
            ageMs > const Duration(minutes: 2).inMilliseconds) {
          return false;
        }
        _pruneSeenGroupCallSignals(nowMs);
        final replayId =
            '${signal.author.hex}:${signal.callId}:${signal.nonce}';
        if (_seenGroupCallSignals.containsKey(replayId)) return false;
        _seenGroupCallSignals[replayId] = nowMs;
        if (!_groupCallIncomingCtl.isClosed) {
          _groupCallIncomingCtl.add(signal);
        }
        return true;
      } catch (_) {
        return false;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    });
  }

  bool _sameEpochDescriptor(
    GroupEpochDescriptor left,
    GroupEpochDescriptor right,
  ) =>
      left.groupId == right.groupId &&
      left.epoch == right.epoch &&
      left.keyCommitment == right.keyCommitment &&
      left.envelopeRoot == right.envelopeRoot &&
      left.recipientCount == right.recipientCount;

  List<ControlEntry> _acceptedControl(
    GroupManifest manifest,
    List<ControlEntry> control,
  ) {
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    return folded.accepted;
  }

  List<SpaceControlHead> _controlHeads(Iterable<ControlEntry> accepted) {
    final heads = <String, ControlEntry>{};
    for (final entry in accepted) {
      final current = heads[entry.author.hex];
      if (current == null || entry.seq > current.seq) {
        heads[entry.author.hex] = entry;
      }
    }
    final ordered = heads.values.toList()
      ..sort((left, right) => left.author.hex.compareTo(right.author.hex));
    return [
      for (final entry in ordered)
        SpaceControlHead(
          author: entry.author,
          seq: entry.seq,
          hash: controlEntryHash(entry),
        ),
    ];
  }

  SpaceControlCheckpoint? _controlCheckpoint(Iterable<ControlEntry> accepted) {
    final heads = _controlHeads(accepted);
    if (heads.length > kSpaceControlCheckpointHeadsMax) return null;
    return SpaceControlCheckpoint(heads);
  }

  GroupFoldResult? _foldAtControlHeads(
    GroupManifest manifest,
    List<ControlEntry> control,
    List<SpaceControlHead> controlHeads,
  ) {
    final heads = {for (final head in controlHeads) head.author.hex: head};
    if (heads.length != controlHeads.length) return null;
    final selected = <ControlEntry>[];
    for (final entry in control) {
      final head = heads[entry.author.hex];
      if (head != null &&
          entry.seq <= head.seq &&
          _validControlFor(manifest, entry)) {
        selected.add(entry);
      }
    }
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: selected,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    final acceptedHashes = {
      for (final entry in folded.accepted) controlEntryHash(entry),
    };
    for (final head in controlHeads) {
      if (!acceptedHashes.contains(head.hash) ||
          !folded.accepted.any(
            (entry) =>
                entry.author == head.author &&
                entry.seq == head.seq &&
                controlEntryHash(entry) == head.hash,
          )) {
        return null;
      }
    }
    return folded;
  }

  GroupFoldResult? _foldAtPostFrontier(
    GroupManifest manifest,
    List<ControlEntry> control,
    SpaceControlFrontier frontier,
  ) {
    if (!frontier.isStructurallyValid) return null;
    return _foldAtControlHeads(manifest, control, frontier.heads);
  }

  GroupFoldResult? _foldAtControlCheckpoint(
    GroupManifest manifest,
    List<ControlEntry> control,
    ControlEntry entry,
  ) {
    final checkpoint = entry.controlCheckpoint;
    if (entry.op != ControlOp.checkpoint ||
        checkpoint == null ||
        !checkpoint.isStructurallyValid) {
      return null;
    }
    final historical = _foldAtControlHeads(manifest, control, checkpoint.heads);
    if (historical == null ||
        historical.state.policyVersion != entry.policyVersion ||
        !historical.state.isMember(entry.author)) {
      return null;
    }
    SpaceControlHead? predecessor;
    for (final head in checkpoint.heads) {
      if (head.author == entry.author) {
        predecessor = head;
        break;
      }
    }
    if (predecessor == null) {
      if (entry.seq != 0 || entry.prevHash.isNotEmpty) return null;
    } else if (entry.seq != predecessor.seq + 1 ||
        entry.prevHash != predecessor.hash) {
      return null;
    }
    return historical;
  }

  ({int seq, String prevHash, bool blocked}) _nextControlLink(
    GroupManifest manifest,
    List<ControlEntry> control,
    NodeId author,
  ) {
    final authored =
        _acceptedControl(
            manifest,
            control,
          ).where((entry) => entry.author == author).toList()
          ..sort((left, right) => left.seq.compareTo(right.seq));
    final acceptedHeadSeq = authored.isEmpty ? -1 : authored.last.seq;
    final hasRejectedSuffix = control.any(
      (entry) =>
          entry.author == author &&
          _validControlFor(manifest, entry) &&
          entry.seq > acceptedHeadSeq,
    );
    if (authored.isEmpty) {
      return (seq: 0, prevHash: '', blocked: hasRejectedSuffix);
    }
    final head = authored.last;
    return (
      seq: head.seq + 1,
      prevHash: controlEntryHash(head),
      blocked: hasRejectedSuffix,
    );
  }

  ControlEntry? _descriptorEntry(
    GroupManifest manifest,
    List<ControlEntry> control,
    GroupEpochDescriptor descriptor,
  ) {
    for (final entry in _acceptedControl(manifest, control)) {
      final candidate = entry.epochDescriptor;
      if (candidate != null && _sameEpochDescriptor(candidate, descriptor)) {
        return entry;
      }
    }
    return null;
  }

  bool _encryptionEstablished(
    GroupManifest manifest,
    List<ControlEntry> control,
  ) => _acceptedControl(
    manifest,
    control,
  ).any((entry) => entry.epochDescriptor != null);

  bool _validLocalEpochKey(
    GroupManifest manifest,
    List<ControlEntry> control,
    int epoch,
    Uint8List key,
  ) {
    if (key.length != 32) return false;
    for (final entry in _acceptedControl(manifest, control)) {
      final descriptor = entry.epochDescriptor;
      if (descriptor == null || descriptor.epoch != epoch) continue;
      return descriptor.keyCommitment ==
          groupEpochKeyCommitment(
            groupId: manifest.groupId,
            epoch: epoch,
            key: key,
          );
    }
    return false;
  }

  Future<GroupMessage?> _materializeEncryptedMessage(
    GroupBundle bundle,
    GroupMessage message,
  ) async {
    if (!message.isEncrypted) return message;
    if (message.isChannelEncrypted) {
      final channelId = message.channelId!;
      final epoch = message.channelEpoch!;
      final key = bundle.localChannelEpochKeys[_channelKeyId(channelId, epoch)];
      if (key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            channelId,
            epoch,
            key,
          )) {
        return null;
      }
      Uint8List? clear;
      try {
        clear = await decryptSpaceChannelMessagePayload(
          spaceId: bundle.manifest.groupId,
          channelId: channelId,
          channelEpoch: epoch,
          author: message.author,
          seq: message.seq,
          prevHash: message.prevHash,
          policyVersion: message.policyVersion,
          createdAtMs: message.createdAtMs,
          payload: message.encryptedPayload!,
          channelKey: key,
        );
        final decoded = GroupMessageCleartext.decode(clear);
        return decoded == null ? null : message.withDecryptedContent(decoded);
      } catch (_) {
        return null;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    }
    final epoch = message.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptGroupPayload(
        groupId: bundle.manifest.groupId,
        membershipEpoch: epoch,
        author: message.author,
        seq: message.seq,
        prevHash: message.prevHash,
        policyVersion: message.policyVersion,
        createdAtMs: message.createdAtMs,
        payload: message.encryptedPayload!,
        epochKey: key,
      );
      final decoded = GroupMessageCleartext.decode(clear);
      return decoded == null ? null : message.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<SpaceChannelControlCleartext?> _materializeProtectedChannel(
    GroupBundle bundle,
    GroupState state,
    SpaceChannelControlEnvelope envelope, {
    bool requireCurrentAcl = true,
  }) async {
    final id = _channelKeyId(envelope.channelId, envelope.channelEpoch);
    final key = bundle.localChannelEpochKeys[id];
    if (key == null ||
        !_validLocalChannelEpochKey(
          bundle.manifest,
          bundle.control,
          envelope.channelId,
          envelope.channelEpoch,
          key,
        )) {
      return null;
    }
    final entry = _channelDescriptorEntry(
      bundle.manifest,
      bundle.control,
      envelope.keyDescriptor,
    );
    if (entry == null ||
        jsonEncode(entry.channelControl?.toJson()) !=
            jsonEncode(envelope.toJson())) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptSpaceChannelControlPayload(
        spaceId: envelope.spaceId,
        channelId: envelope.channelId,
        channelEpoch: envelope.channelEpoch,
        keyCommitment: envelope.keyDescriptor.keyCommitment,
        author: entry.author,
        policyVersion: entry.policyVersion,
        createdAtMs: entry.createdAtMs,
        payload: envelope.encryptedControl,
        channelKey: key,
      );
      final decoded = SpaceChannelControlCleartext.decode(clear);
      if (decoded == null ||
          decoded.channel.spaceId != bundle.manifest.groupId ||
          decoded.channel.channelId != envelope.channelId ||
          decoded.channel.kind == SpaceChannelKind.category ||
          decoded.channel.categoryId != null ||
          decoded.channel.isDefault ||
          !decoded.recipients.contains(_signer.selfId) ||
          decoded.recipients.length != envelope.keyDescriptor.recipientCount ||
          (requireCurrentAcl &&
              decoded.recipients.any(
                (recipient) => !state.isMember(recipient),
              ))) {
        return null;
      }
      // V1 keeps every current owner/admin able to revoke access and rotate
      // the channel after a membership mutation. Omitting one would strand an
      // undecryptable ACL subtree and make revocation depend on the creator.
      if (requireCurrentAcl) {
        for (final member in state.members.values) {
          if (member.role.rank >= GroupRole.admin.rank &&
              !decoded.recipients.contains(member.nodeId)) {
            return null;
          }
        }
      }
      return decoded;
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<Map<String, SpaceChannelControlCleartext>> _protectedChannelsOf(
    GroupBundle bundle,
    GroupState state,
  ) async {
    final result = <String, SpaceChannelControlCleartext>{};
    for (final envelope in state.protectedChannels.values) {
      final clear = await _materializeProtectedChannel(bundle, state, envelope);
      if (clear != null) result[envelope.channelId.hex] = clear;
    }
    return result;
  }

  /// Decrypt and authorize accepted V14 moderation evidence for channels the
  /// current device can still see. The outer fold proves signature, chain,
  /// policy version, moderator rank and current channel epoch; this second
  /// phase proves the hidden target/reference against the exact prior control
  /// prefix. Invalid ciphertext is inert and never weakens the clear log.
  Future<List<SpaceModerationRecord>> _protectedModerationRecordsOf(
    GroupBundle bundle,
    GroupState state,
  ) async {
    if (state.protectedModeration.isEmpty ||
        !SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const [];
    }
    final currentChannels = await _protectedChannelsOf(bundle, state);
    if (currentChannels.isEmpty) return const [];
    final accepted = _acceptedControl(bundle.manifest, bundle.control);
    final records = <SpaceModerationRecord>[];
    for (var index = 0; index < accepted.length; index++) {
      final entry = accepted[index];
      final envelope = entry.channelModeration;
      if (envelope == null || currentChannels[envelope.channelId.hex] == null) {
        continue;
      }
      SpaceChannelControlEnvelope? channelRevision;
      for (var prior = index - 1; prior >= 0; prior--) {
        final candidate = accepted[prior].channelControl;
        if (candidate?.channelId == envelope.channelId &&
            candidate?.channelEpoch == envelope.channelEpoch) {
          channelRevision = candidate;
          break;
        }
      }
      if (channelRevision == null) continue;
      final channelAtAction = await _materializeProtectedChannel(
        bundle,
        state,
        channelRevision,
        requireCurrentAcl: false,
      );
      if (channelAtAction == null ||
          channelAtAction.channel.access != SpaceChannelAccess.restricted ||
          channelAtAction.channel.kind != SpaceChannelKind.text ||
          channelAtAction.channel.archived) {
        continue;
      }
      final key =
          bundle.localChannelEpochKeys[_channelKeyId(
            envelope.channelId,
            envelope.channelEpoch,
          )];
      if (key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            envelope.channelId,
            envelope.channelEpoch,
            key,
          )) {
        continue;
      }
      Uint8List? clear;
      try {
        clear = await decryptSpaceChannelModerationPayload(
          spaceId: envelope.spaceId,
          channelId: envelope.channelId,
          channelEpoch: envelope.channelEpoch,
          author: entry.author,
          seq: entry.seq,
          prevHash: entry.prevHash,
          policyVersion: entry.policyVersion,
          createdAtMs: entry.createdAtMs,
          payload: envelope.encryptedAction,
          channelKey: key,
        );
        final action = SpaceModerationAction.fromJson(
          jsonDecode(utf8.decode(clear, allowMalformed: false)),
        );
        final reference = action?.reference;
        if (action == null ||
            action.kind != SpaceModerationKind.deleteMessage ||
            action.scope != SpaceModerationScope.channel ||
            action.channelId != envelope.channelId ||
            action.createdAtMs != entry.createdAtMs ||
            reference?.kind != SpaceModerationReferenceKind.message ||
            reference?.channelId != envelope.channelId ||
            reference?.author != action.target) {
          continue;
        }
        final historical = foldControlLog(
          owner: bundle.manifest.owner,
          entries: accepted.sublist(0, index),
          verify: (candidate) => _validControlFor(bundle.manifest, candidate),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        final actorRole = historical.roleOf(entry.author);
        final targetRole = historical.roleOf(action.target);
        final authorized =
            actorRole != null &&
            SpaceAcl.authorizeControlContext(
              author: entry.author,
              authorRole: actorRole,
              policy: historical.accessPolicy,
              op: ControlOp.moderate,
              targetRole: targetRole,
              target: action.target,
              channelId: action.channelId,
              moderationTargetsRemovedContent: true,
            ).allowed;
        if (!authorized) continue;
        final actionId = '${entry.author.hex}:${entry.seq}';
        records.add(
          SpaceModerationRecord(
            actionId: actionId,
            actor: entry.author,
            actionSeq: entry.seq,
            action: action,
          ),
        );
      } catch (_) {
        // A copied, corrupt or unauthorized ciphertext is signed opaque
        // evidence only. It never becomes an enforceable moderation action.
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    }
    return List.unmodifiable(records);
  }

  /// Materialize the signed retention timeline visible to this device. V9
  /// rows are already clear; V15 rows are decrypted only for a currently
  /// visible restricted channel and validated against its historical epoch.
  ///
  /// [hiddenThroughMs] is the fail-closed boundary caused by an accepted but
  /// locally unreadable encrypted revision. A later readable revision makes
  /// messages created after that activation safe again; older content remains
  /// hidden because a destructive policy may already have retired it.
  Future<
    ({List<SpaceRetentionRevision> revisions, Map<String, int> hiddenThroughMs})
  >
  _materializedRetentionHistory(
    GroupBundle bundle,
    GroupState state, {
    Map<String, SpaceChannelControlCleartext>? currentChannels,
  }) async {
    final visibleChannels =
        currentChannels ?? await _protectedChannelsOf(bundle, state);
    final accepted = _acceptedControl(bundle.manifest, bundle.control);
    final revisions = <SpaceRetentionRevision>[];
    final unresolved = <String>{};
    final hiddenThrough = <String, int>{};
    var lastActivationMs = 0;

    for (var index = 0; index < accepted.length; index++) {
      final entry = accepted[index];
      if (entry.op != ControlOp.setRetention) continue;
      final activatedAt = entry.createdAtMs < lastActivationMs
          ? lastActivationMs
          : entry.createdAtMs;
      lastActivationMs = activatedAt;
      final clearPolicy = entry.retentionPolicy;
      if (clearPolicy != null) {
        revisions.add(
          SpaceRetentionRevision(
            policy: clearPolicy,
            activatedAtMs: activatedAt,
            author: entry.author,
            authorSeq: entry.seq,
          ),
        );
        continue;
      }

      final envelope = entry.channelRetention;
      if (envelope == null ||
          visibleChannels[envelope.channelId.hex] == null ||
          state.protectedRetention['${entry.author.hex}:${entry.seq}'] ==
              null) {
        continue;
      }
      final channelHex = envelope.channelId.hex;
      SpaceChannelControlEnvelope? channelRevision;
      for (var prior = index - 1; prior >= 0; prior--) {
        final candidate = accepted[prior].channelControl;
        if (candidate?.channelId == envelope.channelId &&
            candidate?.channelEpoch == envelope.channelEpoch) {
          channelRevision = candidate;
          break;
        }
      }
      final channelAtPolicy = channelRevision == null
          ? null
          : await _materializeProtectedChannel(
              bundle,
              state,
              channelRevision,
              requireCurrentAcl: false,
            );
      final key =
          bundle.localChannelEpochKeys[_channelKeyId(
            envelope.channelId,
            envelope.channelEpoch,
          )];
      if (channelAtPolicy == null ||
          channelAtPolicy.channel.access != SpaceChannelAccess.restricted ||
          channelAtPolicy.channel.kind != SpaceChannelKind.text ||
          key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            envelope.channelId,
            envelope.channelEpoch,
            key,
          )) {
        unresolved.add(channelHex);
        continue;
      }

      Uint8List? clear;
      try {
        clear = await decryptSpaceChannelRetentionPayload(
          spaceId: envelope.spaceId,
          channelId: envelope.channelId,
          channelEpoch: envelope.channelEpoch,
          author: entry.author,
          seq: entry.seq,
          prevHash: entry.prevHash,
          policyVersion: entry.policyVersion,
          createdAtMs: entry.createdAtMs,
          payload: envelope.encryptedPolicy,
          channelKey: key,
        );
        final policy = SpaceRetentionPolicy.fromJson(
          jsonDecode(utf8.decode(clear, allowMalformed: false)),
        );
        if (policy == null || policy.channelId != envelope.channelId) {
          unresolved.add(channelHex);
          continue;
        }
        revisions.add(
          SpaceRetentionRevision(
            policy: policy,
            activatedAtMs: activatedAt,
            author: entry.author,
            authorSeq: entry.seq,
          ),
        );
        if (unresolved.remove(channelHex)) {
          final previous = hiddenThrough[channelHex] ?? -1;
          if (activatedAt > previous) hiddenThrough[channelHex] = activatedAt;
        }
      } catch (_) {
        unresolved.add(channelHex);
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    }
    for (final channelHex in unresolved) {
      hiddenThrough[channelHex] = 0x7fffffffffffffff;
    }
    return (
      revisions: List<SpaceRetentionRevision>.unmodifiable(revisions),
      hiddenThroughMs: Map<String, int>.unmodifiable(hiddenThrough),
    );
  }

  SpaceRetentionPolicy _effectiveRetentionPolicy(
    Iterable<SpaceRetentionRevision> revisions, [
    NodeId? channelId,
  ]) {
    SpaceRetentionPolicy space = const SpaceRetentionPolicy(
      mode: SpaceRetentionMode.keepForever,
    );
    SpaceRetentionPolicy? channel;
    for (final revision in revisions) {
      final policy = revision.policy;
      if (policy.channelId == null) {
        space = policy;
      } else if (policy.channelId == channelId) {
        channel = policy.mode == SpaceRetentionMode.inherit ? null : policy;
      }
    }
    return channel ?? space;
  }

  /// Clear (V9) retention revisions only, with the same monotone activation
  /// clamp as [_materializedRetentionHistory]. Synchronous callers (snapshot
  /// assembly) use this subset; restricted-channel envelopes need key
  /// decryption and are enforced by the async sync/sweep paths instead.
  List<SpaceRetentionRevision> _clearRetentionRevisions(GroupBundle bundle) {
    if (!bundle.manifest.isSpace) return const [];
    final revisions = <SpaceRetentionRevision>[];
    var lastActivationMs = 0;
    for (final entry in _acceptedControl(bundle.manifest, bundle.control)) {
      if (entry.op != ControlOp.setRetention) continue;
      final activatedAt = entry.createdAtMs < lastActivationMs
          ? lastActivationMs
          : entry.createdAtMs;
      lastActivationMs = activatedAt;
      final policy = entry.retentionPolicy;
      if (policy == null) continue;
      revisions.add(
        SpaceRetentionRevision(
          policy: policy,
          activatedAtMs: activatedAt,
          author: entry.author,
          authorSeq: entry.seq,
        ),
      );
    }
    return revisions;
  }

  /// True when the signed retention timeline retires this message row (or
  /// space-post comment) at [atMs]. Used symmetrically at the read, serve
  /// (sync/snapshot) and ingest boundaries so retired content is neither
  /// shown, redistributed nor resurrected by a stale holder.
  bool _retentionRetiresMessage({
    required GroupManifest manifest,
    required List<SpaceRetentionRevision> revisions,
    required Map<String, int> hiddenThroughMs,
    required GroupMessage message,
    required int atMs,
  }) {
    if (!manifest.isSpace || (revisions.isEmpty && hiddenThroughMs.isEmpty)) {
      return false;
    }
    final NodeId? effectiveChannelId = message.spacePostId != null
        ? null
        : (message.channelId ?? defaultSpaceChannelId(manifest.groupId));
    final hiddenThrough = effectiveChannelId == null
        ? null
        : hiddenThroughMs[effectiveChannelId.hex];
    if (hiddenThrough != null && message.createdAtMs <= hiddenThrough) {
      return true;
    }
    return spaceRetentionRemoves(
      revisions: revisions,
      createdAtMs: message.createdAtMs,
      atMs: atMs,
      channelId: effectiveChannelId,
    );
  }

  /// True when retention retires this post at [atMs]. Pinned posts are always
  /// preserved (the policy is structurally required to preserve pins).
  bool _retentionRetiresPost({
    required GroupManifest manifest,
    required GroupState state,
    required List<SpaceRetentionRevision> revisions,
    required SpacePost post,
    required int atMs,
  }) {
    if (!manifest.isSpace ||
        revisions.isEmpty ||
        state.postPinFor(post.postId)?.pinned == true) {
      return false;
    }
    return spaceRetentionRemoves(
      revisions: revisions,
      createdAtMs: post.createdAtMs,
      atMs: atMs,
      channelId: null,
    );
  }

  bool _retentionRetiresReaction({
    required GroupManifest manifest,
    required List<SpaceRetentionRevision> revisions,
    required Map<String, int> hiddenThroughMs,
    required GroupReaction reaction,
    required int atMs,
  }) {
    if (!manifest.isSpace || (revisions.isEmpty && hiddenThroughMs.isEmpty)) {
      return false;
    }
    final channelId = reaction.channelId;
    final hiddenThrough = channelId == null
        ? null
        : hiddenThroughMs[channelId.hex];
    if (hiddenThrough != null && reaction.createdAtMs <= hiddenThrough) {
      return true;
    }
    return spaceRetentionRemoves(
      revisions: revisions,
      createdAtMs: reaction.createdAtMs,
      atMs: atMs,
      channelId: channelId,
    );
  }

  /// Serve-time retention cuts. The read-time filter drops the expired prefix
  /// from a served snapshot, but until the sweep physically deletes it there is
  /// no stored cut — so a receiver would orphan the retained suffix (its
  /// prevHash points to an excluded row). Synthesize, per scope, a cut for the
  /// read-time-retired prefix (matching the serve exclusion boundary) and merge
  /// it with the bundle's own cuts, so the served rcut lets the receiver
  /// re-anchor. Read-only: this never deletes; the sweep still owns deletion.
  Map<String, SpaceRetentionCut> _serveRetentionCuts(
    GroupBundle b,
    List<SpaceRetentionRevision> revisions,
    Map<String, int> hiddenThroughMs,
    int atMs,
  ) {
    if (!b.manifest.isSpace || (revisions.isEmpty && hiddenThroughMs.isEmpty)) {
      return b.retentionCuts;
    }
    final byChain = <String, List<GroupMessage>>{};
    for (final m in b.messages) {
      if (!_validMessageFor(b.manifest.groupId, m)) continue;
      byChain
          .putIfAbsent(
            retentionCutKey(_messageChainScope(b.manifest, m), m.author),
            () => [],
          )
          .add(m);
    }
    final forks = _messageForks(
      b.manifest,
      _retainedMessageRows(b.manifest, b.messages),
    );
    final cuts = <String, SpaceRetentionCut>{...b.retentionCuts};
    for (final entry in byChain.entries) {
      final rows = entry.value
        ..sort((left, right) => left.seq.compareTo(right.seq));
      final scope = _messageChainScope(b.manifest, rows.first);
      final fork = forks[entry.key];
      final priorCutSeq = b.retentionCuts[entry.key]?.throughSeq ?? -1;
      GroupMessage? lastRetired;
      for (final m in rows) {
        if (m.seq <= priorCutSeq) continue;
        if (fork != null && m.seq >= fork.seq) break;
        if (!_retentionRetiresMessage(
          manifest: b.manifest,
          revisions: revisions,
          hiddenThroughMs: hiddenThroughMs,
          message: m,
          atMs: atMs,
        )) {
          break;
        }
        lastRetired = m;
      }
      if (lastRetired == null) continue;
      final prior = cuts[entry.key];
      if (prior == null || lastRetired.seq > prior.throughSeq) {
        cuts[entry.key] = SpaceRetentionCut(
          scope: scope,
          author: rows.first.author,
          throughSeq: lastRetired.seq,
          throughHash: groupMessageHash(lastRetired),
          throughCreatedAtMs: lastRetired.createdAtMs,
        );
      }
    }
    return cuts;
  }

  /// Validate a remote retention-cut hint against the local signed retention
  /// timeline. The claimed boundary must itself be expired under the fold and
  /// must not cover any locally retained, still-live row in the same chain.
  bool _acceptableRemoteRetentionCut({
    required GroupManifest manifest,
    required List<SpaceRetentionRevision> revisions,
    required Iterable<GroupMessage> localMessages,
    required SpaceRetentionCut cut,
    required int atMs,
  }) {
    if (!manifest.isSpace || !cut.isStructurallyValid) return false;
    // A remote cut is unsigned, so it must carry the deleted-boundary hash AND
    // the receiver must already hold the retained anchor whose prevHash is that
    // boundary. Without this a peer could forge a cut with a high throughSeq +
    // an old throughCreatedAtMs and, delivered before the victim's rows sync,
    // hide those rows (they land seq <= throughSeq and are filtered out). The
    // anchor requirement means we only trust a cut for a chain we have actually
    // synced past — where the "no live local row <= throughSeq" check below is
    // meaningful. A hash-less legacy remote cut is never accepted.
    if (cut.throughHash.isEmpty) return false;
    NodeId? channelId;
    final scopeHead = cut.scope.split('|').first;
    if (!scopeHead.startsWith('post:')) {
      try {
        channelId = NodeId.fromHex(scopeHead);
      } catch (_) {
        return false;
      }
    }
    if (!spaceRetentionRemoves(
      revisions: revisions,
      createdAtMs: cut.throughCreatedAtMs,
      atMs: atMs,
      channelId: channelId,
    )) {
      return false;
    }
    var hasAnchor = false;
    for (final message in localMessages) {
      if (message.author != cut.author ||
          _messageChainScope(manifest, message) != cut.scope) {
        continue;
      }
      if (message.prevHash == cut.throughHash) hasAnchor = true;
      if (message.seq > cut.throughSeq) continue;
      // A local row the cut claims to retire must genuinely be expired;
      // otherwise the hint would hide live history.
      if (!spaceRetentionRemoves(
        revisions: revisions,
        createdAtMs: message.createdAtMs,
        atMs: atMs,
        channelId: channelId,
      )) {
        return false;
      }
    }
    return hasAnchor;
  }

  Future<GroupReaction?> _materializeEncryptedReaction(
    GroupBundle bundle,
    GroupReaction reaction,
  ) async {
    if (!reaction.isEncrypted) return reaction;
    if (reaction.isChannelEncrypted) {
      final channelId = reaction.channelId!;
      final epoch = reaction.channelEpoch!;
      final key = bundle.localChannelEpochKeys[_channelKeyId(channelId, epoch)];
      if (key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            channelId,
            epoch,
            key,
          )) {
        return null;
      }
      Uint8List? clear;
      try {
        clear = await decryptSpaceChannelReactionPayload(
          spaceId: bundle.manifest.groupId,
          channelId: channelId,
          channelEpoch: epoch,
          author: reaction.author,
          seq: reaction.seq,
          reactionVersion: reaction.version,
          lifecycleGeneration: reaction.lifecycleGeneration ?? '',
          createdAtMs: reaction.createdAtMs,
          payload: reaction.encryptedPayload!,
          channelKey: key,
        );
        final decoded = GroupReactionCleartext.decode(clear);
        return decoded == null ||
                decoded.schemaVersion != 2 ||
                decoded.targetKind != ReactionTargetKind.message
            ? null
            : reaction.withDecryptedContent(decoded);
      } catch (_) {
        return null;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    }
    final epoch = reaction.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptGroupReactionPayload(
        groupId: bundle.manifest.groupId,
        membershipEpoch: epoch,
        author: reaction.author,
        seq: reaction.seq,
        createdAtMs: reaction.createdAtMs,
        reactionVersion: reaction.version,
        lifecycleGeneration: reaction.lifecycleGeneration ?? '',
        payload: reaction.encryptedPayload!,
        epochKey: key,
      );
      final decoded = GroupReactionCleartext.decode(clear);
      final expectedSchema = reaction.version == 2 ? 1 : 2;
      return decoded == null || decoded.schemaVersion != expectedSchema
          ? null
          : reaction.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<SpacePost?> _materializeEncryptedPost(
    GroupBundle bundle,
    SpacePost post,
  ) async {
    if (!post.isEncrypted) return post;
    final epoch = post.membershipEpoch!;
    final key = bundle.localEpochKeys[epoch];
    if (key == null ||
        !_validLocalEpochKey(bundle.manifest, bundle.control, epoch, key)) {
      return null;
    }
    Uint8List? clear;
    try {
      clear = await decryptSpacePostPayload(
        spaceId: post.spaceId,
        membershipEpoch: epoch,
        author: post.author,
        seq: post.seq,
        prevHash: post.prevHash,
        postType: post.type.name,
        visibility: post.visibility.name,
        policyVersion: post.policyVersion,
        createdAtMs: post.createdAtMs,
        publishedAtMs: post.publishedAtMs,
        controlFrontier: post.controlFrontier?.toJson() ?? const [],
        controlCheckpointHash: post.controlCheckpointHash ?? '',
        postOperation: post.version >= 7 ? post.operation.name : '',
        targetSeq: post.version >= 7 ? post.targetSeq : null,
        lifecycleGeneration: post.lifecycleGeneration ?? '',
        payload: post.encryptedPayload!,
        epochKey: key,
      );
      final decoded = SpacePostCleartext.decode(clear);
      if (decoded == null ||
          decoded.isTombstone !=
              (post.operation == SpacePostOperation.delete)) {
        return null;
      }
      return post.withDecryptedContent(decoded);
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  }

  Future<
    ({List<GroupEpochRecipientEnvelope> envelopes, Map<int, Uint8List> keys})
  >
  _mergeEpochMaterial({
    required GroupManifest manifest,
    required List<ControlEntry> control,
    required List<GroupEpochRecipientEnvelope> existingEnvelopes,
    required Map<int, Uint8List> existingKeys,
    required List<GroupEpochRecipientEnvelope> incomingEnvelopes,
  }) async {
    final accepted = _acceptedControl(manifest, control);
    final keys = <int, Uint8List>{
      for (final entry in existingKeys.entries)
        if (_validLocalEpochKey(manifest, control, entry.key, entry.value))
          entry.key: entry.value,
    };
    final envelopes = <GroupEpochRecipientEnvelope>[];
    final seen = <String>{};
    void acceptEnvelope(
      GroupEpochRecipientEnvelope envelope, {
      required bool fromWire,
    }) {
      GroupEpochDescriptor? descriptor;
      for (final entry in accepted) {
        final candidate = entry.epochDescriptor;
        if (candidate != null &&
            candidate.groupId == envelope.groupId &&
            candidate.epoch == envelope.epoch &&
            candidate.keyCommitment == envelope.keyCommitment &&
            candidate.recipientCount == envelope.recipientCount &&
            verifyGroupEpochEnvelope(
              descriptor: candidate,
              envelope: envelope,
            )) {
          descriptor = candidate;
          break;
        }
      }
      if (descriptor == null ||
          (fromWire && envelope.recipient != _signer.selfId) ||
          !verifyGroupEpochEnvelope(
            descriptor: descriptor,
            envelope: envelope,
          )) {
        return;
      }
      final identity =
          '${envelope.epoch}:${envelope.recipient.hex}:${envelope.keyCommitment}';
      if (seen.add(identity)) envelopes.add(envelope);
    }

    for (final envelope in existingEnvelopes) {
      acceptEnvelope(envelope, fromWire: false);
    }
    for (final envelope in incomingEnvelopes) {
      acceptEnvelope(envelope, fromWire: true);
    }

    final opener = _epochService;
    if (opener != null) {
      for (final envelope in envelopes) {
        if (envelope.recipient != _signer.selfId ||
            keys.containsKey(envelope.epoch)) {
          continue;
        }
        GroupEpochDescriptor? descriptor;
        for (final entry in accepted) {
          final candidate = entry.epochDescriptor;
          if (candidate != null &&
              candidate.epoch == envelope.epoch &&
              candidate.keyCommitment == envelope.keyCommitment &&
              verifyGroupEpochEnvelope(
                descriptor: candidate,
                envelope: envelope,
              )) {
            descriptor = candidate;
            break;
          }
        }
        if (descriptor == null) continue;
        final issuer = _descriptorEntry(manifest, control, descriptor)?.author;
        if (issuer == null) continue;
        try {
          final opened = await opener.openEpoch(
            descriptor: descriptor,
            envelope: envelope,
            recipient: _signer.selfId,
            expectedIssuer: issuer,
            ourCertVersion: ourCertVersion,
          );
          keys[opened.epoch] = opened.key;
        } catch (_) {
          // Invalid, copied, stale or wrong-recipient epoch material is a
          // terminal silent drop: never reveal membership/key possession.
        }
      }
    }
    return (envelopes: envelopes, keys: keys);
  }

  ControlEntry? _channelDescriptorEntry(
    GroupManifest manifest,
    List<ControlEntry> control,
    GroupEpochDescriptor descriptor,
  ) {
    for (final entry in _acceptedControl(manifest, control)) {
      final candidate = entry.channelControl?.keyDescriptor;
      if (candidate != null && _sameEpochDescriptor(candidate, descriptor)) {
        return entry;
      }
    }
    return null;
  }

  bool _validLocalChannelEpochKey(
    GroupManifest manifest,
    List<ControlEntry> control,
    NodeId channelId,
    int epoch,
    Uint8List key,
  ) {
    if (key.length != 32) return false;
    for (final entry in _acceptedControl(manifest, control)) {
      final descriptor = entry.channelControl?.keyDescriptor;
      if (descriptor == null ||
          descriptor.groupId != channelId ||
          descriptor.epoch != epoch) {
        continue;
      }
      return descriptor.keyCommitment ==
          groupEpochKeyCommitment(groupId: channelId, epoch: epoch, key: key);
    }
    return false;
  }

  Future<
    ({List<GroupEpochRecipientEnvelope> envelopes, Map<String, Uint8List> keys})
  >
  _mergeChannelEpochMaterial({
    required GroupManifest manifest,
    required List<ControlEntry> control,
    required List<GroupEpochRecipientEnvelope> existingEnvelopes,
    required Map<String, Uint8List> existingKeys,
    required List<GroupEpochRecipientEnvelope> incomingEnvelopes,
  }) async {
    final accepted = _acceptedControl(manifest, control);
    final descriptors =
        <String, ({GroupEpochDescriptor value, NodeId issuer})>{};
    for (final entry in accepted) {
      final descriptor = entry.channelControl?.keyDescriptor;
      if (descriptor != null) {
        descriptors[_channelKeyId(descriptor.groupId, descriptor.epoch)] = (
          value: descriptor,
          issuer: entry.author,
        );
      }
    }
    final keys = <String, Uint8List>{
      for (final entry in existingKeys.entries)
        if (_validChannelKeyId(entry.key)) entry.key: entry.value,
    };
    keys.removeWhere((id, key) {
      final separator = id.lastIndexOf(':');
      try {
        return !_validLocalChannelEpochKey(
          manifest,
          control,
          NodeId.fromHex(id.substring(0, separator)),
          int.parse(id.substring(separator + 1)),
          key,
        );
      } catch (_) {
        return true;
      }
    });
    final envelopes = <GroupEpochRecipientEnvelope>[];
    final seen = <String>{};
    final authorizedIncomingScopes = <String>{};
    for (final envelope in incomingEnvelopes) {
      final id = _channelKeyId(envelope.groupId, envelope.epoch);
      final descriptor = descriptors[id]?.value;
      if (envelope.recipient == _signer.selfId &&
          descriptor != null &&
          verifyGroupEpochEnvelope(
            descriptor: descriptor,
            envelope: envelope,
          )) {
        authorizedIncomingScopes.add(id);
      }
    }

    void acceptEnvelope(
      GroupEpochRecipientEnvelope envelope, {
      required bool fromWire,
    }) {
      final descriptor =
          descriptors[_channelKeyId(envelope.groupId, envelope.epoch)]?.value;
      if (descriptor == null ||
          (fromWire &&
              !authorizedIncomingScopes.contains(
                _channelKeyId(envelope.groupId, envelope.epoch),
              )) ||
          !verifyGroupEpochEnvelope(
            descriptor: descriptor,
            envelope: envelope,
          )) {
        return;
      }
      final identity =
          '${envelope.groupId.hex}:${envelope.epoch}:'
          '${envelope.recipient.hex}:${envelope.keyCommitment}';
      if (seen.add(identity)) envelopes.add(envelope);
    }

    for (final envelope in existingEnvelopes) {
      acceptEnvelope(envelope, fromWire: false);
    }
    for (final envelope in incomingEnvelopes) {
      acceptEnvelope(envelope, fromWire: true);
    }

    final opener = _epochService;
    if (opener != null) {
      for (final envelope in envelopes) {
        final id = _channelKeyId(envelope.groupId, envelope.epoch);
        if (envelope.recipient != _signer.selfId || keys.containsKey(id)) {
          continue;
        }
        final source = descriptors[id];
        if (source == null) continue;
        try {
          final opened = await opener.openEpoch(
            descriptor: source.value,
            envelope: envelope,
            recipient: _signer.selfId,
            expectedIssuer: source.issuer,
            ourCertVersion: ourCertVersion,
          );
          keys[id] = opened.key;
        } catch (_) {
          // Wrong recipient, copied scope or invalid proof: silent drop.
        }
      }
    }
    return (envelopes: envelopes, keys: keys);
  }

  Future<List<GroupReaction>> _compactReactions(GroupBundle bundle) async {
    final latest = <String, GroupReaction>{};
    final heads = <String, GroupReaction>{};
    for (final stored in bundle.reactions) {
      if (!_validReactionFor(bundle.manifest.groupId, stored)) continue;
      final r = await _materializeEncryptedReaction(bundle, stored);
      if (r == null) continue;
      final key = '${r.author.hex}|${r.targetKind.name}|${r.target}';
      final current = latest[key];
      if (current == null || isNewerGroupReaction(r, current)) {
        latest[key] = r;
      }
      final headKey = '${_reactionGeneration(stored)}|${r.author.hex}';
      final head = heads[headKey];
      if (head == null || r.seq > head.seq) heads[headKey] = r;
    }
    final keep = <String>{
      for (final r in latest.values) '${r.author.hex}:${r.seq}',
      for (final r in heads.values) '${r.author.hex}:${r.seq}',
    };
    return [
      for (final r in bundle.reactions)
        if (_validReactionFor(bundle.manifest.groupId, r) &&
            keep.contains('${r.author.hex}:${r.seq}'))
          r,
    ];
  }

  List<GroupMessage> _compactDeviceMessages(
    NodeId groupId,
    List<GroupMessage> input,
  ) {
    final latest =
        <
          (DeviceSyncKind, String),
          ({DeviceSyncEvent event, GroupMessage message})
        >{};
    final heads = <String, GroupMessage>{};
    final unknown = <String>{};
    for (final m in input) {
      if (!_validMessageFor(groupId, m)) continue;
      final head = heads[m.author.hex];
      if (head == null || m.seq > head.seq) heads[m.author.hex] = m;
      final event = DeviceSyncEvent.fromBody(m.body);
      if (event == null) {
        // Forward-compatible: an older build must not erase a newer event kind.
        unknown.add(m.ref);
        continue;
      }
      final key = (event.kind, event.key);
      final current = latest[key];
      if (current == null ||
          isNewerDeviceSync(event, current.event) ||
          (!isNewerDeviceSync(current.event, event) &&
              _messageIdentityCompare(m, current.message) > 0)) {
        latest[key] = (event: event, message: m);
      }
    }
    final keep = <String>{
      ...unknown,
      for (final v in latest.values) v.message.ref,
      for (final m in heads.values) m.ref,
    };
    return [
      for (final m in input)
        if (_validMessageFor(groupId, m) && keep.contains(m.ref)) m,
    ];
  }

  int _messageIdentityCompare(GroupMessage a, GroupMessage b) {
    final author = a.author.hex.compareTo(b.author.hex);
    return author != 0 ? author : a.seq.compareTo(b.seq);
  }

  /// Compact only logs whose old entries are superseded state. Ordinary group
  /// messages are chat history and are never removed. Reaction winners and
  /// device-sync LWW winners are retained together with each author's max-seq
  /// row, preserving the current fold, next-seq allocation, and gap-fill
  /// high-water. Invalid/cross-group rows are scrubbed as part of the rewrite.
  Future<GroupLogCompaction?> compactStateLogs(NodeId groupId) async {
    return _serialized(groupId, () => _compactStateLogs(groupId));
  }

  Future<GroupLogCompaction?> _compactStateLogs(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    final control = [
      for (final e in b.control)
        if (_validControlFor(b.manifest, e)) e,
    ];
    final messages = b.manifest.name == kDeviceGroupName
        ? _compactDeviceMessages(groupId, b.messages)
        : _retainedMessageRows(b.manifest, b.messages);
    final reactions = await _compactReactions(b);
    final posts = _retainedPostRows(groupId, b.posts);
    final result = GroupLogCompaction(
      messagesBefore: b.messages.length,
      messagesAfter: messages.length,
      postsBefore: b.posts.length,
      postsAfter: posts.length,
      controlBefore: b.control.length,
      controlAfter: control.length,
      reactionsBefore: b.reactions.length,
      reactionsAfter: reactions.length,
    );
    if (result.changed) {
      await _save(
        b.copyWith(
          control: control,
          messages: messages,
          posts: posts,
          reactions: reactions,
        ),
      );
    }
    return result;
  }

  /// The group index lists EVERY group/Space id, so in one settings record
  /// it outgrows the hidden-volume record capacity at roughly 30+ groups
  /// (~2.2 KiB) — from then on creating or even ingesting any new group
  /// throws PayloadTooLarge (found live 2026-07-25 on the stand fixture,
  /// right after container compaction proved the store itself healthy).
  /// The index therefore lives in the chunked file store; the legacy
  /// settings value is still read as a fallback for stores written before
  /// the move. Consumers keep their own strictness: [_index] is lenient,
  /// [_groupIdsForGc] stays fail-closed on malformed content.
  Future<String?> _readIndexJson() async {
    // Same race as a bundle, worse consequence: a miss here falls back to the
    // legacy settings copy, and the next _setIndex persists that stale list —
    // an id of a purged group comes back and, having no bundle and no
    // tombstone, silently disables shared-content GC. The old comment on the
    // legacy clear ("inert because reads prefer the file") holds only while
    // the file read cannot miss.
    await _awaitStoreWrite('groups.index');
    final blob = await _storage.loadFile('groups.index');
    if (blob != null) return utf8.decode(blob, allowMalformed: true);
    return _storage.getSetting('groups.index');
  }

  Future<List<String>> _index() async {
    final raw = await _readIndexJson();
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      return d is List ? d.whereType<String>().toList() : [];
    } catch (_) {
      return [];
    }
  }

  /// Every id in the group index, with whether a bundle actually backs it and
  /// whether a deletion tombstone explains its absence.
  ///
  /// Diagnostic: an indexed id with no bundle and no tombstone ("a ghost")
  /// makes [sweepSharedContentGarbage] refuse to collect anything at all, and
  /// nothing else can name one — the index is not otherwise observable from
  /// outside. Read-only; it neither repairs nor prunes.
  Future<List<({String hex, bool hasBundle, bool tombstoned})>>
  indexedGroups() async {
    final out = <({String hex, bool hasBundle, bool tombstoned})>[];
    for (final hex in await _index()) {
      NodeId groupId;
      try {
        groupId = NodeId.fromHex(hex);
      } catch (_) {
        out.add((hex: hex, hasBundle: false, tombstoned: false));
        continue;
      }
      out.add((
        hex: hex,
        hasBundle: await _loadBundleRaw(groupId) != null,
        tombstoned: await deletedSpaceTombstone(groupId) != null,
      ));
    }
    return out;
  }

  /// Remove index entries that nothing backs: no bundle, no kind hint, no
  /// deletion tombstone.
  ///
  /// One such entry makes [sweepSharedContentGarbage] refuse to collect
  /// anything at all — it cannot see that group's references, so it fail-closes
  /// rather than risk deleting live content. The entries themselves are debris
  /// from the index race closed in [_readIndexJson]: a stale legacy list got
  /// persisted and resurrected an id whose group had been purged.
  ///
  /// Deliberately opt-in and dry by default. All three signals must be absent:
  /// the kind hint is written inside [_save], so its absence means the bundle
  /// was never written here (or was purged along with it), and requiring the
  /// tombstone check too keeps a recoverable Space out of reach. Returns the
  /// ids it removed, or would remove when [apply] is false.
  Future<List<String>> repairIndexGhosts({bool apply = false}) async {
    final ids = await _index();
    final ghosts = <String>[];
    for (final hex in ids) {
      NodeId groupId;
      try {
        groupId = NodeId.fromHex(hex);
      } catch (_) {
        ghosts.add(hex);
        continue;
      }
      if (await _loadBundleRaw(groupId) != null) continue;
      if (await _readGroupKindHint(hex) != null) continue;
      if (await deletedSpaceTombstone(groupId) != null) continue;
      ghosts.add(hex);
    }
    if (apply && ghosts.isNotEmpty) {
      await _setIndex([
        for (final hex in ids)
          if (!ghosts.contains(hex)) hex,
      ]);
      devLog(
        () => 'xVeil[group]: index repaired — removed ${ghosts.length} '
            'entries nothing backed',
      );
    }
    return ghosts;
  }

  Future<void> _setIndex(List<String> ids) async {
    final write = _storage.storeFile(
      'groups.index',
      Uint8List.fromList(utf8.encode(jsonEncode(ids))),
      name: 'groups-index',
    );
    _bundleWrites['groups.index'] = write;
    try {
      await write;
    } finally {
      if (identical(_bundleWrites['groups.index'], write)) {
        _bundleWrites.remove('groups.index');
      }
    }
    try {
      await _storage.putSetting('groups.index', '');
    } catch (_) {
      // The file copy is authoritative; a lingering legacy value is inert
      // because reads prefer the file.
    }
  }

  // ── Group-kind hint index. PURE PERF HINT: the hourly maintenance loops
  // (retention sweep, deleted-Space purge) used to load and decrypt EVERY
  // bundle just to learn `manifest.isSpace` / "has any retention row" —
  // ~30s on a grown store. The hint lets them skip bundles that cannot
  // match. Correctness never depends on it: a missing/unreadable hint means
  // "load the bundle as before" (fail-open), and it is recomputed from the
  // full bundle on every save. The hint is written BEFORE the bundle blob so
  // a crash between the two can only over-approximate (claim a retention row
  // the old blob does not have yet), which costs one load — never a skipped
  // enforcement.
  //
  // Values: 'g' legacy group; 's' Space with no setRetention control rows
  // (can never have a bounded policy to enforce); 'sb' Space with at least
  // one setRetention row (a syntactic over-approximation of "bounded":
  // materialized revisions exist only for setRetention entries).

  String _groupKindHintKey(String hex) => 'group.kind.v1.$hex';
  final Map<String, String> _groupKindHints = {};

  String _computeGroupKindHint(GroupBundle b) => !b.manifest.isSpace
      ? 'g'
      : b.control.any((entry) => entry.op == ControlOp.setRetention)
      ? 'sb'
      : 's';

  Future<String?> _readGroupKindHint(String hex) async {
    final cached = _groupKindHints[hex];
    if (cached != null) return cached;
    final raw = await _storage.getSetting(_groupKindHintKey(hex));
    if (raw == 'g' || raw == 's' || raw == 'sb') {
      _groupKindHints[hex] = raw!;
      return raw;
    }
    return null;
  }

  Future<void> _writeGroupKindHint(String hex, String hint) async {
    if (_groupKindHints[hex] == hint) return;
    try {
      if (await _storage.getSetting(_groupKindHintKey(hex)) != hint) {
        await _storage.putSetting(_groupKindHintKey(hex), hint);
      }
      _groupKindHints[hex] = hint;
    } catch (_) {
      // Never let a hint write failure break a save; the next maintenance
      // pass simply loads the bundle.
      _groupKindHints.remove(hex);
    }
  }

  Future<void> _clearGroupKindHint(String hex) async {
    _groupKindHints.remove(hex);
    try {
      await _storage.putSetting(_groupKindHintKey(hex), '');
    } catch (_) {
      // A stale hint on a purged id is harmless: the bundle is gone, so a
      // later maintenance load simply finds nothing.
    }
  }

  String _spaceDeletionTombstoneKey(NodeId spaceId) =>
      'space.deleted:${spaceId.hex}.v1';

  Future<SpaceDeletionTombstone?> deletedSpaceTombstone(NodeId spaceId) async {
    final raw = await _storage.getSetting(_spaceDeletionTombstoneKey(spaceId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final tombstone = SpaceDeletionTombstone.fromJson(jsonDecode(raw));
      return tombstone?.spaceId == spaceId ? tombstone : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDeletedSpaceTombstone(SpaceDeletionTombstone tombstone) =>
      _storage.putSetting(
        _spaceDeletionTombstoneKey(tombstone.spaceId),
        jsonEncode(tombstone.toJson()),
      );

  Future<void> _clearDeletedSpaceTombstone(NodeId spaceId) =>
      _storage.putSetting(_spaceDeletionTombstoneKey(spaceId), '');

  String _key(NodeId groupId) => 'group:${groupId.hex}';

  /// Read a group's serialized bundle. It lives in the CHUNKED file-store, not a
  /// single setting: an inline image attachment can push the JSON well past the
  /// ~4 KB single-setting cap (HvException.PayloadTooLarge). Falls back to the
  /// legacy settings key for groups written before the store moved.
  /// Bundle writes in flight, by store key. A read that lands inside one
  /// would see the store's documented "unknown OR INCOMPLETE" null and report
  /// the group as missing — see [_loadBundleRaw].
  final Map<String, Future<void>> _bundleWrites = {};

  /// How long a read waits out a bundle write before reading regardless.
  /// Mutable for tests.
  Duration bundleWriteWait = const Duration(seconds: 5);

  /// Wait out an in-flight write of [key] before reading it.
  ///
  /// storeFile is not atomic to readers and loadFile answers null for a file
  /// that is unknown OR INCOMPLETE, so a read landing inside a write cannot
  /// tell "being replaced" from "not there". What that costs depends on the
  /// key: for a bundle it made the group vanish; for the group index it is
  /// worse, because the miss falls back to the legacy settings copy and the
  /// next write persists THAT — resurrecting ids of groups long gone.
  ///
  /// Only the writer answers for its own failure: a reader that waited still
  /// goes and reads, since inheriting the exception would turn a method whose
  /// contract is "answer null" into one that throws. Bounded, because this is
  /// a read — on timeout we read anyway and land back on the old behaviour for
  /// that one call.
  Future<void> _awaitStoreWrite(String key) async {
    while (true) {
      final pending = _bundleWrites[key];
      if (pending == null) return;
      var timedOut = false;
      await pending
          .timeout(bundleWriteWait, onTimeout: () => timedOut = true)
          .then<void>((_) {}, onError: (_) {});
      if (timedOut) return;
    }
  }

  Future<String?> _loadBundleRaw(NodeId groupId) async {
    final key = _key(groupId);
    // Wait out any replacement of this bundle first. storeFile is not atomic
    // to readers, and loadFile answers null for a half-written file exactly as
    // it does for one that never existed. Callers cannot tell those apart, so
    // a read racing a save made the group vanish: deviceSyncRecords then
    // answered "no records" and cloud reconcile applied nothing at all —
    // measured on the stand as convergence at one row per ten minutes
    // (2026-07-27). The loop re-checks because a second save can start while
    // we await the first.
    await _awaitStoreWrite(key);
    final blob = await _storage.loadFile(key);
    if (blob != null) return utf8.decode(blob);
    return _storage.getSetting(key);
  }

  /// Every way this returns null says the group does not exist, and callers
  /// act on that: a failed load makes [deviceSyncRecords] answer "no records",
  /// which makes cloud reconcile apply nothing at all. So each refusal names
  /// itself — a silent null here reads downstream as a missing group and cost
  /// an evening of looking in the wrong place (2026-07-27).
  void _loadRefused(NodeId groupId, String why) => devLog(
    () => 'xVeil[group]: load ${groupId.short} refused — $why',
  );

  Future<GroupBundle?> load(NodeId groupId) async {
    final raw = await _loadBundleRaw(groupId);
    if (raw == null) {
      _loadRefused(groupId, 'no bundle in the file store nor the legacy key');
      return null;
    }
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      final manifest = GroupManifest.fromJson(d['m']);
      if (manifest == null || !_validManifest(manifest)) {
        _loadRefused(
          groupId,
          manifest == null ? 'manifest did not parse' : 'manifest is invalid',
        );
        return null;
      }
      final control = (d['c'] as List? ?? const [])
          .map(ControlEntry.fromJson)
          .whereType<ControlEntry>()
          .toList();
      final messages = (d['g'] as List? ?? const [])
          .map(GroupMessage.fromJson)
          .whereType<GroupMessage>()
          .toList();
      final posts = (d['p'] as List? ?? const [])
          .map(SpacePost.fromJson)
          .whereType<SpacePost>()
          .toList();
      final reactions = (d['r'] as List? ?? const [])
          .map(GroupReaction.fromJson)
          .whereType<GroupReaction>()
          .toList();
      final publicComments = (d['pc'] as List? ?? const [])
          .map(SpacePublicComment.fromJson)
          .whereType<SpacePublicComment>()
          .toList();
      final publicReactions = (d['pr'] as List? ?? const [])
          .map(SpacePublicReaction.fromJson)
          .whereType<SpacePublicReaction>()
          .toList();
      final epochEnvelopes = (d['ke'] as List? ?? const [])
          .map(GroupEpochRecipientEnvelope.fromJson)
          .whereType<GroupEpochRecipientEnvelope>()
          .toList();
      final channelEpochEnvelopes = (d['cke'] as List? ?? const [])
          .map(GroupEpochRecipientEnvelope.fromJson)
          .whereType<GroupEpochRecipientEnvelope>()
          .toList();
      final localEpochKeys = <int, Uint8List>{};
      final rawKeys = d['kk'];
      if (rawKeys is Map) {
        for (final entry in rawKeys.entries) {
          final epoch = int.tryParse('${entry.key}');
          if (epoch == null ||
              epoch < 0 ||
              epoch > 0xffffffff ||
              entry.value is! String) {
            continue;
          }
          try {
            final key = Uint8List.fromList(base64Decode(entry.value as String));
            if (key.length == 32) localEpochKeys[epoch] = key;
          } catch (_) {
            // Corrupt local key rows are ignored; the retained sealed envelope
            // can recover the key on a later load/ingest.
          }
        }
      }
      final localChannelEpochKeys = <String, Uint8List>{};
      final rawChannelKeys = d['ckk'];
      if (rawChannelKeys is Map) {
        for (final entry in rawChannelKeys.entries) {
          final id = '${entry.key}';
          if (!_validChannelKeyId(id) || entry.value is! String) continue;
          try {
            final key = Uint8List.fromList(base64Decode(entry.value as String));
            if (key.length == 32) localChannelEpochKeys[id] = key;
          } catch (_) {
            // Corrupt local rows are ignored; a retained sealed envelope may
            // recover the key on a later load or sync.
          }
        }
      }
      final sovereignBundle = d['s'] is String
          ? Uint8List.fromList(base64Decode(d['s'] as String))
          : null;
      if (!_validSovereignBundle(manifest, sovereignBundle)) {
        _loadRefused(groupId, 'sovereign bundle did not verify');
        return null;
      }
      final retentionCuts = <String, SpaceRetentionCut>{};
      for (final raw in d['rcut'] as List? ?? const []) {
        final cut = SpaceRetentionCut.fromJson(raw);
        if (cut == null) continue;
        final key = retentionCutKey(cut.scope, cut.author);
        final prior = retentionCuts[key];
        if (prior == null || cut.throughSeq > prior.throughSeq) {
          retentionCuts[key] = cut;
        }
      }
      final material = await _mergeEpochMaterial(
        manifest: manifest,
        control: control,
        existingEnvelopes: epochEnvelopes,
        existingKeys: localEpochKeys,
        incomingEnvelopes: const [],
      );
      final channelMaterial = await _mergeChannelEpochMaterial(
        manifest: manifest,
        control: control,
        existingEnvelopes: channelEpochEnvelopes,
        existingKeys: localChannelEpochKeys,
        incomingEnvelopes: const [],
      );
      return GroupBundle(
        manifest: manifest,
        control: control,
        messages: messages,
        posts: posts,
        reactions: reactions,
        publicComments: publicComments,
        publicReactions: publicReactions,
        epochEnvelopes: material.envelopes,
        localEpochKeys: material.keys,
        channelEpochEnvelopes: channelMaterial.envelopes,
        localChannelEpochKeys: channelMaterial.keys,
        sovereignBundle: sovereignBundle,
        retentionCuts: retentionCuts,
      );
    } catch (error) {
      // A throw here is indistinguishable from "no such group" to every
      // caller, so it must not be silent: a transient store read is the one
      // failure that looks like a deleted group and heals by itself.
      _loadRefused(groupId, 'threw while decoding: $error');
      return null;
    }
  }

  Future<void> _save(GroupBundle b, {bool notify = true}) async {
    // Chunked file-store (not putSetting): the bundle carries inline media that
    // overflows the single-setting cap. storeFile replaces the prior blob (or
    // no-ops if byte-identical) and chunks large values across commits.
    final json = jsonEncode({
      'm': b.manifest.toJson(),
      'c': b.control.map((e) => e.toJson()).toList(),
      'g': b.messages.map((m) => m.toJson()).toList(),
      if (b.posts.isNotEmpty)
        'p': b.posts.map((post) => post.toJson()).toList(),
      'r': b.reactions.map((x) => x.toJson()).toList(),
      if (b.publicComments.isNotEmpty)
        'pc': b.publicComments.map((comment) => comment.toJson()).toList(),
      if (b.publicReactions.isNotEmpty)
        'pr': b.publicReactions.map((reaction) => reaction.toJson()).toList(),
      if (b.epochEnvelopes.isNotEmpty)
        'ke': b.epochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (b.localEpochKeys.isNotEmpty)
        'kk': {
          for (final entry in b.localEpochKeys.entries)
            '${entry.key}': base64Encode(entry.value),
        },
      if (b.channelEpochEnvelopes.isNotEmpty)
        'cke': b.channelEpochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (b.localChannelEpochKeys.isNotEmpty)
        'ckk': {
          for (final entry in b.localChannelEpochKeys.entries)
            entry.key: base64Encode(entry.value),
        },
      if (b.sovereignBundle != null) 's': base64Encode(b.sovereignBundle!),
      if (b.retentionCuts.isNotEmpty)
        'rcut': [for (final cut in b.retentionCuts.values) cut.toJson()],
    });
    // Published while the two writes below are in flight so a concurrent read
    // waits for the new bytes instead of reading the half-replaced blob as a
    // missing group.
    final key = _key(b.manifest.groupId);
    final write = _writeBundleBytes(key, b, json);
    _bundleWrites[key] = write;
    try {
      await write;
    } finally {
      if (identical(_bundleWrites[key], write)) _bundleWrites.remove(key);
    }
    if (notify) changes.value++;
  }

  Future<void> _writeBundleBytes(
    String key,
    GroupBundle b,
    String json,
  ) async {
    // Hint first: a crash between the two writes may only claim MORE than
    // the stored blob (e.g. a retention row the old blob lacks), which makes
    // maintenance load the bundle — never skip one it must enforce.
    await _writeGroupKindHint(b.manifest.groupId.hex, _computeGroupKindHint(b));
    await _storage.storeFile(
      key,
      Uint8List.fromList(utf8.encode(json)),
      name: 'group',
    );
  }

  Map<String, int>? _decodeContentGcMarks(Uint8List raw) {
    try {
      final value = jsonDecode(utf8.decode(raw, allowMalformed: false));
      if (value is! Map || value['v'] != 1 || value['marks'] is! Map) {
        return null;
      }
      final rows = value['marks'] as Map;
      if (rows.length > 100000) return null;
      final marks = <String, int>{};
      for (final entry in rows.entries) {
        final contentId = entry.key;
        final firstUnreachableAtMs = entry.value;
        if (contentId is! String ||
            !_sharedContentIdPattern.hasMatch(contentId) ||
            firstUnreachableAtMs is! int ||
            firstUnreachableAtMs < 1) {
          return null;
        }
        marks[contentId] = firstUnreachableAtMs;
      }
      return marks;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, int>> _loadContentGcMarks() async {
    final active = await _storage.getSetting('$_contentGcMarksKey.active');
    if (active == 'a' || active == 'b') {
      final raw = await _storage.loadFile('$_contentGcMarksKey.$active');
      final decoded = raw == null ? null : _decodeContentGcMarks(raw);
      if (decoded != null) return decoded;
    }
    // A fallback slot is an older generation and may contain a mark that was
    // deliberately cleared while the content was reachable. Reusing it after
    // pointer loss/corruption could therefore shorten a later quarantine.
    // Restart every grace period instead; corruption can only delay deletion.
    return <String, int>{};
  }

  Future<void> _saveContentGcMarks(Map<String, int> marks) async {
    final active = await _storage.getSetting('$_contentGcMarksKey.active');
    if (active == 'a' || active == 'b') {
      final currentRaw = await _storage.loadFile('$_contentGcMarksKey.$active');
      final current = currentRaw == null
          ? null
          : _decodeContentGcMarks(currentRaw);
      if (current != null &&
          current.length == marks.length &&
          current.entries.every((entry) => marks[entry.key] == entry.value)) {
        return;
      }
    }
    final next = active == 'a' ? 'b' : 'a';
    final sorted = marks.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'v': 1,
          'marks': {for (final entry in sorted) entry.key: entry.value},
        }),
      ),
    );
    await _storage.storeFile(
      '$_contentGcMarksKey.$next',
      bytes,
      name: 'shared-content-gc-quarantine',
    );
    await _storage.putSetting('$_contentGcMarksKey.active', next);
  }

  Future<({Set<String> contentIds, bool complete})> _rawGroupContentReferences(
    GroupBundle bundle,
    GroupState state,
  ) async {
    final contentIds = <String>{};
    for (final message in _acceptedMessagesWithinLifecycle(bundle, state)) {
      final visible = message.isEncrypted
          ? await _materializeEncryptedMessage(bundle, message)
          : message;
      if (visible == null) {
        return (contentIds: contentIds, complete: false);
      }
      final contentId = visible.attachment?.contentId;
      if (contentId != null) contentIds.add(contentId);
    }
    for (final post in _canonicalPostRows(
      bundle.manifest.groupId,
      bundle.posts,
    )) {
      final visible = post.isEncrypted
          ? await _materializeEncryptedPost(bundle, post)
          : post;
      if (visible == null) {
        return (contentIds: contentIds, complete: false);
      }
      for (final media in visible.media) {
        final contentId = media.contentId;
        if (contentId != null) contentIds.add(contentId);
      }
    }
    return (contentIds: contentIds, complete: true);
  }

  Future<bool> _groupProjectionComplete(
    GroupBundle bundle,
    GroupState state,
  ) async {
    for (final message in _acceptedMessagesWithinLifecycle(bundle, state)) {
      if (message.isEncrypted &&
          await _materializeEncryptedMessage(bundle, message) == null) {
        return false;
      }
    }
    for (final post in _canonicalPostRows(
      bundle.manifest.groupId,
      bundle.posts,
    )) {
      if (post.isEncrypted &&
          await _materializeEncryptedPost(bundle, post) == null) {
        return false;
      }
    }
    return true;
  }

  Future<({Set<String> groupIds, bool complete})> _groupIdsForGc() async {
    final groupIds = <String>{};
    try {
      final raw = await _readIndexJson();
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is! List || decoded.length > 100000) {
          return (groupIds: groupIds, complete: false);
        }
        for (final value in decoded) {
          if (value is! String || !_sharedContentIdPattern.hasMatch(value)) {
            return (groupIds: groupIds, complete: false);
          }
          groupIds.add(value);
        }
      }

      // The ordinary UI index is allowed to lag a crash-safe bundle write.
      // Cross-check concrete roots so a lost/stale index cannot hide a Group
      // from destructive reachability. A malformed candidate blocks the pass.
      for (final key in await _storage.settingsKeys()) {
        String? groupId;
        if (key.startsWith('file:group:')) {
          groupId = key.substring('file:group:'.length);
        } else if (key.startsWith('ondisk:group:')) {
          groupId = key.substring('ondisk:group:'.length);
        } else if (key.startsWith('set:group:')) {
          groupId = key.substring('set:group:'.length);
        } else if (key.startsWith('filepiece:group:')) {
          final rest = key.substring('filepiece:group:'.length);
          final cut = rest.lastIndexOf(':');
          if (cut <= 0 || int.tryParse(rest.substring(cut + 1)) == null) {
            return (groupIds: groupIds, complete: false);
          }
          groupId = rest.substring(0, cut);
        }
        if (groupId == null) continue;
        if (!_sharedContentIdPattern.hasMatch(groupId)) {
          devLog(() => 'xVeil[content-gc]: group index holds a malformed id');
          return (groupIds: groupIds, complete: false);
        }
        groupIds.add(groupId);
      }
      return (groupIds: groupIds, complete: true);
    } catch (_) {
      devLog(() => 'xVeil[content-gc]: group index could not be read');
      return (groupIds: groupIds, complete: false);
    }
  }

  Future<({Set<String> contentIds, bool complete})>
  _groupContentReferencesForGc() async {
    final contentIds = <String>{};
    final index = await _groupIdsForGc();
    if (!index.complete) {
      devLog(() => 'xVeil[content-gc]: group index incomplete (see the line above)');
      return (contentIds: contentIds, complete: false);
    }
    for (final hex in index.groupIds) {
      NodeId groupId;
      try {
        groupId = NodeId.fromHex(hex);
      } catch (_) {
        devLog(() => 'xVeil[content-gc]: indexed id is not a node id');
        return (contentIds: contentIds, complete: false);
      }
      final result = await _serialized(groupId, () async {
        final bundle = await load(groupId);
        if (bundle == null) {
          final wasPurged = await deletedSpaceTombstone(groupId) != null;
          if (!wasPurged) {
            // Fail-closed is right — collecting while blind to one group's
            // references would delete live content. But it is permanent if
            // the index keeps an id whose bundle is gone: measured on the
            // stand as `stored=104 referenced=42 purged=0` for hours, with
            // two such ids logging a load refusal every few seconds. Say
            // which group holds the sweep, or the symptom is only "storage
            // never shrinks".
            devLog(
              () =>
                  'xVeil[content-gc]: blocked by ${groupId.short} — '
                  'indexed, no bundle, no deletion tombstone',
            );
          }
          return (contentIds: <String>{}, complete: wasPurged);
        }
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        if (state.isDeleted) {
          // Recovery can restore the exact bundle until purge. Keep every
          // decryptable historical reference, not only the currently hidden
          // projection, for the whole recovery window.
          return _rawGroupContentReferences(bundle, state);
        }
        final refs = await referencedContentIds(
          groupId,
          applyLocalRetention: true,
        );
        return (
          contentIds: refs,
          complete: await _groupProjectionComplete(bundle, state),
        );
      });
      contentIds.addAll(result.contentIds);
      if (!result.complete) {
        devLog(() => 'xVeil[content-gc]: a group projection is not fully readable');
        return (contentIds: contentIds, complete: false);
      }
    }
    final publicIndex = await _loadPublicSubscriptionIndex();
    if (!publicIndex.complete) {
      devLog(() => 'xVeil[content-gc]: public-subscription index could not be read');
      return (contentIds: contentIds, complete: false);
    }
    for (final hex in publicIndex.ids) {
      final NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        devLog(() => 'xVeil[content-gc]: public-subscription index holds a malformed id');
        return (contentIds: contentIds, complete: false);
      }
      final snapshot = await _loadPublicSubscriptionSnapshot(spaceId);
      if (snapshot == null) {
        // A referenced root that cannot be authenticated is uncertainty. Do
        // not use a malformed index/snapshot pair as deletion authority.
        devLog(() => 'xVeil[content-gc]: a public-subscription snapshot did not authenticate');
        return (contentIds: contentIds, complete: false);
      }
      contentIds.addAll(
        snapshot.package.projection.verifiedReferencedContentIds(
          _signer.verifyDetached,
        ),
      );
    }
    return (contentIds: contentIds, complete: true);
  }

  /// Mark/sweep the one shared hash-CID namespace. Every destructive domain
  /// defers to this pass, which unions chat, cloud and validated group/Space
  /// roots, waits through [gracePeriod], re-scans before deletion, then removes
  /// payload and `mf:<cid>` together. Any unreadable root aborts fail-closed.
  Future<SharedContentGcSweep> sweepSharedContentGarbage({
    int? nowMs,
    Duration gracePeriod = kSharedContentGcGracePeriod,
    int limit = 16,
  }) async {
    if (limit <= 0 || limit > 256) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..256');
    }
    if (gracePeriod.isNegative) {
      throw ArgumentError.value(
        gracePeriod,
        'gracePeriod',
        'must not be negative',
      );
    }
    final now = nowMs ?? _now();
    final storage = await _storage.sharedContentReferenceSnapshot();
    final groups = storage.complete
        ? await _groupContentReferencesForGc()
        : (contentIds: <String>{}, complete: false);
    if (!storage.complete || !groups.complete) {
      return SharedContentGcSweep(
        stored: storage.storedContentIds.length,
        referenced:
            storage.referencedContentIds.length + groups.contentIds.length,
        unreachable: 0,
        marked: 0,
        purged: 0,
        failed: 1,
        complete: false,
      );
    }

    final referenced = <String>{
      ...storage.referencedContentIds,
      ...groups.contentIds,
    };
    final unreachable = storage.storedContentIds.difference(referenced);
    final marks = await _loadContentGcMarks();
    marks.removeWhere(
      (contentId, _) =>
          referenced.contains(contentId) ||
          !storage.storedContentIds.contains(contentId),
    );
    var marked = 0;
    for (final contentId in unreachable) {
      if (!marks.containsKey(contentId)) {
        marks[contentId] = now;
        marked++;
      }
    }
    try {
      // Commit quarantine before any destructive operation. A crash can only
      // leave an older mark (longer retention), never bypass the grace period.
      await _saveContentGcMarks(marks);
    } catch (_) {
      return SharedContentGcSweep(
        stored: storage.storedContentIds.length,
        referenced: referenced.length,
        unreachable: unreachable.length,
        marked: marked,
        purged: 0,
        failed: 1,
        complete: false,
      );
    }

    final eligible =
        [
          for (final entry in marks.entries)
            if (now - entry.value >= gracePeriod.inMilliseconds) entry,
        ]..sort((left, right) {
          final time = left.value.compareTo(right.value);
          return time != 0 ? time : left.key.compareTo(right.key);
        });
    if (eligible.isEmpty) {
      return SharedContentGcSweep(
        stored: storage.storedContentIds.length,
        referenced: referenced.length,
        unreachable: unreachable.length,
        marked: marked,
        purged: 0,
        failed: 0,
        complete: true,
      );
    }

    // A second independent snapshot closes long sweep windows and catches a
    // reference added after quarantine. New storage still observes the full
    // grace period even if it was created from a formerly orphaned CID.
    final recheckStorage = await _storage.sharedContentReferenceSnapshot();
    final recheckGroups = recheckStorage.complete
        ? await _groupContentReferencesForGc()
        : (contentIds: <String>{}, complete: false);
    if (!recheckStorage.complete || !recheckGroups.complete) {
      return SharedContentGcSweep(
        stored: storage.storedContentIds.length,
        referenced: referenced.length,
        unreachable: unreachable.length,
        marked: marked,
        purged: 0,
        failed: 1,
        complete: false,
      );
    }
    final recheckedReferences = <String>{
      ...recheckStorage.referencedContentIds,
      ...recheckGroups.contentIds,
    };
    var purged = 0;
    var failed = 0;
    for (final entry in eligible.take(limit)) {
      final contentId = entry.key;
      if (recheckedReferences.contains(contentId) ||
          !recheckStorage.storedContentIds.contains(contentId)) {
        marks.remove(contentId);
        continue;
      }
      try {
        await _storage.deleteStoredFile(contentId);
        await _storage.deleteStoredFile('mf:$contentId');
        marks.remove(contentId);
        purged++;
      } catch (_) {
        failed++;
      }
    }
    if (purged > 0) await _storage.scrubDeleted();
    try {
      await _saveContentGcMarks(marks);
    } catch (_) {
      failed++;
    }
    return SharedContentGcSweep(
      stored: storage.storedContentIds.length,
      referenced: referenced.length,
      unreachable: unreachable.length,
      marked: marked,
      purged: purged,
      failed: failed,
      complete: failed == 0,
    );
  }

  /// Start the idempotent lifecycle maintenance loop. GUI and headless hosts
  /// call this once after constructing the service; tests can invoke
  /// [purgeDeletedSpaces] directly with a deterministic clock.
  void startSpaceLifecycleMaintenance() {
    if (_spaceDeletionMaintenanceTimer != null) return;
    unawaited(_runSpaceDeletionMaintenance());
    _spaceDeletionMaintenanceTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(_runSpaceDeletionMaintenance()),
    );
  }

  Future<void> _runSpaceDeletionMaintenance() async {
    if (_spaceDeletionMaintenanceRunning) return;
    _spaceDeletionMaintenanceRunning = true;
    try {
      await purgeDeletedSpaces();
      // Retention rows first: freed media references become unreachable and
      // the shared-content GC below can then mark/collect the blobs.
      final retention = await sweepSpaceRetention();
      if (retention.scanned > 0 || retention.deleted > 0) {
        devLog(
          () =>
              'xVeil[retention]: scanned=${retention.scanned} '
              'messages=${retention.messagesDeleted} '
              'posts=${retention.postsDeleted} '
              'reactions=${retention.reactionsDeleted} '
              'cuts=${retention.cutsRecorded} failed=${retention.failed}',
        );
      }
      final gc = await sweepSharedContentGarbage();
      devLog(
        () =>
            'xVeil[content-gc]: stored=${gc.stored} '
            'referenced=${gc.referenced} unreachable=${gc.unreachable} '
            'marked=${gc.marked} purged=${gc.purged} failed=${gc.failed} '
            'complete=${gc.complete}',
      );
      final rotated = await sweepStaleChannelKeys();
      if (rotated > 0) {
        devLog(() => 'xVeil[channel-keys]: rotated=$rotated');
      }
      final collapsed = await sweepStateLogCompaction();
      if (collapsed > 0) {
        devLog(() => 'xVeil[compaction]: rows collapsed=$collapsed');
      }
    } finally {
      _spaceDeletionMaintenanceRunning = false;
    }
  }

  /// Physically delete retention-expired rows once their expiry is older than
  /// the policy's physical-deletion grace.
  ///
  /// Message rows form strict per-(scope, author) hash chains, so only a
  /// fully expired chain PREFIX is removed and a local [SpaceRetentionCut]
  /// re-anchors the fold at the first retained row; fork evidence is never
  /// deleted. Posts and reactions are not hash-chained and are removed
  /// row-wise (a publication is removed only when its whole revision group is
  /// expired and unpinned). Freed media references are collected by the
  /// shared-content GC that runs after this sweep. The fail-closed
  /// hidden-through boundary of an unreadable encrypted policy never deletes
  /// anything. Bounded, idempotent, serialized per Space.
  /// Run [rotateStaleChannelKeys] across every Space this device holds.
  ///
  /// Lives in the hourly maintenance pass because that is what it is: a key
  /// that has served long enough is not an incident, and rotating it an hour
  /// late costs nothing. Doing it here also means the rotation is never
  /// attached to someone opening a screen, which would make the timing of a
  /// key change say something about who was looking.
  /// [limit] bounds how many Spaces one pass folds, the same budget the
  /// retention sweep takes and for the same reason: this runs hourly on a
  /// phone, and a device in many Spaces must not spend the hour on it. What
  /// the budget skips is simply examined next hour.
  Future<int> sweepStaleChannelKeys({int limit = 16}) async {
    if (limit <= 0 || limit > 256) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..256');
    }
    var rotated = 0;
    var budget = limit;
    for (final hex in await _index()) {
      if (budget == 0) break;
      NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        continue;
      }
      // 'g' marks a group rather than a Space, and only a Space has protected
      // channels — skip the load exactly as the retention sweep does.
      if (await _readGroupKindHint(hex) == 'g') continue;
      budget--;
      try {
        rotated += await rotateStaleChannelKeys(spaceId);
      } catch (_) {
        // One unreadable Space must not stop the rest of the sweep.
      }
    }
    return rotated;
  }

  /// Where the last compaction pass stopped, so consecutive hours cover
  /// different groups instead of re-folding the same first few.
  int _compactionCursor = 0;

  /// Compact superseded state rows across the groups this device holds.
  ///
  /// Compaction has always existed but ran only at boot (via
  /// [nudgeGroupSyncAll]). Replication ships a group's bundle WHOLE, so what
  /// the log accumulates between restarts is paid again on every sync:
  /// measured on the stand, a device-sync log at **2748 rows and 173 inline
  /// images** for a cloud of nine items, which one compaction pass collapsed
  /// to 233 and 11. A long-running app therefore got slower to sync the
  /// longer it ran, and a restart "fixed" it — which is how this was found.
  ///
  /// [limit] bounds one pass for the same reason the other sweeps are
  /// bounded: this runs hourly on a phone. The cursor makes the budget
  /// rotate, so a device in many groups still compacts all of them, just
  /// across several hours.
  Future<int> sweepStateLogCompaction({int limit = 8}) async {
    if (limit <= 0 || limit > 256) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..256');
    }
    final ids = await _index();
    if (ids.isEmpty) return 0;
    var collapsed = 0;
    final take = limit < ids.length ? limit : ids.length;
    // The device-sync group grows fastest — every cloud edit appends to it —
    // so it is compacted on EVERY pass rather than waiting for the cursor to
    // come round. Measured live: with a plain rotating budget it sat outside
    // the first window and one pass collapsed nothing while a manual run of
    // the same code collapsed 21 rows.
    // NOT gated on the index: the device group is not listed there (nothing
    // enumerating `_index()` has ever reached it, which is why its log had
    // grown to 2748 rows), so a membership check here would skip the one
    // group this pass exists for.
    final deviceHex = await deviceGroupIdHex();
    final order = <String>[
      ?deviceHex,
      for (var i = 0; i < take; i++)
        if (ids[(_compactionCursor + i) % ids.length] != deviceHex)
          ids[(_compactionCursor + i) % ids.length],
    ];
    for (final hex in order) {
      try {
        final result = await compactStateLogs(NodeId.fromHex(hex));
        if (result == null || !result.changed) continue;
        collapsed +=
            (result.messagesBefore - result.messagesAfter) +
            (result.postsBefore - result.postsAfter) +
            (result.controlBefore - result.controlAfter) +
            (result.reactionsBefore - result.reactionsAfter);
      } catch (_) {
        // One unreadable group must not stop the rest of the pass.
      }
    }
    _compactionCursor = (_compactionCursor + take) % ids.length;
    return collapsed;
  }

  Future<SpaceRetentionSweep> sweepSpaceRetention({
    int? nowMs,
    int limit = 16,
  }) async {
    if (limit <= 0 || limit > 256) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..256');
    }
    final now = nowMs ?? _now();
    var scanned = 0;
    var messagesDeleted = 0;
    var postsDeleted = 0;
    var reactionsDeleted = 0;
    var cutsRecorded = 0;
    var failed = 0;
    var budget = limit;
    for (final hex in await _index()) {
      if (budget == 0) break;
      NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        continue;
      }
      // Kind hint: 'g' (not a Space) and 's' (Space with zero setRetention
      // rows — materialized revisions can only come from such rows) cannot
      // have anything to enforce; skip the expensive load. Missing hint →
      // load as before and backfill so the next hourly pass skips.
      final hint = await _readGroupKindHint(hex);
      if (hint == 'g' || hint == 's') continue;
      try {
        await _serialized(spaceId, () async {
          final b = await load(spaceId);
          if (b == null) return;
          if (hint == null) {
            await _writeGroupKindHint(hex, _computeGroupKindHint(b));
          }
          if (!b.manifest.isSpace) return;
          final state = foldControlLog(
            owner: b.manifest.owner,
            entries: b.control,
            verify: (entry) => _validControlFor(b.manifest, entry),
            initialName: b.manifest.name,
            initialDescription: b.manifest.description ?? '',
          ).state;
          final retention = await _materializedRetentionHistory(b, state);
          final hasBoundedPolicy = retention.revisions.any(
            (revision) =>
                revision.policy.mode == SpaceRetentionMode.deleteAfter,
          );
          if (!hasBoundedPolicy) return;
          scanned++;
          budget--;

          bool graceExpiredMessage(GroupMessage m) {
            final channelId = m.spacePostId != null
                ? null
                : (m.channelId ?? defaultSpaceChannelId(b.manifest.groupId));
            final grace = _effectiveRetentionPolicy(
              retention.revisions,
              channelId,
            ).physicalDeletionGraceMs;
            return _retentionRetiresMessage(
              manifest: b.manifest,
              revisions: retention.revisions,
              hiddenThroughMs: const {},
              message: m,
              atMs: now - grace,
            );
          }

          // Messages: expired createdAt is monotone along a chain, so the
          // deletable region is always a prefix; stop at the first live row
          // or at recorded fork evidence.
          final byChain = <String, List<GroupMessage>>{};
          final untouched = <GroupMessage>[];
          for (final m in b.messages) {
            if (!_validMessageFor(b.manifest.groupId, m)) {
              untouched.add(m);
              continue;
            }
            final scope = _messageChainScope(b.manifest, m);
            byChain
                .putIfAbsent(retentionCutKey(scope, m.author), () => [])
                .add(m);
          }
          final forks = _messageForks(
            b.manifest,
            _retainedMessageRows(b.manifest, b.messages),
          );
          final deletedHashes = <String>{};
          final newCuts = <String, SpaceRetentionCut>{...b.retentionCuts};
          for (final entry in byChain.entries) {
            final rows = entry.value
              ..sort((left, right) => left.seq.compareTo(right.seq));
            final scope = _messageChainScope(b.manifest, rows.first);
            final fork = forks[entry.key];
            final priorCutSeq = b.retentionCuts[entry.key]?.throughSeq ?? -1;
            GroupMessage? lastDeleted;
            for (final m in rows) {
              if (m.seq <= priorCutSeq) {
                // Straggler below an accepted cut: already retired.
                deletedHashes.add(groupMessageHash(m));
                continue;
              }
              if (fork != null && m.seq >= fork.seq) break;
              if (!graceExpiredMessage(m)) break;
              deletedHashes.add(groupMessageHash(m));
              lastDeleted = m;
            }
            if (lastDeleted == null) continue;
            final prior = newCuts[entry.key];
            if (prior == null || lastDeleted.seq > prior.throughSeq) {
              newCuts[entry.key] = SpaceRetentionCut(
                scope: scope,
                author: rows.first.author,
                throughSeq: lastDeleted.seq,
                throughHash: groupMessageHash(lastDeleted),
                throughCreatedAtMs: lastDeleted.createdAtMs,
              );
              cutsRecorded++;
            }
          }
          final keptMessages = <GroupMessage>[
            ...untouched,
            for (final rows in byChain.values)
              for (final m in rows)
                if (!deletedHashes.contains(groupMessageHash(m))) m,
          ];

          // Publications: not hash-chained, but edit/delete revisions sign
          // the root, so a postId group is removed only atomically and only
          // when every revision is expired and unpinned.
          final spaceGrace = _effectiveRetentionPolicy(
            retention.revisions,
          ).physicalDeletionGraceMs;
          final byPostId = <String, List<SpacePost>>{};
          final keptPosts = <SpacePost>[];
          for (final post in b.posts) {
            if (!_validPostFor(b.manifest.groupId, post)) {
              keptPosts.add(post);
              continue;
            }
            byPostId.putIfAbsent(post.postId, () => []).add(post);
          }
          var deletedPostRows = 0;
          for (final group in byPostId.values) {
            final allExpired = group.every(
              (post) => _retentionRetiresPost(
                manifest: b.manifest,
                state: state,
                revisions: retention.revisions,
                post: post,
                atMs: now - spaceGrace,
              ),
            );
            if (allExpired) {
              deletedPostRows += group.length;
            } else {
              keptPosts.addAll(group);
            }
          }

          final keptReactions = <GroupReaction>[];
          var deletedReactionRows = 0;
          for (final r in b.reactions) {
            final grace = _effectiveRetentionPolicy(
              retention.revisions,
              r.channelId,
            ).physicalDeletionGraceMs;
            if (_validReactionFor(b.manifest.groupId, r) &&
                _retentionRetiresReaction(
                  manifest: b.manifest,
                  revisions: retention.revisions,
                  hiddenThroughMs: const {},
                  reaction: r,
                  atMs: now - grace,
                )) {
              deletedReactionRows++;
              continue;
            }
            keptReactions.add(r);
          }

          if (deletedHashes.isEmpty &&
              deletedPostRows == 0 &&
              deletedReactionRows == 0) {
            return;
          }
          messagesDeleted += deletedHashes.length;
          postsDeleted += deletedPostRows;
          reactionsDeleted += deletedReactionRows;
          await _save(
            b.copyWith(
              messages: keptMessages,
              posts: keptPosts,
              reactions: keptReactions,
              retentionCuts: newCuts,
            ),
            notify: false,
          );
        });
      } catch (_) {
        failed++;
      }
    }
    if (messagesDeleted + postsDeleted + reactionsDeleted > 0) {
      try {
        await _storage.scrubDeleted();
      } catch (_) {
        failed++;
      }
    }
    return SpaceRetentionSweep(
      scanned: scanned,
      messagesDeleted: messagesDeleted,
      postsDeleted: postsDeleted,
      reactionsDeleted: reactionsDeleted,
      cutsRecorded: cutsRecorded,
      failed: failed,
      complete: failed == 0,
    );
  }

  /// Physically purge expired recoverable Space bundles in bounded batches.
  /// A compact anti-resurrection tombstone is committed first, then the heavy
  /// encrypted blob is deleted and scrubbed. Re-running after any partial
  /// failure is safe and converges to the same result.
  Future<SpaceDeletionSweep> purgeDeletedSpaces({
    int? nowMs,
    int limit = 16,
  }) async {
    if (limit <= 0 || limit > 256) {
      throw ArgumentError.value(limit, 'limit', 'must be 1..256');
    }
    final now = nowMs ?? _now();
    final ids = await _index();
    final removedIds = <String>{};
    var scanned = 0;
    var purged = 0;
    var pending = 0;
    var failed = 0;
    var budget = limit;
    for (final hex in ids) {
      if (budget == 0) {
        continue;
      }
      NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        continue;
      }
      // A hinted legacy group can never be a deleted Space; skip its load.
      // (Index cleanup for missing bundles only ever applies to Space
      // tombstones, which clear their hint on purge, so 'g' stays accurate.)
      final hint = await _readGroupKindHint(hex);
      if (hint == 'g') continue;
      final bundle = await load(spaceId);
      if (bundle == null) {
        if (await deletedSpaceTombstone(spaceId) != null) removedIds.add(hex);
        continue;
      }
      if (hint == null) {
        await _writeGroupKindHint(hex, _computeGroupKindHint(bundle));
      }
      if (!bundle.manifest.isSpace) {
        continue;
      }
      scanned++;
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      final transition = state.lifecycleTransition;
      final deadline = transition?.recoveryDeadlineMs;
      if (!state.isDeleted || deadline == null || now < deadline) {
        if (state.isDeleted) pending++;
        continue;
      }
      budget--;
      try {
        final didPurge = await _serialized(spaceId, () async {
          final current = await load(spaceId);
          if (current == null || !current.manifest.isSpace) return false;
          final currentState = foldControlLog(
            owner: current.manifest.owner,
            entries: current.control,
            verify: (entry) => _validControlFor(current.manifest, entry),
            initialName: current.manifest.name,
            initialDescription: current.manifest.description ?? '',
          ).state;
          final currentDeadline =
              currentState.lifecycleTransition?.recoveryDeadlineMs;
          final transitionHash = currentState.lifecycleTransitionHash;
          if (!currentState.isDeleted ||
              currentDeadline == null ||
              now < currentDeadline) {
            return false;
          }
          if (transitionHash == null) throw StateError('missing delete hash');
          await _saveDeletedSpaceTombstone(
            SpaceDeletionTombstone(
              spaceId: spaceId,
              deleteTransitionHash: transitionHash,
              recoveryDeadlineMs: currentDeadline,
              purgedAtMs: now,
            ),
          );
          await _storage.deleteStoredFile(_key(spaceId));
          await _clearGroupKindHint(spaceId.hex);
          return true;
        });
        if (didPurge) {
          purged++;
          removedIds.add(hex);
          devLog(
            () =>
                'xVeil[spaces]: purged deleted Space ${spaceId.short} '
                'after recovery deadline',
          );
        } else {
          pending++;
        }
      } catch (_) {
        failed++;
      }
    }
    if (removedIds.isNotEmpty) {
      final latest = await _index();
      await _setIndex([
        for (final id in latest)
          if (!removedIds.contains(id)) id,
      ]);
    }
    if (purged > 0) {
      await _storage.scrubDeleted();
      changes.value++;
    }
    _observeSpace(
      SpaceObservationType.contentCleanup,
      failed > 0
          ? SpaceObservationOutcome.failed
          : purged > 0
          ? SpaceObservationOutcome.succeeded
          : SpaceObservationOutcome.noOp,
      reason: failed > 0 ? SpaceObservationReason.storageFailed : null,
      amount: purged,
    );
    return SpaceDeletionSweep(
      scanned: scanned,
      purged: purged,
      pending: pending,
      failed: failed,
    );
  }

  /// The group chats we are STILL A MEMBER of. Spaces are
  /// deliberately excluded: they have their own list and navigation surface.
  /// (or were never/no-longer a member of, per the folded control-log) is hidden
  /// without deleting its blob — the stored data lingers deniably and a fresh
  /// re-add simply folds us back in. (An admin-removal we never received doesn't
  /// hide the group on our side: we don't learn we were removed — no oracle.)
  Future<List<GroupListEntry>> listGroups() => _listUserGroups(spaces: false);

  /// The Spaces this identity currently belongs to. Group chats are excluded.
  Future<List<GroupListEntry>> listSpaces() => _listUserGroups(spaces: true);

  Future<List<GroupListEntry>> _listUserGroups({required bool spaces}) async {
    final out =
        <
          ({
            NodeId groupId,
            String name,
            String description,
            SpaceVisibility? visibility,
            SpaceLifecycleState lifecycleState,
            bool discoverable,
            int unread,
            int postUnread,
            bool muted,
            NotificationMuteMode notificationMode,
            DateTime? notificationUntil,
            String preview,
            int lastTs,
          })
        >[];
    for (final hex in await _index()) {
      try {
        final b = await load(NodeId.fromHex(hex));
        if (b == null) continue;
        if (b.manifest.isSpace != spaces) continue;
        final state = foldControlLog(
          owner: b.manifest.owner,
          entries: b.control,
          verify: (e) => _validControlFor(b.manifest, e),
          initialName: b.manifest.name,
          initialDescription: b.manifest.description ?? '',
        ).state;
        if (!state.isMember(_signer.selfId)) continue;
        // Device groups are infrastructure, not chats — never listed.
        if (b.manifest.name == kDeviceGroupName) continue;
        final gid = b.manifest.groupId;
        // One validated pass powers unread AND the last-message preview.
        final wm =
            int.tryParse(await _storage.getSetting('group.seen:$hex') ?? '') ??
            0;
        final msgs = await messagesOf(gid);
        final last = msgs.isEmpty ? null : msgs.last;
        final spacePosts = spaces
            ? await postsOf(gid)
            : const <SpacePostView>[];
        final lastPost = spacePosts.isEmpty ? null : spacePosts.last;
        final postIsLatest =
            lastPost != null &&
            (last == null || lastPost.publishedAtMs >= last.createdAtMs);
        final notificationPolicy = await groupNotificationPolicy(gid);
        final notificationMode = notificationPolicy.effectiveAt(DateTime.now());
        out.add((
          groupId: gid,
          name: state.name,
          description: state.description,
          visibility: b.manifest.visibility,
          lifecycleState: state.lifecycleState,
          discoverable: b.manifest.discoverable ?? false,
          unread: msgs
              .where((m) => m.createdAtMs > wm && m.author != _signer.selfId)
              .length,
          postUnread: await unreadSpacePosts(gid),
          muted: notificationMode != NotificationMuteMode.all,
          notificationMode: notificationMode,
          notificationUntil: notificationMode == NotificationMuteMode.all
              ? null
              : notificationPolicy.until,
          preview: postIsLatest
              ? (lastPost.title.trim().isNotEmpty
                    ? lastPost.title
                    : lastPost.body)
              : last == null
              ? ''
              : previewOf(last),
          // A brand-new chat has no message timestamp yet, but it must still
          // participate in the shared Chats recency ordering. Using zero sent
          // it below every established direct/group conversation, which made
          // successful creation look as if the chat had disappeared.
          lastTs: postIsLatest
              ? lastPost.publishedAtMs
              : last?.createdAtMs ?? b.manifest.createdAtMs,
        ));
      } catch (_) {}
    }
    return out;
  }

  /// Create a signed Space named [name] with us as the sole owner.
  Future<NodeId> createSpace(
    String name, {
    String description = '',
    String? avatarContentId,
    String? coverContentId,
    SpaceVisibility visibility = SpaceVisibility.private,
    bool discoverable = false,
  }) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 160) {
      throw ArgumentError.value(name, 'name', 'must contain 1..160 characters');
    }
    if (description.length > 4096) {
      throw ArgumentError.value(
        description,
        'description',
        'must not exceed 4096 characters',
      );
    }
    if ((avatarContentId?.length ?? 0) > 512 ||
        (coverContentId?.length ?? 0) > 512) {
      throw ArgumentError('Space content id must not exceed 512 characters');
    }
    final gid = _randomGroupId();
    final createdAtMs = _now();
    final unsignedManifest = SpaceManifest.space(
      spaceId: gid,
      owner: _signer.selfId,
      genesisPubKey: _signer.selfPubKey,
      name: normalizedName,
      description: description,
      avatarContentId: avatarContentId,
      coverContentId: coverContentId,
      visibility: visibility,
      discoverable: discoverable,
      createdAtMs: createdAtMs,
    );
    final manifest = _signer.signSpaceManifest(unsignedManifest);
    if (!_validManifest(manifest)) {
      throw StateError('space genesis signature rejected');
    }
    final defaultChannel = SpaceChannel(
      spaceId: gid,
      channelId: defaultSpaceChannelId(gid),
      kind: SpaceChannelKind.text,
      name: 'general',
      description: '',
      position: 0,
      isDefault: true,
      archived: false,
      history: SpaceChannelHistory.fromJoin,
      createdBy: _signer.selfId,
      createdAtMs: createdAtMs,
    );
    final channelControl = _signer.signControl(
      ControlEntry(
        version: 2,
        groupId: gid,
        author: _signer.selfId,
        seq: 0,
        prevHash: '',
        op: ControlOp.createChannel,
        target: null,
        role: null,
        policyVersion: 0,
        createdAtMs: createdAtMs,
        signature: Uint8List(0),
        channel: defaultChannel,
      ),
    );
    final initialFold = foldControlLog(
      owner: manifest.owner,
      entries: [channelControl],
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    if (initialFold.rejected.isNotEmpty ||
        initialFold.state.channels.length != 1) {
      throw StateError('default Space channel rejected');
    }
    var bundle = GroupBundle(
      manifest: manifest,
      control: [channelControl],
      messages: [],
    );
    final epochService = _epochService;
    if (epochService != null) {
      final key = _randomEpochKey();
      try {
        final sealed = await epochService.sealEpoch(
          groupId: gid,
          epoch: 1,
          epochKey: key,
          recipients: [_signer.selfId],
        );
        final signed = _signer.signControl(
          ControlEntry(
            version: 2,
            groupId: gid,
            author: _signer.selfId,
            seq: 1,
            prevHash: controlEntryHash(channelControl),
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: 0,
            createdAtMs: _now(),
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        final folded = foldControlLog(
          owner: manifest.owner,
          entries: [channelControl, signed],
          verify: (entry) => _validControlFor(manifest, entry),
          initialName: manifest.name,
        );
        if (folded.rejected.isNotEmpty ||
            folded.state.epochDescriptor == null) {
          throw StateError('initial group epoch rejected');
        }
        bundle = GroupBundle(
          manifest: manifest,
          control: [channelControl, signed],
          messages: const [],
          epochEnvelopes: sealed.envelopes,
          localEpochKeys: {1: Uint8List.fromList(key)},
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    }
    // Creation is visible only after both the bundle and its index entry are
    // durable. Emitting from _save here races listGroups against the old index.
    await _save(bundle, notify: false);
    final idx = await _index();
    idx.add(gid.hex);
    await _setIndex(idx);
    // The durable bundle/index commit is the moment list consumers may expose
    // the new Space. Without this tick an already-mounted Communities screen
    // kept its old StreamProvider value until some unrelated group mutation.
    changes.value++;
    _observeSpace(
      SpaceObservationType.spaceCreated,
      SpaceObservationOutcome.succeeded,
    );
    return gid;
  }

  /// Create a group chat named [name] with us as the sole owner. Group chats
  /// keep the established group-wide message log and do not acquire Space
  /// channels, publications, visibility or subscriptions.
  Future<NodeId> createGroup(String name) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty || normalizedName.length > 64) {
      throw ArgumentError.value(name, 'name', 'must contain 1..64 characters');
    }
    final gid = _randomGroupId();
    final manifest = SpaceManifest(
      groupId: gid,
      owner: _signer.selfId,
      genesisPubKey: _signer.selfPubKey,
      name: normalizedName,
      createdAtMs: _now(),
    );
    var bundle = GroupBundle(manifest: manifest, control: [], messages: []);
    final epochService = _epochService;
    if (epochService != null) {
      final key = _randomEpochKey();
      try {
        final sealed = await epochService.sealEpoch(
          groupId: gid,
          epoch: 1,
          epochKey: key,
          recipients: [_signer.selfId],
        );
        final signed = _signer.signControl(
          ControlEntry(
            groupId: gid,
            author: _signer.selfId,
            seq: 0,
            prevHash: '',
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: 0,
            createdAtMs: _now(),
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        final folded = foldControlLog(
          owner: manifest.owner,
          entries: [signed],
          verify: (entry) => _validControlFor(manifest, entry),
          initialName: manifest.name,
        );
        if (folded.rejected.isNotEmpty ||
            folded.state.epochDescriptor == null) {
          throw StateError('initial group epoch rejected');
        }
        bundle = GroupBundle(
          manifest: manifest,
          control: [signed],
          messages: const [],
          epochEnvelopes: sealed.envelopes,
          localEpochKeys: {1: Uint8List.fromList(key)},
        );
      } finally {
        key.fillRange(0, key.length, 0);
      }
    }
    // Creation is visible only after both the bundle and its index entry are
    // durable. Emitting from _save here races listGroups against the old index.
    await _save(bundle, notify: false);
    final idx = await _index();
    idx.add(gid.hex);
    await _setIndex(idx);
    // Creation is a list mutation too. Group chat screens are opened directly
    // after this call, so the missing tick stayed invisible until Back: the
    // Chats tab then kept the pre-create provider snapshot indefinitely.
    changes.value++;
    return gid;
  }

  /// Explicitly convert every eligible legacy group owned by this identity to
  /// a signed Space without changing ids, logs, messages, media references or
  /// epoch keys. This is intentionally NOT called at boot: group chats are
  /// first-class and conversion requires a separate user-confirmed workflow.
  /// A non-owner cannot manufacture genesis authority, so their copy remains
  /// readable until an owner-signed manifest arrives through normal sync.
  /// Explicit owner-initiated conversion of ONE legacy group chat into a
  /// Space. This is never run automatically (the canon keeps group chats as
  /// chats); the user picks a specific chat and confirms. Idempotent: a group
  /// already converted returns true, a non-owned/invalid one returns false.
  Future<bool> convertGroupToSpace(NodeId groupId) async {
    final outcome = await _serialized(
      groupId,
      () => _convertLegacyGroupLocked(groupId),
    );
    if (outcome == 'upgraded') changes.value++;
    return outcome == 'upgraded' || outcome == 'current';
  }

  /// Convert one legacy group to a Space under an already-held per-group lock.
  /// Returns 'upgraded' / 'current' (already a Space or device/sovereign) /
  /// 'not-owner' / 'failed'.
  Future<String> _convertLegacyGroupLocked(NodeId groupId) async {
    final bundle = await load(groupId);
    if (bundle == null) return 'failed';
    final legacy = bundle.manifest;
    if (legacy.isSpace ||
        legacy.isSovereignDevice ||
        legacy.name == kDeviceGroupName) {
      return 'current';
    }
    if (!legacy.isLegacyGroup) return 'failed';
    if (legacy.owner != _signer.selfId) return 'not-owner';
    final unsigned = SpaceManifest.space(
      spaceId: legacy.groupId,
      owner: legacy.owner,
      genesisPubKey: legacy.genesisPubKey,
      name: legacy.name,
      createdAtMs: legacy.createdAtMs,
    );
    final signed = _signer.signSpaceManifest(unsigned);
    if (!legacy.sameImmutableRoot(signed) || !_validManifest(signed)) {
      return 'failed';
    }
    final state = foldControlLog(
      owner: legacy.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(legacy, entry),
      initialName: legacy.name,
    ).state;
    final channelCreatedAt = _now();
    final defaultChannel = SpaceChannel(
      spaceId: legacy.groupId,
      channelId: defaultSpaceChannelId(legacy.groupId),
      kind: SpaceChannelKind.text,
      name: 'general',
      description: '',
      position: 0,
      isDefault: true,
      archived: false,
      history: SpaceChannelHistory.fromJoin,
      createdBy: _signer.selfId,
      createdAtMs: channelCreatedAt,
    );
    final link = _nextControlLink(legacy, bundle.control, _signer.selfId);
    if (link.blocked) return 'failed';
    final createChannel = _signer.signControl(
      ControlEntry(
        version: 2,
        groupId: legacy.groupId,
        author: _signer.selfId,
        seq: link.seq,
        prevHash: link.prevHash,
        op: ControlOp.createChannel,
        target: null,
        role: null,
        policyVersion: state.policyVersion,
        createdAtMs: channelCreatedAt,
        signature: Uint8List(0),
        channel: defaultChannel,
      ),
    );
    final candidate = [...bundle.control, createChannel];
    final folded = foldControlLog(
      owner: signed.owner,
      entries: candidate,
      verify: (entry) => _validControlFor(signed, entry),
      initialName: signed.name,
    );
    if (folded.rejected.any(
      (entry) =>
          entry.author == createChannel.author &&
          entry.seq == createChannel.seq,
    )) {
      return 'failed';
    }
    await _save(bundle.copyWith(manifest: signed, control: candidate));
    return 'upgraded';
  }

  Future<SpaceManifestMigration> migrateOwnedLegacyGroupsToSpaces() async {
    var upgraded = 0;
    var alreadyCurrent = 0;
    var notOwner = 0;
    var failed = 0;
    final ids = await _index();
    for (final hex in ids.toSet()) {
      NodeId groupId;
      try {
        groupId = NodeId.fromHex(hex);
      } catch (_) {
        failed++;
        continue;
      }
      final outcome = await _serialized(
        groupId,
        () => _convertLegacyGroupLocked(groupId),
      );
      switch (outcome) {
        case 'upgraded':
          upgraded++;
        case 'current':
          alreadyCurrent++;
        case 'not-owner':
          notOwner++;
        default:
          failed++;
      }
    }
    return SpaceManifestMigration(
      scanned: ids.toSet().length,
      upgraded: upgraded,
      alreadyCurrent: alreadyCurrent,
      notOwner: notOwner,
      failed: failed,
    );
  }

  NodeId _randomGroupId() {
    final rnd = Random.secure();
    return NodeId(
      Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256))),
    );
  }

  Uint8List _randomEpochKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
  }

  /// The current folded state of [groupId], or null if unknown.
  Future<GroupState?> stateOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    return foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
      initialName: b.manifest.name,
      initialDescription: b.manifest.description ?? '',
      initialAvatarContentId: b.manifest.avatarContentId,
      initialCoverContentId: b.manifest.coverContentId,
    ).state;
  }

  /// A fresh opaque id for a custom role or participant group. Callers may
  /// stage a complete policy locally, but only [replaceSpaceAccessPolicy]
  /// makes it authoritative through the signed control log.
  String newSpaceAccessObjectId() => _newSpaceInviteId();

  /// Atomically replace custom roles, participant groups and direct role
  /// assignments. Optimistic [expectedRevision] prevents two editors from
  /// silently overwriting each other. Owners are unrestricted; a manageRoles
  /// delegate signs V20 and is constrained by the same capability ceiling in
  /// this service and the final causal-fold authorization boundary.
  Future<SpaceAccessPolicy?> replaceSpaceAccessPolicy(
    NodeId spaceId, {
    required int expectedRevision,
    required Iterable<SpaceRoleDefinition> roles,
    required Iterable<SpaceMemberGroup> groups,
    required Iterable<SpaceMemberRoleAssignment> directAssignments,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allowsControl(selfId, ControlOp.setPolicy) ||
        (state.accessPolicy?.revision ?? 0) != expectedRevision) {
      return null;
    }
    final now = _now();
    // Historical snapshots keep departed ids for audit. A fresh snapshot
    // automatically drops those stale assignments so one removal cannot make
    // every later policy edit structurally impossible.
    final currentGroups = [
      for (final group in groups)
        SpaceMemberGroup(
          groupId: group.groupId,
          name: group.name,
          members: group.members.where(state.isMember),
          roleIds: group.roleIds,
        ),
    ];
    final currentDirectAssignments = [
      for (final assignment in directAssignments)
        if (state.isMember(assignment.member)) assignment,
    ];
    final policy = SpaceAccessPolicy(
      spaceId: spaceId,
      schemaVersion:
          state.accessPolicy?.schemaVersion == 3 ||
              roles.any((role) => role.usesDenyEncoding)
          ? 3
          : state.accessPolicy?.schemaVersion == 2 ||
                roles.any((role) => role.usesScopedEncoding)
          ? 2
          : 1,
      revision: expectedRevision + 1,
      previousPolicyHash: state.accessPolicy?.policyHash ?? '',
      changedBy: selfId,
      changedAtMs: now,
      roles: roles,
      groups: currentGroups,
      directAssignments: currentDirectAssignments,
    );
    if (!policy.isStructurallyValid) {
      return null;
    }
    if (!SpaceAcl(state).authorizePolicyChange(selfId, policy).allowed) {
      return null;
    }
    final applied = await _addControlOp(
      spaceId,
      ControlOp.setPolicy,
      accessPolicy: policy,
      createdAtMs: now,
    );
    return applied ? policy : null;
  });

  /// Current signed channels of one Space, ordered for presentation.
  Future<List<SpaceChannel>> channelsOf(
    NodeId spaceId, {
    bool includeArchived = false,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const [];
    }
    final protected = await _protectedChannelsOf(bundle, state);
    final channels = [
      for (final channel in state.channels.values)
        if (includeArchived || !channel.archived) channel,
      for (final clear in protected.values)
        if (includeArchived || !clear.channel.archived) clear.channel,
    ];
    channels.sort((left, right) {
      final position = left.position.compareTo(right.position);
      if (position != 0) return position;
      return left.channelId.hex.compareTo(right.channelId.hex);
    });
    return channels;
  }

  /// Current participants allowed into one voice scope. Resolving this once
  /// lets the call FSM reconcile an N-party room without decrypting the same
  /// protected channel control separately for every participant.
  Future<({Set<NodeId> recipients, int? channelEpoch})?>
  currentVoiceChannelAdmission(NodeId groupId, NodeId? channelId) async {
    final bundle = await load(groupId);
    if (bundle == null || bundle.manifest.isSovereignDevice) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    Iterable<NodeId> candidates = state.members.values.map(
      (member) => member.nodeId,
    );
    int? channelEpoch;
    if (channelId != null) {
      if (!bundle.manifest.isSpace) return null;
      final open = state.channels[channelId.hex];
      if (open != null) {
        if (open.kind != SpaceChannelKind.voice || open.archived) return null;
      } else {
        final opaque = state.protectedChannels[channelId.hex];
        if (opaque == null) return null;
        final clear = await _materializeProtectedChannel(bundle, state, opaque);
        if (clear == null ||
            clear.channel.kind != SpaceChannelKind.voice ||
            clear.channel.archived) {
          return null;
        }
        candidates = clear.recipients;
        channelEpoch = opaque.channelEpoch;
      }
    }
    final acl = SpaceAcl(state);
    return (
      recipients: {
        for (final member in candidates)
          if (state.isMember(member) &&
              acl.allows(member, SpacePermission.view) &&
              acl.allows(
                member,
                SpacePermission.enterVoice,
                channelId: channelId,
              ))
            member,
      },
      channelEpoch: channelEpoch,
    );
  }

  /// Authoritative current admission for a voice room. Restricted channels
  /// fail closed when their rotated control/key is unavailable locally.
  Future<bool> canEnterVoiceChannel(
    NodeId groupId,
    NodeId? channelId,
    NodeId member,
  ) async =>
      (await currentVoiceChannelAdmission(
        groupId,
        channelId,
      ))?.recipients.contains(member) ??
      false;

  Future<NodeId?> createChannel(
    NodeId spaceId, {
    required String name,
    required SpaceChannelKind kind,
    String description = '',
    NodeId? categoryId,
    int position = 0,
    bool isDefault = false,
    SpaceChannelHistory history = SpaceChannelHistory.fromJoin,
    int? historySinceMs,
    SpaceChannelAccess access = SpaceChannelAccess.space,
    Iterable<NodeId> members = const [],
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(state).allows(
      _signer.selfId,
      SpacePermission.manageChannels,
      categoryId: categoryId,
    )) {
      return null;
    }
    final firstText =
        access == SpaceChannelAccess.space &&
        kind == SpaceChannelKind.text &&
        !state.channels.values.any(
          (channel) =>
              channel.kind == SpaceChannelKind.text && !channel.archived,
        );
    final createdAtMs = _now();
    final channel = SpaceChannel(
      spaceId: spaceId,
      channelId: _randomGroupId(),
      kind: kind,
      name: name.trim(),
      description: description,
      categoryId: categoryId,
      position: position,
      isDefault: kind == SpaceChannelKind.text && (isDefault || firstText),
      archived: false,
      history: history,
      historySinceMs: historySinceMs,
      createdBy: _signer.selfId,
      createdAtMs: createdAtMs,
      access: access,
    );
    if (!channel.isValid) return null;
    if (access != SpaceChannelAccess.space) {
      if (kind == SpaceChannelKind.category ||
          categoryId != null ||
          isDefault ||
          _epochService == null) {
        return null;
      }
      final applied = await _writeProtectedChannel(
        bundle,
        state,
        channel,
        requestedRecipients: members,
        create: true,
      );
      return applied ? channel.channelId : null;
    }
    final applied = await _addControlOp(
      spaceId,
      ControlOp.createChannel,
      channel: channel,
    );
    return applied ? channel.channelId : null;
  });

  /// Replace mutable channel fields while its signed identity remains fixed.
  Future<bool> updateChannel(NodeId spaceId, SpaceChannel channel) =>
      _serialized(spaceId, () async {
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
        ).state;
        final acl = SpaceAcl(state);
        final currentPublic = state.channels[channel.channelId.hex];
        final canManageDestination = acl.allows(
          _signer.selfId,
          SpacePermission.manageChannels,
          channelId: channel.channelId,
          categoryId: channel.kind == SpaceChannelKind.category
              ? channel.channelId
              : channel.categoryId,
        );
        final canManageSource =
            currentPublic == null ||
            acl.allows(
              _signer.selfId,
              SpacePermission.manageChannels,
              channelId: currentPublic.channelId,
              categoryId: currentPublic.kind == SpaceChannelKind.category
                  ? currentPublic.channelId
                  : currentPublic.categoryId,
            );
        if (!canManageDestination ||
            !canManageSource ||
            channel.spaceId != spaceId ||
            !channel.isValid) {
          return false;
        }
        if (channel.access != SpaceChannelAccess.space) {
          final protected = await _protectedChannelsOf(bundle, state);
          final current = protected[channel.channelId.hex];
          if (current == null ||
              !current.channel.sameIdentity(channel) ||
              _epochService == null) {
            return false;
          }
          return _writeProtectedChannel(
            bundle,
            state,
            channel,
            requestedRecipients: current.recipients,
            create: false,
          );
        }
        return _addControlOp(
          spaceId,
          ControlOp.updateChannel,
          channel: channel,
        );
      });

  /// How long one protected-channel key may stay in service, and how much may
  /// be written under it, before this device replaces it.
  ///
  /// Losing a device is not an event the Space can observe, so a key that
  /// never changes turns one lost device into a standing window over
  /// everything the channel goes on to say. Membership changes already rotate;
  /// these two bound the case where membership does not change for a long
  /// time. Neither is configurable: a per-channel dial for how weak a channel
  /// may become is a setting nobody needs and an attacker would enjoy.
  static const protectedChannelKeyMaxAgeMs = 30 * 24 * 60 * 60 * 1000;
  static const protectedChannelKeyMaxMessages = 1000;

  /// Replace a protected channel's key while leaving its ACL exactly as it is.
  ///
  /// The case this exists for is a suspected compromise — a lost phone, a
  /// shared screen — where the answer is a new key rather than a changed
  /// membership. Same permission as any other ACL edit: whoever may say who
  /// reads the channel may say when its key stops being the old one.
  Future<bool> rotateChannelKey(NodeId spaceId, NodeId channelId) =>
      _serialized(spaceId, () => _rotateChannelKeyLocked(spaceId, channelId));

  Future<bool> _rotateChannelKeyLocked(NodeId spaceId, NodeId channelId) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace || _epochService == null) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(state).allows(
      _signer.selfId,
      SpacePermission.manageChannels,
      channelId: channelId,
    )) {
      return false;
    }
    final current = (await _protectedChannelsOf(
      bundle,
      state,
    ))[channelId.hex];
    if (current == null) return false;
    // The recipients we pass are the ones we just decrypted, so this is a new
    // epoch and a new key over an unchanged ACL — the write path makes no
    // distinction between that and a membership edit.
    return _writeProtectedChannel(
      bundle,
      state,
      current.channel,
      requestedRecipients: current.recipients,
      create: false,
    );
  }

  /// Rotate the keys of protected channels whose current key has served past
  /// [protectedChannelKeyMaxAgeMs] or carried more than
  /// [protectedChannelKeyMaxMessages] messages. Returns how many rotated.
  ///
  /// Both bounds are read from state that is already signed and already here:
  /// the epoch's age from the control entry that introduced it, its volume
  /// from the messages that name it. Nothing new is persisted and no clock is
  /// trusted beyond the one already trusted for control ordering.
  ///
  /// Best-effort and idempotent. Only a device that may manage the channel can
  /// do it — for everyone else this is a no-op, and the rotation happens the
  /// next time someone who can looks. Callers can treat it as maintenance:
  /// rotating late is a weaker guarantee, not a broken one.
  Future<int> rotateStaleChannelKeys(NodeId spaceId) =>
      _serialized(spaceId, () async {
        final bundle = await load(spaceId);
        if (bundle == null ||
            !bundle.manifest.isSpace ||
            _epochService == null) {
          return 0;
        }
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
        ).state;
        final acl = SpaceAcl(state);
        final stale = <NodeId>[];
        for (final opaque in state.protectedChannels.values) {
          if (!acl.allows(
            _signer.selfId,
            SpacePermission.manageChannels,
            channelId: opaque.channelId,
          )) {
            continue;
          }
          if (await _protectedChannelKeyIsStale(bundle, opaque)) {
            stale.add(opaque.channelId);
          }
        }
        var rotated = 0;
        for (final channelId in stale) {
          // Each rotation appends control entries, so the next one must see
          // them: re-read rather than reuse the fold above.
          if (await _rotateChannelKeyLocked(spaceId, channelId)) rotated++;
        }
        return rotated;
      });

  Future<bool> _protectedChannelKeyIsStale(
    GroupBundle bundle,
    SpaceChannelControlEnvelope opaque,
  ) async {
    final startedAtMs = _protectedChannelEpochStartedAtMs(bundle, opaque);
    if (startedAtMs != null &&
        _now() - startedAtMs >= protectedChannelKeyMaxAgeMs) {
      return true;
    }
    var carried = 0;
    for (final message in await _messagesOfBundle(
      bundle,
      channelId: opaque.channelId,
      applyLocalRetention: false,
    )) {
      if (message.channelEpoch != opaque.channelEpoch) continue;
      if (++carried >= protectedChannelKeyMaxMessages) return true;
    }
    return false;
  }

  /// When the channel's current epoch was introduced, per the signed control
  /// entry that carried it. Null when that entry is no longer in the log —
  /// after a checkpoint compaction, say — in which case age says nothing and
  /// only the volume bound applies.
  int? _protectedChannelEpochStartedAtMs(
    GroupBundle bundle,
    SpaceChannelControlEnvelope opaque,
  ) {
    for (final entry in bundle.control.reversed) {
      final control = entry.channelControl;
      if (control == null ||
          control.channelId != opaque.channelId ||
          control.channelEpoch != opaque.channelEpoch) {
        continue;
      }
      return entry.createdAtMs;
    }
    return null;
  }

  /// Replace the explicit member portion of a protected channel ACL. Current
  /// Space owners/admins are always included so a future revocation never
  /// depends on one creator retaining the key. Every ACL mutation rotates the
  /// key and emits a new opaque signed control revision.
  Future<bool> setChannelMembers(
    NodeId spaceId,
    NodeId channelId,
    Iterable<NodeId> members,
  ) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace || _epochService == null) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (!SpaceAcl(state).allows(
      _signer.selfId,
      SpacePermission.manageChannels,
      channelId: channelId,
    )) {
      return false;
    }
    final protected = await _protectedChannelsOf(bundle, state);
    final current = protected[channelId.hex];
    if (current == null) return false;
    return _writeProtectedChannel(
      bundle,
      state,
      current.channel,
      requestedRecipients: members,
      create: false,
    );
  });

  Future<List<NodeId>?> channelMembersOf(
    NodeId spaceId,
    NodeId channelId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    final protected = await _protectedChannelsOf(bundle, state);
    final clear = protected[channelId.hex];
    if (clear != null) return List.unmodifiable(clear.recipients);
    if (state.channels.containsKey(channelId.hex)) {
      return List.unmodifiable(
        state.members.values.map((member) => member.nodeId),
      );
    }
    return null;
  }

  List<NodeId>? _protectedChannelRecipients(
    GroupState state,
    Iterable<NodeId> requested,
  ) {
    final recipients = <String, NodeId>{};
    for (final member in requested) {
      if (!state.isMember(member)) return null;
      recipients[member.hex] = member;
    }
    for (final member in state.members.values) {
      if (member.role.rank >= GroupRole.admin.rank) {
        recipients[member.nodeId.hex] = member.nodeId;
      }
    }
    recipients[_signer.selfId.hex] = _signer.selfId;
    final ordered = recipients.values.toList()
      ..sort((left, right) => left.hex.compareTo(right.hex));
    if (ordered.isEmpty || ordered.length > maxSpaceChannelRecipientCount) {
      return null;
    }
    return ordered;
  }

  Future<_PreparedProtectedChannelRevision?> _prepareProtectedChannel(
    GroupBundle bundle,
    GroupState state,
    SpaceChannel channel, {
    required Iterable<NodeId> requestedRecipients,
    required bool create,
    GroupState? recipientState,
    int? createdAtMs,
  }) async {
    final epochService = _epochService;
    if (epochService == null ||
        channel.access != SpaceChannelAccess.restricted ||
        channel.kind == SpaceChannelKind.category ||
        channel.categoryId != null ||
        channel.isDefault) {
      return null;
    }
    final recipients = _protectedChannelRecipients(
      recipientState ?? state,
      requestedRecipients,
    );
    if (recipients == null) return null;
    final previous = state.protectedChannels[channel.channelId.hex];
    if ((create && previous != null) || (!create && previous == null)) {
      return null;
    }
    SpaceRetentionPolicy? currentRetentionPolicy;
    var hasCurrentRetentionPolicy = false;
    SpaceChannelControlCleartext? previousClear;
    if (previous != null && state.protectedRetention.isNotEmpty) {
      previousClear = await _materializeProtectedChannel(
        bundle,
        state,
        previous,
        requireCurrentAcl: false,
      );
      if (previousClear == null) return null;
      final retention = await _materializedRetentionHistory(
        bundle,
        state,
        currentChannels: {channel.channelId.hex: previousClear},
      );
      if (retention.hiddenThroughMs[channel.channelId.hex] ==
          0x7fffffffffffffff) {
        return null;
      }
      for (final revision in retention.revisions) {
        final policy = revision.policy;
        if (policy.channelId != channel.channelId) continue;
        currentRetentionPolicy = policy;
        hasCurrentRetentionPolicy = true;
      }
      final addsRecipient = recipients.any(
        (recipient) => !previousClear!.recipients.contains(recipient),
      );
      if (addsRecipient &&
          hasCurrentRetentionPolicy &&
          state.roleOf(_signer.selfId) != GroupRole.owner) {
        // Only the owner can preserve a manageStorage decision in the new
        // epoch. Never grant an old content key merely to reveal policy.
        return null;
      }
    }
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      _signer.selfId,
    );
    if (link.blocked) return null;
    final channelEpoch = create ? 1 : previous!.channelEpoch + 1;
    final key = _randomEpochKey();
    Uint8List? clear;
    Uint8List? retentionClear;
    var transferredKey = false;
    try {
      final sealed = await epochService.sealEpoch(
        groupId: channel.channelId,
        epoch: channelEpoch,
        epochKey: key,
        recipients: recipients,
      );
      final controlClear = SpaceChannelControlCleartext(
        channel: channel,
        recipients: recipients,
      );
      if (!controlClear.isStructurallyValid) return null;
      clear = controlClear.encode();
      final revisionCreatedAtMs = createdAtMs ?? _now();
      final encrypted = await encryptSpaceChannelControlPayload(
        spaceId: bundle.manifest.groupId,
        channelId: channel.channelId,
        channelEpoch: channelEpoch,
        keyCommitment: sealed.descriptor.keyCommitment,
        author: _signer.selfId,
        policyVersion: state.policyVersion,
        createdAtMs: revisionCreatedAtMs,
        clearText: clear,
        channelKey: key,
      );
      final opaque = SpaceChannelControlEnvelope(
        spaceId: bundle.manifest.groupId,
        channelId: channel.channelId,
        channelEpoch: channelEpoch,
        keyDescriptor: sealed.descriptor,
        encryptedControl: encrypted,
      );
      final signed = _signer.signControl(
        ControlEntry(
          version: 5,
          groupId: bundle.manifest.groupId,
          author: _signer.selfId,
          seq: link.seq,
          prevHash: link.prevHash,
          op: create ? ControlOp.createChannel : ControlOp.updateChannel,
          target: null,
          role: null,
          policyVersion: state.policyVersion,
          createdAtMs: revisionCreatedAtMs,
          signature: Uint8List(0),
          channelControl: opaque,
        ),
      );
      final controls = <ControlEntry>[signed];
      final candidate = <ControlEntry>[...bundle.control, signed];
      if (hasCurrentRetentionPolicy &&
          currentRetentionPolicy != null &&
          state.roleOf(_signer.selfId) == GroupRole.owner) {
        final retentionCreatedAt = revisionCreatedAtMs;
        retentionClear = Uint8List.fromList(
          utf8.encode(jsonEncode(currentRetentionPolicy.toJson())),
        );
        final retentionEncrypted = await encryptSpaceChannelRetentionPayload(
          spaceId: bundle.manifest.groupId,
          channelId: channel.channelId,
          channelEpoch: channelEpoch,
          author: _signer.selfId,
          seq: link.seq + 1,
          prevHash: controlEntryHash(signed),
          policyVersion: state.policyVersion,
          createdAtMs: retentionCreatedAt,
          clearText: retentionClear,
          channelKey: key,
        );
        final retention = _signer.signControl(
          ControlEntry(
            version: 15,
            groupId: bundle.manifest.groupId,
            author: _signer.selfId,
            seq: link.seq + 1,
            prevHash: controlEntryHash(signed),
            op: ControlOp.setRetention,
            target: null,
            role: null,
            channelRetention: SpaceChannelRetentionEnvelope(
              spaceId: bundle.manifest.groupId,
              channelId: channel.channelId,
              channelEpoch: channelEpoch,
              encryptedPolicy: retentionEncrypted,
            ),
            policyVersion: state.policyVersion,
            createdAtMs: retentionCreatedAt,
            signature: Uint8List(0),
          ),
        );
        candidate.add(retention);
        controls.add(retention);
      }
      final folded = foldControlLog(
        owner: bundle.manifest.owner,
        entries: candidate,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      );
      if (folded.rejected.any(
        (entry) => controls.any(
          (control) =>
              entry.author == control.author && entry.seq == control.seq,
        ),
      )) {
        return null;
      }
      final keyId = _channelKeyId(channel.channelId, channelEpoch);
      final result = _PreparedProtectedChannelRevision(
        bundle: bundle.copyWith(
          control: candidate,
          channelEpochEnvelopes: [
            ...bundle.channelEpochEnvelopes,
            ...sealed.envelopes,
          ],
          localChannelEpochKeys: {
            ...bundle.localChannelEpochKeys,
            keyId: Uint8List.fromList(key),
          },
        ),
        controls: controls,
        transientKey: key,
      );
      transferredKey = true;
      return result;
    } catch (_) {
      return null;
    } finally {
      clear?.fillRange(0, clear.length, 0);
      retentionClear?.fillRange(0, retentionClear.length, 0);
      if (!transferredKey) key.fillRange(0, key.length, 0);
    }
  }

  Future<bool> _writeProtectedChannel(
    GroupBundle bundle,
    GroupState state,
    SpaceChannel channel, {
    required Iterable<NodeId> requestedRecipients,
    required bool create,
  }) async {
    final prepared = await _prepareProtectedChannel(
      bundle,
      state,
      channel,
      requestedRecipients: requestedRecipients,
      create: create,
    );
    if (prepared == null) return false;
    try {
      await _save(prepared.bundle);
      unawaited(
        broadcastDelta(bundle.manifest.groupId, control: prepared.controls),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      prepared.transientKey.fillRange(0, prepared.transientKey.length, 0);
    }
  }

  Future<void> _repairProtectedChannelEpochs(NodeId spaceId) =>
      _serialized(spaceId, () async {
        var bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) {
          return;
        }
        var currentBundle = bundle;
        var state = foldControlLog(
          owner: currentBundle.manifest.owner,
          entries: currentBundle.control,
          verify: (entry) => _validControlFor(currentBundle.manifest, entry),
          initialName: currentBundle.manifest.name,
        ).state;
        if (state.roleOf(_signer.selfId) != GroupRole.owner) return;
        final ids = state.protectedChannels.keys.toList();
        for (final id in ids) {
          final envelope = state.protectedChannels[id];
          if (envelope == null) continue;
          final current = await _materializeProtectedChannel(
            currentBundle,
            state,
            envelope,
          );
          if (current != null) continue;
          final stale = await _materializeProtectedChannel(
            currentBundle,
            state,
            envelope,
            requireCurrentAcl: false,
          );
          if (stale == null) continue;
          final recipients = stale.recipients
              .where(state.isMember)
              .toList(growable: false);
          await _writeProtectedChannel(
            currentBundle,
            state,
            stale.channel,
            requestedRecipients: recipients,
            create: false,
          );
          final reloaded = await load(spaceId);
          if (reloaded == null) return;
          currentBundle = reloaded;
          state = foldControlLog(
            owner: currentBundle.manifest.owner,
            entries: currentBundle.control,
            verify: (entry) => _validControlFor(currentBundle.manifest, entry),
            initialName: currentBundle.manifest.name,
          ).state;
        }
      });

  Future<bool> setChannelArchived(
    NodeId spaceId,
    NodeId channelId,
    bool archived,
  ) async {
    final current = (await channelsOf(
      spaceId,
      includeArchived: true,
    )).where((channel) => channel.channelId == channelId).firstOrNull;
    if (current == null || current.archived == archived) return current != null;
    return updateChannel(spaceId, current.copyWith(archived: archived));
  }

  Future<bool> setDefaultChannel(NodeId spaceId, NodeId channelId) async {
    final current = (await channelsOf(
      spaceId,
      includeArchived: true,
    )).where((channel) => channel.channelId == channelId).firstOrNull;
    if (current == null ||
        current.kind != SpaceChannelKind.text ||
        current.archived) {
      return false;
    }
    if (current.isDefault) return true;
    return updateChannel(spaceId, current.copyWith(isDefault: true));
  }

  /// The next per-author seq for [author] in a list of entries carrying seq.
  int _nextSeq(Iterable<int> seqs) {
    var max = -1;
    for (final s in seqs) {
      if (s > max) max = s;
    }
    return max + 1;
  }

  /// Append a control op authored by us. Returns true if it was valid (signed,
  /// permitted against the current state) and persisted; false otherwise.
  Future<bool> addControlOp(
    NodeId groupId,
    ControlOp op, {
    NodeId? target,
    GroupRole? role,
    String? text,
    SpaceChannel? channel,
  }) => _serialized(
    groupId,
    () => _addControlOp(
      groupId,
      op,
      target: target,
      role: role,
      text: text,
      channel: channel,
    ),
  );

  /// Turn a still-live consent decision into membership under the same
  /// per-Space mutation queue as role, moderation and lifecycle changes.
  ///
  /// Contact state belongs to MessagingService, so it cannot share the
  /// per-Space mutex directly. The synchronous generation bump from
  /// [notifyContactAccessChanged] plus the durable status read in [guard]
  /// closes that cross-store TOCTOU window. [_addControlOp] checks the guard
  /// after the expensive epoch-seal awaits and again after persistence,
  /// before any snapshot can be sent to the candidate member.
  Future<bool> _addMemberFromConsent(
    NodeId spaceId,
    NodeId member,
    GroupRole role, {
    required bool requireAcceptedContact,
  }) {
    final generation = _contactAccessGeneration(member);
    Future<bool> guard() => _contactConsentStillAllows(
      member,
      generation: generation,
      requireAccepted: requireAcceptedContact,
    );
    return _serialized(
      spaceId,
      () => _addControlOp(
        spaceId,
        ControlOp.addMember,
        target: member,
        role: role,
        commitGuard: guard,
      ),
    );
  }

  Future<bool> _addControlOp(
    NodeId groupId,
    ControlOp op, {
    NodeId? target,
    GroupRole? role,
    String? text,
    SpaceChannel? channel,
    SpaceRulesVersion? rules,
    SpaceRulesAcceptance? rulesAcceptance,
    SpaceModerationAction? moderationAction,
    SpaceModerationRevocation? moderationRevocation,
    SpaceChannelModerationEnvelope? channelModeration,
    SpaceChannelRetentionEnvelope? channelRetention,
    SpaceRetentionPolicy? retentionPolicy,
    SpaceLifecycleTransition? lifecycleTransition,
    SpacePostPin? postPin,
    SpaceRecommendationCampaign? recommendationCampaign,
    SpaceRecommendationPolicy? recommendationPolicy,
    SpaceAccessPolicy? accessPolicy,
    int? createdAtMs,
    Future<bool> Function()? commitGuard,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    if (b.manifest.name == kDeviceGroupName) return false;
    if ((op == ControlOp.transferOwnership ||
            op == ControlOp.publishRules ||
            op == ControlOp.acceptRules ||
            op == ControlOp.moderate ||
            op == ControlOp.revokeModeration ||
            op == ControlOp.setRetention ||
            op == ControlOp.setPostPin ||
            op == ControlOp.setRecommendationCampaign ||
            op == ControlOp.setRecommendationPolicy ||
            op == ControlOp.archiveSpace ||
            op == ControlOp.deleteSpace ||
            op == ControlOp.restoreSpace) &&
        !b.manifest.isSpace) {
      return false;
    }
    final initialLink = _nextControlLink(b.manifest, b.control, _signer.selfId);
    if (initialLink.blocked) return false;
    var mySeq = initialLink.seq;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final protectedBefore = <SpaceChannelControlCleartext>[];
    final moderationRemovesMember =
        op == ControlOp.moderate &&
        moderationAction?.kind.removesMembership == true;
    final protectedAclMayChange =
        op == ControlOp.removeMember ||
        op == ControlOp.ban ||
        moderationRemovesMember ||
        op == ControlOp.setRole ||
        op == ControlOp.transferOwnership ||
        (op == ControlOp.addMember && role == GroupRole.admin);
    if (protectedAclMayChange) {
      for (final envelope in state.protectedChannels.values) {
        final clear = await _materializeProtectedChannel(
          b,
          state,
          envelope,
          requireCurrentAcl: false,
        );
        // A membership/role transaction may not commit while even one current
        // protected ACL cannot be re-encrypted. Silently skipping it would
        // recreate the stale-key split this transaction is meant to prevent.
        if (clear == null) return false;
        protectedBefore.add(clear);
      }
    }
    final pv = state.policyVersion;
    final epochService = _epochService;
    final generatedKeys = <Uint8List>[];
    final controls = <ControlEntry>[];
    final envelopes = [...b.epochEnvelopes];
    final localKeys = <int, Uint8List>{
      for (final entry in b.localEpochKeys.entries) entry.key: entry.value,
    };
    try {
      GroupEpochSealSet? prepared;
      Uint8List? preparedKey;
      if (epochService != null &&
          (op == ControlOp.removeMember ||
              op == ControlOp.ban ||
              moderationRemovesMember ||
              op == ControlOp.rotateEpoch)) {
        final recipients = [
          for (final member in state.members.values)
            if ((op != ControlOp.removeMember &&
                    op != ControlOp.ban &&
                    !moderationRemovesMember) ||
                member.nodeId != target)
              member.nodeId,
        ];
        if (recipients.isEmpty) return false;
        preparedKey = _randomEpochKey();
        generatedKeys.add(preparedKey);
        prepared = await epochService.sealEpoch(
          groupId: groupId,
          epoch: state.epoch + 1,
          epochKey: preparedKey,
          recipients: recipients,
        );
      }

      final createdAt =
          createdAtMs ??
          (op == ControlOp.createChannel && channel != null
              ? channel.createdAtMs
              : _now());
      final revokesPublishing =
          op == ControlOp.mute ||
          op == ControlOp.removeMember ||
          op == ControlOp.ban ||
          (op == ControlOp.moderate &&
              moderationAction?.kind.blocksPosts == true);
      final postBoundary =
          b.manifest.isSpace && revokesPublishing && target != null
          ? _postBoundaryFor(b, target)
          : null;
      ControlEntry signMutation(int seq, String prevHash) =>
          _signer.signControl(
            ControlEntry(
              version: lifecycleTransition != null
                  ? lifecycleTransition.recoveryDeadlineMs == null
                        ? 10
                        : 11
                  : postPin != null
                  ? 12
                  : recommendationCampaign != null
                  ? 13
                  : recommendationPolicy != null
                  ? 21
                  : accessPolicy != null
                  ? state.roleOf(_signer.selfId) != GroupRole.owner
                        ? 20
                        : accessPolicy.schemaVersion >= 3
                        ? 19
                        : accessPolicy.schemaVersion >= 2
                        ? 18
                        : 17
                  : channelRetention != null
                  ? 15
                  : retentionPolicy != null
                  ? retentionPolicy.mediaOnly
                        ? 16
                        : 9
                  : channelModeration != null
                  ? 14
                  : moderationAction != null || moderationRevocation != null
                  ? 8
                  : rules != null || rulesAcceptance != null
                  ? 7
                  : op == ControlOp.transferOwnership
                  ? 6
                  : postBoundary == null
                  ? 2
                  : 3,
              groupId: groupId,
              author: _signer.selfId,
              seq: seq,
              prevHash: prevHash,
              op: op,
              target: target,
              role: role,
              text: text,
              channel: channel,
              rules: rules,
              rulesAcceptance: rulesAcceptance,
              moderationAction: moderationAction,
              moderationRevocation: moderationRevocation,
              channelModeration: channelModeration,
              channelRetention: channelRetention,
              retentionPolicy: retentionPolicy,
              lifecycleTransition: lifecycleTransition,
              postPin: postPin,
              recommendationCampaign: recommendationCampaign,
              recommendationPolicy: recommendationPolicy,
              accessPolicy: accessPolicy,
              policyVersion: pv,
              createdAtMs: createdAt,
              signature: Uint8List(0),
              epochDescriptor: prepared?.descriptor,
              postBoundary: postBoundary,
            ),
          );

      // First project the requested membership/role result. Protected channel
      // revisions are then appended *before* that mutation, but their encrypted
      // recipient sets are derived from this future state. This ordering lets
      // the current owner preserve an owner-only retention decision during an
      // ownership transfer while the final bundle is still one atomic write.
      final projected = signMutation(initialLink.seq, initialLink.prevHash);
      final projectedFold = foldControlLog(
        owner: b.manifest.owner,
        entries: [...b.control, projected],
        verify: (entry) => _validControlFor(b.manifest, entry),
        initialName: b.manifest.name,
      );
      if (projectedFold.rejected.any(
        (entry) =>
            identical(entry, projected) ||
            (entry.author == projected.author && entry.seq == projected.seq),
      )) {
        return false;
      }

      var workingBundle = b;
      var workingState = state;
      if (protectedAclMayChange) {
        final demotesProtectedAdmin =
            op == ControlOp.setRole &&
            target != null &&
            (state.roleOf(target)?.rank ?? -1) >= GroupRole.admin.rank &&
            (projectedFold.state.roleOf(target)?.rank ?? -1) <
                GroupRole.admin.rank;
        for (final old in protectedBefore) {
          final recipients = old.recipients
              .where(
                (member) =>
                    projectedFold.state.isMember(member) &&
                    !(demotesProtectedAdmin && member == target),
              )
              .toList(growable: false);
          final revision = await _prepareProtectedChannel(
            workingBundle,
            workingState,
            old.channel,
            requestedRecipients: recipients,
            create: false,
            recipientState: projectedFold.state,
            createdAtMs: createdAt,
          );
          if (revision == null) return false;
          generatedKeys.add(revision.transientKey);
          controls.addAll(revision.controls);
          workingBundle = revision.bundle;
          workingState = foldControlLog(
            owner: b.manifest.owner,
            entries: workingBundle.control,
            verify: (entry) => _validControlFor(b.manifest, entry),
            initialName: b.manifest.name,
          ).state;
        }
      }

      final mutationLink = _nextControlLink(
        b.manifest,
        workingBundle.control,
        _signer.selfId,
      );
      if (mutationLink.blocked) return false;
      mySeq = mutationLink.seq;
      final signed = signMutation(mySeq, mutationLink.prevHash);
      controls.add(signed);
      var candidate = [...workingBundle.control, signed];
      var folded = foldControlLog(
        owner: b.manifest.owner,
        entries: candidate,
        verify: (entry) => _validControlFor(b.manifest, entry),
        initialName: b.manifest.name,
      );
      if (folded.rejected.any(
        (entry) =>
            identical(entry, signed) ||
            (entry.author == signed.author && entry.seq == signed.seq),
      )) {
        return false;
      }
      if (prepared != null && preparedKey != null) {
        envelopes.addAll(prepared.envelopes);
        localKeys[prepared.descriptor.epoch] = Uint8List.fromList(preparedKey);
      }

      // An add itself must remain readable by legacy peers, then an immediately
      // following signed rotate establishes a key for the post-add membership.
      // New members receive no older envelopes: forward secrecy is the default.
      if (op == ControlOp.addMember && epochService != null) {
        final key = _randomEpochKey();
        generatedKeys.add(key);
        final sealed = await epochService.sealEpoch(
          groupId: groupId,
          epoch: folded.state.epoch + 1,
          epochKey: key,
          recipients: folded.state.members.values.map(
            (member) => member.nodeId,
          ),
        );
        mySeq++;
        final rotate = _signer.signControl(
          ControlEntry(
            version: 2,
            groupId: groupId,
            author: _signer.selfId,
            seq: mySeq,
            prevHash: controlEntryHash(signed),
            op: ControlOp.rotateEpoch,
            target: null,
            role: null,
            policyVersion: folded.state.policyVersion,
            createdAtMs: createdAt + 1,
            signature: Uint8List(0),
            epochDescriptor: sealed.descriptor,
          ),
        );
        candidate = [...candidate, rotate];
        folded = foldControlLog(
          owner: b.manifest.owner,
          entries: candidate,
          verify: (entry) => _validControlFor(b.manifest, entry),
          initialName: b.manifest.name,
        );
        if (folded.rejected.any(
          (entry) =>
              identical(entry, rotate) ||
              (entry.author == rotate.author && entry.seq == rotate.seq),
        )) {
          return false;
        }
        controls.add(rotate);
        envelopes.addAll(sealed.envelopes);
        localKeys[sealed.descriptor.epoch] = Uint8List.fromList(key);
      }

      final savedBundle = workingBundle.copyWith(
        control: candidate,
        epochEnvelopes: envelopes,
        localEpochKeys: localKeys,
      );
      if (commitGuard != null && !await commitGuard()) return false;
      await _save(savedBundle);
      if (commitGuard != null && !await commitGuard()) {
        // The relationship changed while the storage write itself was in
        // flight. Do not broadcast the transient add (and its epoch envelope)
        // to the candidate. Append a signed removal + epoch rotation while the
        // caller still owns the same per-Space queue, then send one full
        // convergent snapshot to the remaining members. The append-only audit
        // truthfully records the rare cross-store race instead of rewriting
        // already persisted signed history.
        final compensated = await _addControlOp(
          groupId,
          ControlOp.removeMember,
          target: target,
        );
        final latestState = await stateOf(groupId);
        final removalPersisted =
            target != null &&
            latestState != null &&
            !latestState.isMember(target);
        if (compensated || removalPersisted) {
          try {
            await broadcast(groupId);
          } catch (error) {
            // The signed removal is already durable and the rejected candidate
            // never received the transient add. Keep the fail-closed local
            // truth; ordinary anti-entropy can retry convergence.
            devLog(
              () =>
                  'xVeil[spaces]: consent compensation persisted but '
                  'snapshot retry failed (${groupId.short}): $error',
            );
          }
        } else {
          // No membership snapshot was emitted yet and this service still owns
          // the per-Space queue, so restoring the exact pre-commit bundle is a
          // safe local transaction rollback (not a signed-history rewrite
          // visible to peers).
          await _save(b);
          devLog(
            () =>
                'xVeil[spaces]: consent changed during membership commit; '
                'compensating removal failed, restored pre-commit bundle '
                '(${groupId.short})',
          );
        }
        return false;
      }
      // Protected ACL/key revisions and the membership/role mutation became
      // durable in the same storeFile call. Only now may peers observe them.
      // A join needs the whole log; every other mutation is a bounded delta.
      if (protectedAclMayChange) {
        if (op == ControlOp.addMember) {
          await broadcast(groupId);
        } else {
          await broadcastDelta(groupId, control: controls);
        }
      } else if (op == ControlOp.addMember) {
        unawaited(broadcast(groupId));
      } else {
        unawaited(broadcastDelta(groupId, control: controls));
      }
      if (b.manifest.isSpace) {
        if ({
          ControlOp.addMember,
          ControlOp.removeMember,
          ControlOp.setRole,
          ControlOp.leave,
          ControlOp.transferOwnership,
        }.contains(op)) {
          _observeSpace(
            SpaceObservationType.memberChanged,
            SpaceObservationOutcome.succeeded,
          );
        }
        if (moderationAction?.kind == SpaceModerationKind.permanentBan) {
          _observeSpace(
            SpaceObservationType.memberBanned,
            SpaceObservationOutcome.succeeded,
          );
        }
        final keyRows = controls
            .where(
              (entry) =>
                  entry.epochDescriptor != null || entry.channelControl != null,
            )
            .length;
        if (keyRows > 0) {
          _observeSpace(
            SpaceObservationType.keyRotated,
            SpaceObservationOutcome.succeeded,
            amount: keyRows,
          );
        }
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      for (final key in generatedKeys) {
        key.fillRange(0, key.length, 0);
      }
    }
  }

  /// Rename [groupId] (admins+). The name folds into every member's view via a
  /// signed `setName` op (delta-broadcast). Returns false if we lack permission.
  Future<bool> renameGroup(NodeId groupId, String name) {
    final normalized = name.trim();
    if (normalized.isEmpty || normalized.length > 160) {
      return Future.value(false);
    }
    return addControlOp(groupId, ControlOp.setName, text: normalized);
  }

  /// Update the public-facing Space summary through the same signed control
  /// log as the name. Empty text deliberately clears it; no mutable side-store
  /// can diverge between members.
  Future<bool> setSpaceDescription(NodeId spaceId, String description) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final normalized = description.trim();
    if (normalized.length > 4096) return false;
    return addControlOp(spaceId, ControlOp.setDescription, text: normalized);
  }

  /// Replace the Space avatar/cover with shared-content ids (null clears a
  /// slot). The image bytes must already be registered in the shared content
  /// store, so they replicate through the same membership-authorized path as
  /// publication media; this row only re-points the signed profile.
  Future<bool> setSpaceProfileMedia(
    NodeId spaceId, {
    String? avatarContentId,
    String? coverContentId,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final payload = encodeSpaceProfileMedia(
      avatarContentId: avatarContentId,
      coverContentId: coverContentId,
    );
    if (decodeSpaceProfileMedia(payload) == null) return false;
    return addControlOp(spaceId, ControlOp.setProfileMedia, text: payload);
  }

  /// Publish a typed Space-wide or channel retention revision. Open channel
  /// policies use the signed V9 shape. Restricted channel policy semantics use
  /// V15 ciphertext under that channel epoch; only its already-opaque routing
  /// id/epoch remain visible in the global control log.
  Future<bool> setSpaceRetentionPolicy(
    NodeId spaceId,
    SpaceRetentionPolicy policy,
  ) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        !policy.isStructurallyValid) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allows(
      _signer.selfId,
      SpacePermission.manageStorage,
      channelId: policy.channelId,
    )) {
      return false;
    }
    final channelId = policy.channelId;
    if (channelId == null || state.channels.containsKey(channelId.hex)) {
      return _addControlOp(
        spaceId,
        ControlOp.setRetention,
        retentionPolicy: policy,
      );
    }
    final envelope = state.protectedChannels[channelId.hex];
    if (envelope == null) return false;
    final clearChannel = await _materializeProtectedChannel(
      bundle,
      state,
      envelope,
    );
    if (clearChannel == null ||
        clearChannel.channel.access != SpaceChannelAccess.restricted ||
        clearChannel.channel.kind != SpaceChannelKind.text) {
      return false;
    }
    final key = bundle
        .localChannelEpochKeys[_channelKeyId(channelId, envelope.channelEpoch)];
    if (key == null ||
        !_validLocalChannelEpochKey(
          bundle.manifest,
          bundle.control,
          channelId,
          envelope.channelEpoch,
          key,
        )) {
      return false;
    }
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      _signer.selfId,
    );
    if (link.blocked) return false;
    final createdAt = _now();
    Uint8List? clear;
    try {
      clear = Uint8List.fromList(utf8.encode(jsonEncode(policy.toJson())));
      final encrypted = await encryptSpaceChannelRetentionPayload(
        spaceId: spaceId,
        channelId: channelId,
        channelEpoch: envelope.channelEpoch,
        author: _signer.selfId,
        seq: link.seq,
        prevHash: link.prevHash,
        policyVersion: state.policyVersion,
        createdAtMs: createdAt,
        clearText: clear,
        channelKey: key,
      );
      return _addControlOp(
        spaceId,
        ControlOp.setRetention,
        channelRetention: SpaceChannelRetentionEnvelope(
          spaceId: spaceId,
          channelId: channelId,
          channelEpoch: envelope.channelEpoch,
          encryptedPolicy: encrypted,
        ),
        createdAtMs: createdAt,
      );
    } catch (_) {
      return false;
    } finally {
      clear?.fillRange(0, clear.length, 0);
    }
  });

  /// Effective signed policy visible to this device for one Space/channel.
  /// Null is fail-closed: the channel is unknown, unauthorized, or has a
  /// current encrypted revision this device cannot authenticate/decrypt.
  Future<SpaceRetentionPolicy?> spaceRetentionPolicyOf(
    NodeId spaceId, {
    NodeId? channelId,
  }) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return null;
    }
    if (channelId == null || state.channels.containsKey(channelId.hex)) {
      return state.effectiveRetentionPolicy(channelId);
    }
    final channels = await _protectedChannelsOf(bundle, state);
    if (channels[channelId.hex] == null) return null;
    final history = await _materializedRetentionHistory(
      bundle,
      state,
      currentChannels: channels,
    );
    if (history.hiddenThroughMs[channelId.hex] == 0x7fffffffffffffff) {
      return null;
    }
    return _effectiveRetentionPolicy(history.revisions, channelId);
  }

  /// Authorized audit projection. Clear Space/open-channel revisions and only
  /// decryptable restricted-channel revisions are returned in signed order.
  Future<List<SpaceRetentionRevision>> spaceRetentionHistoryOf(
    NodeId spaceId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const [];
    }
    return (await _materializedRetentionHistory(bundle, state)).revisions;
  }

  /// One newest-first, typed view over immutable accepted policy evidence.
  ///
  /// Access snapshots are already clear to Space members. Retention rows are
  /// materialized through [spaceRetentionHistoryOf], so a restricted-channel
  /// policy is included only when this device can authenticate and decrypt it.
  Future<List<SpacePolicyAuditEntry>> spacePolicyAudit(NodeId spaceId) async {
    final state = await stateOf(spaceId);
    if (state == null ||
        !SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const [];
    }
    final entries = <SpacePolicyAuditEntry>[
      for (final policy in state.accessPolicyHistory)
        SpaceAccessPolicyAuditEntry(policy),
      for (final revision in await spaceRetentionHistoryOf(spaceId))
        SpaceRetentionPolicyAuditEntry(revision),
      for (final policy in state.recommendationPolicyHistory)
        SpaceRecommendationPolicyAuditEntry(policy),
    ];
    entries.sort((left, right) {
      final changed = right.changedAtMs.compareTo(left.changedAtMs);
      return changed != 0 ? changed : right.stableId.compareTo(left.stableId);
    });
    return List.unmodifiable(entries);
  }

  String _localSpaceRetentionKey(NodeId spaceId) =>
      'space.retention.local.v1:${spaceId.hex}';

  Future<({int? days, int retiredBeforeMs})> _localSpaceRetention(
    NodeId spaceId,
  ) async {
    final raw = await _storage.getSetting(_localSpaceRetentionKey(spaceId));
    if (raw == null || raw.isEmpty) return (days: null, retiredBeforeMs: -1);
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1) {
        return (days: null, retiredBeforeMs: -1);
      }
      final days = value['days'];
      final retired = value['retiredBefore'];
      if ((days != null && (days is! int || days <= 0 || days > 36500)) ||
          retired is! int ||
          retired < -1) {
        return (days: null, retiredBeforeMs: -1);
      }
      return (days: days as int?, retiredBeforeMs: retired);
    } catch (_) {
      return (days: null, retiredBeforeMs: -1);
    }
  }

  Future<int?> localSpaceRetentionDays(NodeId spaceId) async =>
      (await _localSpaceRetention(spaceId)).days;

  Future<int> _localSpaceRetentionCutoff(NodeId spaceId, int atMs) async {
    final local = await _localSpaceRetention(spaceId);
    final rolling = local.days == null
        ? -1
        : atMs - Duration(days: local.days!).inMilliseconds;
    return rolling > local.retiredBeforeMs ? rolling : local.retiredBeforeMs;
  }

  /// Change only this device's materialized history window. The previously
  /// reached cutoff is retained, so extending the window never resurrects
  /// locally retired history and never mutates the signed Space policy.
  Future<bool> setLocalSpaceRetentionDays(NodeId spaceId, int? days) async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        !bundle.manifest.isSpace ||
        (days != null && (days <= 0 || days > 36500))) {
      return false;
    }
    final now = _now();
    final cutoff = await _localSpaceRetentionCutoff(spaceId, now);
    await _storage.putSetting(
      _localSpaceRetentionKey(spaceId),
      jsonEncode({
        'v': 1,
        'days': ?days,
        'retiredBefore': cutoff,
        'updatedAt': now,
      }),
    );
    changes.value++;
    return true;
  }

  /// Publish a new immutable rules revision through the signed Space control
  /// log. Revisions are contiguous and keep the full previous history; a
  /// concurrent stale revision is rejected deterministically by the fold.
  Future<bool> publishSpaceRules(
    NodeId spaceId, {
    required String fullText,
    required String summary,
    int? effectiveAtMs,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(
      state,
    ).allows(_signer.selfId, SpacePermission.manageSettings)) {
      return false;
    }
    final normalizedText = fullText.trim();
    final normalizedSummary = summary.trim();
    final publishedAt = _now();
    // UI/API clocks the "effective now" choice before this signed mutation
    // receives its monotonic timestamp. Clamp a past/equal choice to the exact
    // signed publish time; preserve genuinely future activation dates.
    final requestedEffectiveAt = effectiveAtMs ?? publishedAt;
    final effectiveAt = requestedEffectiveAt > publishedAt
        ? requestedEffectiveAt
        : publishedAt;
    final nextVersion = (state.currentRules?.version ?? 0) + 1;
    final rules = SpaceRulesVersion(
      version: nextVersion,
      fullText: normalizedText,
      summary: normalizedSummary,
      author: _signer.selfId,
      publishedAtMs: publishedAt,
      effectiveAtMs: effectiveAt,
      previousVersion: nextVersion == 1 ? null : nextVersion - 1,
    );
    if (!rules.isStructurallyValid) return false;
    return _addControlOp(
      spaceId,
      ControlOp.publishRules,
      rules: rules,
      createdAtMs: publishedAt,
    );
  });

  /// Acknowledge the current rules as the active member. Publishing a later
  /// revision leaves this signed acknowledgement in history and makes
  /// [GroupState.requiresRulesAcceptance] true until the member accepts again.
  Future<bool> acceptSpaceRules(NodeId spaceId) =>
      _serialized(spaceId, () async {
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        final state = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        ).state;
        final rules = state.currentRules;
        if (rules == null ||
            !SpaceAcl(
              state,
            ).allowsControl(_signer.selfId, ControlOp.acceptRules)) {
          return false;
        }
        if (!state.requiresRulesAcceptance(_signer.selfId)) return true;
        final acceptedAt = _now();
        return _addControlOp(
          spaceId,
          ControlOp.acceptRules,
          rulesAcceptance: SpaceRulesAcceptance(
            rulesVersion: rules.version,
            acceptedAtMs: acceptedAt,
          ),
          createdAtMs: acceptedAt,
        );
      });

  /// Append one signed moderation action and return its immutable audit id.
  /// The method is Space-only: group chats retain their existing lightweight
  /// membership controls and never acquire a community moderation ledger.
  Future<String?> moderateSpace(
    NodeId spaceId, {
    required SpaceModerationKind kind,
    required NodeId target,
    required SpaceModerationScope scope,
    required String reason,
    NodeId? channelId,
    int? expiresAtMs,
    SpaceModerationReference? reference,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final removesContent = {
      SpaceModerationKind.deleteMessage,
      SpaceModerationKind.deletePost,
    }.contains(kind);
    if (!SpaceAcl(state).allowsControl(
      _signer.selfId,
      ControlOp.moderate,
      target: target,
      channelId: channelId,
      moderationTargetsRemovedContent: removesContent,
    )) {
      return null;
    }
    final createdAt = _now();
    final action = SpaceModerationAction(
      kind: kind,
      target: target,
      scope: scope,
      reason: reason.trim(),
      createdAtMs: createdAt,
      channelId: channelId,
      expiresAtMs: expiresAtMs,
      reference: reference,
    );
    if (!action.isStructurallyValid) return null;

    final protectedEnvelope = channelId == null
        ? null
        : state.protectedChannels[channelId.hex];
    if (protectedEnvelope != null) {
      if (kind != SpaceModerationKind.deleteMessage ||
          scope != SpaceModerationScope.channel ||
          reference?.kind != SpaceModerationReferenceKind.message ||
          reference?.channelId != channelId) {
        return null;
      }
      final clearChannel = await _materializeProtectedChannel(
        bundle,
        state,
        protectedEnvelope,
      );
      if (clearChannel == null ||
          clearChannel.channel.access != SpaceChannelAccess.restricted ||
          clearChannel.channel.kind != SpaceChannelKind.text ||
          clearChannel.channel.archived) {
        return null;
      }
    }

    if (reference != null) {
      final exists = switch (reference.kind) {
        SpaceModerationReferenceKind.message => (await messagesOf(
          spaceId,
          channelId: reference.channelId,
        )).any((message) => message.ref == reference.contentId),
        SpaceModerationReferenceKind.spacePost => (await postsOf(
          spaceId,
        )).any((post) => post.postId == reference.contentId),
        SpaceModerationReferenceKind.spacePostComment =>
          (await _messagesOfBundle(
            bundle,
            includeSpacePostComments: true,
            applyLocalRetention: false,
          )).any(
            (message) =>
                message.spacePostId != null &&
                message.editOf == null &&
                message.deleteOf == null &&
                message.ref == reference.contentId,
          ),
      };
      if (!exists) return null;
    }
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      _signer.selfId,
    );
    if (link.blocked) return null;
    Future<String?> committedActionId() async {
      final committed = await load(spaceId);
      if (committed == null) return null;
      for (final entry in committed.control.reversed) {
        if (entry.op == ControlOp.moderate &&
            entry.author == _signer.selfId &&
            entry.createdAtMs == createdAt) {
          return '${entry.author.hex}:${entry.seq}';
        }
      }
      return null;
    }

    if (protectedEnvelope != null) {
      final key =
          bundle.localChannelEpochKeys[_channelKeyId(
            protectedEnvelope.channelId,
            protectedEnvelope.channelEpoch,
          )];
      if (key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            protectedEnvelope.channelId,
            protectedEnvelope.channelEpoch,
            key,
          )) {
        return null;
      }
      Uint8List? clear;
      try {
        clear = Uint8List.fromList(utf8.encode(jsonEncode(action.toJson())));
        final encrypted = await encryptSpaceChannelModerationPayload(
          spaceId: spaceId,
          channelId: protectedEnvelope.channelId,
          channelEpoch: protectedEnvelope.channelEpoch,
          author: _signer.selfId,
          seq: link.seq,
          prevHash: link.prevHash,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          clearText: clear,
          channelKey: key,
        );
        final applied = await _addControlOp(
          spaceId,
          ControlOp.moderate,
          channelModeration: SpaceChannelModerationEnvelope(
            spaceId: spaceId,
            channelId: protectedEnvelope.channelId,
            channelEpoch: protectedEnvelope.channelEpoch,
            encryptedAction: encrypted,
          ),
          createdAtMs: createdAt,
        );
        return applied ? await committedActionId() : null;
      } catch (_) {
        return null;
      } finally {
        clear?.fillRange(0, clear.length, 0);
      }
    }
    final applied = await _addControlOp(
      spaceId,
      ControlOp.moderate,
      target: target,
      moderationAction: action,
      createdAtMs: createdAt,
    );
    // A membership-removing moderation action may atomically prepend one or
    // more protected-channel ACL/key revisions. Those rows consume author
    // sequence numbers, so the preflight [link] is not necessarily the
    // committed moderation id. Resolve the signed row after the single durable
    // write; appeals and audit navigation must bind to its actual sequence.
    return applied ? await committedActionId() : null;
  });

  /// Revoke a reversible moderation action. Content removals are deliberately
  /// irreversible; a moderator must publish new content instead of making an
  /// old signed deletion disappear. Revoking a ban only permits a later
  /// consent/invite flow — it never silently restores membership or old keys.
  Future<bool> revokeSpaceModeration(
    NodeId spaceId,
    String actionId, {
    required String reason,
  }) => _serialized(spaceId, () async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final record = state.moderationRecords[actionId];
    if (record == null || record.revokedAtMs != null) return false;
    if ({
      SpaceModerationKind.deleteMessage,
      SpaceModerationKind.deletePost,
    }.contains(record.action.kind)) {
      return false;
    }
    final normalized = reason.trim();
    final revokedAt = _now();
    final revocation = SpaceModerationRevocation(
      actionAuthor: record.actor,
      actionSeq: record.actionSeq,
      reason: normalized,
      revokedAtMs: revokedAt,
    );
    if (!revocation.isStructurallyValid) return false;
    return _addControlOp(
      spaceId,
      ControlOp.revokeModeration,
      target: record.action.target,
      moderationRevocation: revocation,
      createdAtMs: revokedAt,
    );
  });

  Future<List<SpaceModerationRecord>> spaceModerationAudit(
    NodeId spaceId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const [];
    }
    return _moderationRecordsOfBundle(bundle, state);
  }

  /// Move a Space through one owner-signed causal lifecycle transition.
  /// Group chats deliberately have no equivalent operation: their local
  /// conversation archive remains a per-device preference.
  Future<bool> _setSpaceLifecycle(
    NodeId spaceId,
    SpaceLifecycleState targetState, {
    Duration recoveryPeriod = kSpaceDeletionRecoveryPeriod,
  }) => _serialized(spaceId, () async {
    final observationType = switch (targetState) {
      SpaceLifecycleState.active => SpaceObservationType.spaceRestored,
      SpaceLifecycleState.archived => SpaceObservationType.spaceArchived,
      SpaceLifecycleState.deleted => SpaceObservationType.spaceDeleted,
    };
    bool finish(
      bool value, {
      SpaceObservationReason? reason,
      bool noOp = false,
    }) {
      _observeSpace(
        observationType,
        noOp
            ? SpaceObservationOutcome.noOp
            : value
            ? SpaceObservationOutcome.succeeded
            : SpaceObservationOutcome.rejected,
        reason: reason,
      );
      return value;
    }

    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) {
      return finish(false, reason: SpaceObservationReason.notFound);
    }
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    );
    final state = folded.state;
    if (state.lifecycleState == targetState) return finish(true, noOp: true);
    final operation = switch (targetState) {
      SpaceLifecycleState.active => ControlOp.restoreSpace,
      SpaceLifecycleState.archived => ControlOp.archiveSpace,
      SpaceLifecycleState.deleted => ControlOp.deleteSpace,
    };
    if (!SpaceAcl(state).allowsControl(_signer.selfId, operation)) {
      _observeSpace(
        SpaceObservationType.aclDenied,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.permissionDenied,
      );
      return finish(false, reason: SpaceObservationReason.permissionDenied);
    }
    if ((targetState == SpaceLifecycleState.archived && !state.isActive) ||
        (targetState == SpaceLifecycleState.active && state.isActive) ||
        (targetState == SpaceLifecycleState.deleted && state.isDeleted) ||
        recoveryPeriod <= Duration.zero ||
        recoveryPeriod > kSpaceDeletionRecoveryMax) {
      return finish(false, reason: SpaceObservationReason.invalidState);
    }
    final checkpoint = _controlCheckpoint(folded.accepted);
    if (checkpoint == null) {
      return finish(false, reason: SpaceObservationReason.conflict);
    }
    final previous = state.lifecycleTransition;
    final closingFromActive =
        targetState != SpaceLifecycleState.active && state.isActive;
    final messageHeads = closingFromActive
        ? _messageLifecycleHeads(bundle)
        : previous?.messageHeads;
    final postHeads = closingFromActive
        ? _postLifecycleHeads(bundle)
        : previous?.postHeads;
    final reactionHeads = closingFromActive
        ? _reactionLifecycleHeads(bundle)
        : previous?.reactionHeads;
    if (messageHeads == null || postHeads == null || reactionHeads == null) {
      return finish(false, reason: SpaceObservationReason.conflict);
    }
    final changedAt = _now();
    final recoveryDeadline = switch (targetState) {
      SpaceLifecycleState.deleted => changedAt + recoveryPeriod.inMilliseconds,
      SpaceLifecycleState.active when state.isDeleted =>
        previous?.recoveryDeadlineMs,
      _ => null,
    };
    final transition = SpaceLifecycleTransition(
      spaceId: spaceId,
      state: targetState,
      previousTransitionHash: state.lifecycleTransitionHash ?? '',
      controlCheckpoint: checkpoint,
      contentPolicyVersion: targetState != SpaceLifecycleState.active
          ? state.policyVersion
          : state.policyVersion + 1,
      messageHeads: messageHeads,
      postHeads: postHeads,
      reactionHeads: reactionHeads,
      changedAtMs: changedAt,
      recoveryDeadlineMs: recoveryDeadline,
    );
    if (!transition.isStructurallyValid) {
      return finish(false, reason: SpaceObservationReason.invalidState);
    }
    final applied = await _addControlOp(
      spaceId,
      operation,
      lifecycleTransition: transition,
      createdAtMs: changedAt,
    );
    return finish(
      applied,
      reason: applied ? null : SpaceObservationReason.conflict,
    );
  });

  Future<bool> setSpaceArchived(NodeId spaceId, bool archived) =>
      _setSpaceLifecycle(
        spaceId,
        archived ? SpaceLifecycleState.archived : SpaceLifecycleState.active,
      );

  Future<bool> archiveSpace(NodeId spaceId) => setSpaceArchived(spaceId, true);

  Future<bool> deleteSpace(
    NodeId spaceId, {
    Duration recoveryPeriod = kSpaceDeletionRecoveryPeriod,
  }) => _setSpaceLifecycle(
    spaceId,
    SpaceLifecycleState.deleted,
    recoveryPeriod: recoveryPeriod,
  );

  Future<bool> restoreSpace(NodeId spaceId) =>
      _setSpaceLifecycle(spaceId, SpaceLifecycleState.active);

  /// Atomically move the single effective owner role to an existing member.
  /// The immutable manifest owner remains the genesis signature root; it is
  /// deliberately not rewritten or re-signed during lifecycle operations.
  Future<bool> transferSpaceOwnership(NodeId spaceId, NodeId nextOwner) =>
      _serialized(spaceId, () async {
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        return _addControlOp(
          spaceId,
          ControlOp.transferOwnership,
          target: nextOwner,
        );
      });

  /// Leave [groupId]: append a signed `leave` op (removes only us), tell the
  /// remaining members, and let [listGroups] hide it (the fold drops us). Idempotent
  /// if we already aren't a member; false for the owner (who cannot leave, v1).
  Future<bool> leaveGroup(NodeId groupId) =>
      _serialized(groupId, () => _leaveGroup(groupId));

  Future<bool> _leaveGroup(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return false;
    if (b.manifest.name == kDeviceGroupName) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final me = state.memberOf(_signer.selfId);
    if (me == null) return true; // already gone
    if (!SpaceAcl(state).allowsControl(_signer.selfId, ControlOp.leave)) {
      return false;
    }
    final link = _nextControlLink(b.manifest, b.control, _signer.selfId);
    if (link.blocked) return false;
    final unsigned = ControlEntry(
      version: b.manifest.isSpace ? 3 : 2,
      groupId: groupId,
      author: _signer.selfId,
      seq: link.seq,
      prevHash: link.prevHash,
      op: ControlOp.leave,
      target: null,
      role: null,
      policyVersion: state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
      postBoundary: b.manifest.isSpace
          ? _postBoundaryFor(b, _signer.selfId)
          : null,
    );
    final signed = _signer.signControl(unsigned);
    final candidate = [...b.control, signed];
    final folded = foldControlLog(
      owner: b.manifest.owner,
      entries: candidate,
      verify: (e) => _validControlFor(b.manifest, e),
    );
    if (folded.rejected.any(
      (e) => e.author == signed.author && e.seq == signed.seq,
    )) {
      return false;
    }
    await _save(b.copyWith(control: candidate), notify: !b.manifest.isSpace);
    if (b.manifest.isSpace) _invalidateFeedAccess();
    // Tell the members who remain (broadcastDelta folds AFTER the leave, so it
    // fans out to them and never to us). They drop us from their roster.
    await broadcastDelta(groupId, control: [signed]);
    return true;
  }

  /// Post a message to [groupId]. Rejected (returns false) if we are not a
  /// non-muted member. An optional inline [attachment] rides inside the signed
  /// message (groups media brick 1) — no separate content fetch.
  Future<bool> postMessage(
    NodeId groupId,
    String body, {
    NodeId? channelId,
    MediaObject? attachment,
    String? replyTo,
    List<InlineCustomEmoji> customEmoji = const [],
    // Test/repro-only escape hatch: append WITHOUT the delta fanout —
    // simulates a delta lost in transit (total-outage class), so the
    // gap-fill path has a deterministic stand target.
    bool broadcast = true,
  }) => _serialized(
    groupId,
    () => _postMessage(
      groupId,
      body,
      channelId: channelId,
      attachment: attachment,
      replyTo: replyTo,
      customEmoji: customEmoji,
      broadcast: broadcast,
    ),
  );

  /// Add a comment to one visible root publication. The row uses the
  /// existing signed message log and Space epoch, but its scope is the post
  /// root rather than a channel, so neither Chats nor channel history sees it.
  Future<bool> commentOnSpacePost(
    NodeId spaceId,
    String postId,
    String body, {
    String? replyTo,
    MediaObject? media,
    bool publiclyVisible = false,
    bool broadcast = true,
  }) {
    final normalized = body.trim();
    if ((normalized.isEmpty && media == null) ||
        (media != null &&
            (media.inlinePreviewB64 != null ||
                !media.isReferenceStructurallyValid)) ||
        utf8.encode(normalized).length > kSpacePostCommentMaxBytes) {
      return Future.value(false);
    }
    return _serialized(
      spaceId,
      () => _postMessage(
        spaceId,
        normalized,
        spacePostId: postId,
        attachment: media,
        replyTo: replyTo,
        publiclyVisible: publiclyVisible,
        broadcast: broadcast,
      ),
    );
  }

  /// Append an encrypted immutable revision for one of our own comments.
  /// The original row remains the stable reply target and audit record.
  Future<bool> editSpacePostComment(
    NodeId spaceId,
    String postId,
    String commentRef,
    String body, {
    bool broadcast = true,
  }) {
    final normalized = body.trim();
    if (!_spacePostIdPattern.hasMatch(commentRef) ||
        utf8.encode(normalized).length > kSpacePostCommentMaxBytes) {
      return Future.value(false);
    }
    return _serialized(
      spaceId,
      () => _postMessage(
        spaceId,
        normalized,
        spacePostId: postId,
        editOf: commentRef,
        broadcast: broadcast,
      ),
    );
  }

  /// Append an encrypted immutable tombstone for one of our own comments.
  ///
  /// If the root was explicitly public, the same durable write also appends
  /// its separately author-signed public delete record. The private target
  /// remains inside AEAD cleartext, so non-members cannot correlate the
  /// member-log tombstone with the public statement.
  Future<bool> deleteSpacePostComment(
    NodeId spaceId,
    String postId,
    String commentRef, {
    bool broadcast = true,
  }) {
    if (!_spacePostIdPattern.hasMatch(commentRef)) {
      return Future.value(false);
    }
    return _serialized(
      spaceId,
      () => _postMessage(
        spaceId,
        '',
        spacePostId: postId,
        deleteOf: commentRef,
        broadcast: broadcast,
      ),
    );
  }

  Future<bool> _postMessage(
    NodeId groupId,
    String body, {
    NodeId? channelId,
    String? spacePostId,
    MediaObject? attachment,
    String? replyTo,
    String? editOf,
    String? deleteOf,
    List<InlineCustomEmoji> customEmoji = const [],
    bool publiclyVisible = false,
    bool broadcast = true,
  }) async {
    var effectiveAttachment = attachment;
    var publishPublicComment = publiclyVisible;
    if (!isValidInlineCustomEmoji(body, customEmoji)) return false;
    if (editOf != null && deleteOf != null) return false;
    final mutationOf = editOf ?? deleteOf;
    if (mutationOf != null &&
        (spacePostId == null ||
            !_spacePostIdPattern.hasMatch(mutationOf) ||
            attachment != null ||
            replyTo != null ||
            customEmoji.isNotEmpty)) {
      return false;
    }
    if (deleteOf != null && body.isNotEmpty) return false;
    if (spacePostId != null &&
        editOf == null &&
        deleteOf == null &&
        body.trim().isEmpty &&
        attachment == null) {
      return false;
    }
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    NodeId? resolvedChannelId = channelId;
    SpaceChannelControlCleartext? protectedChannel;
    if (b.manifest.isSpace) {
      if (spacePostId != null) {
        final targetPost = (await _postsOfBundle(
          b,
        )).where((post) => post.postId == spacePostId).firstOrNull;
        if (resolvedChannelId != null ||
            !_spacePostIdPattern.hasMatch(spacePostId) ||
            targetPost == null) {
          return false;
        }
        if (mutationOf != null) {
          final separator = mutationOf.lastIndexOf(':');
          final targetSeq = separator < 0
              ? null
              : int.tryParse(mutationOf.substring(separator + 1));
          publishPublicComment =
              targetSeq != null &&
              b.publicComments.any(
                (comment) =>
                    comment.spaceId == groupId &&
                    comment.postId == spacePostId &&
                    comment.author == _signer.selfId &&
                    comment.seq == targetSeq &&
                    comment.operation == SpacePublicCommentOperation.create &&
                    comment.verify(_signer.verifyDetached),
              );
        }
        if (publishPublicComment &&
            (b.manifest.visibility != SpaceVisibility.public ||
                targetPost.visibility != SpacePostVisibility.public)) {
          return false;
        }
        if (attachment != null &&
            (attachment.inlinePreviewB64 != null ||
                !attachment.isReferenceStructurallyValid)) {
          return false;
        }
        final comments = replyTo == null && mutationOf == null
            ? const <SpacePostCommentView>[]
            : await spacePostCommentsOf(groupId, spacePostId);
        if (replyTo != null) {
          if (!_spacePostIdPattern.hasMatch(replyTo) ||
              !comments.any((comment) => comment.ref == replyTo)) {
            return false;
          }
          if (publishPublicComment &&
              !b.publicComments.any(
                (comment) =>
                    comment.spaceId == groupId &&
                    comment.postId == spacePostId &&
                    comment.ref == replyTo &&
                    comment.operation == SpacePublicCommentOperation.create &&
                    comment.verify(_signer.verifyDetached),
              )) {
            return false;
          }
        }
        if (mutationOf != null) {
          final target = comments
              .where((comment) => comment.ref == mutationOf)
              .firstOrNull;
          if (target == null ||
              target.author != _signer.selfId ||
              (editOf != null &&
                  body.trim().isEmpty &&
                  target.attachment == null)) {
            return false;
          }
        }
      } else {
        resolvedChannelId ??= state.channels.values
            .where(
              (channel) =>
                  channel.kind == SpaceChannelKind.text &&
                  channel.isDefault &&
                  !channel.archived,
            )
            .firstOrNull
            ?.channelId;
        final protected = await _protectedChannelsOf(b, state);
        protectedChannel = resolvedChannelId == null
            ? null
            : protected[resolvedChannelId.hex];
        final channel = resolvedChannelId == null
            ? null
            : state.channels[resolvedChannelId.hex] ??
                  protectedChannel?.channel;
        if (channel == null ||
            channel.kind != SpaceChannelKind.text ||
            channel.archived) {
          return false;
        }
        if (protectedChannel != null && attachment != null) {
          effectiveAttachment = _protectedMediaReference(attachment);
          if (effectiveAttachment == null) return false;
        }
      }
    } else if (resolvedChannelId != null || spacePostId != null) {
      return false;
    }
    if (!SpaceAcl(state).allows(
      _signer.selfId,
      SpacePermission.publishMessages,
      channelId: resolvedChannelId,
    )) {
      return false;
    }
    final descriptor = state.epochDescriptor;
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final key = descriptor == null ? null : b.localEpochKeys[state.epoch];
    if (spacePostId != null &&
        (descriptor == null ||
            key == null ||
            !_validLocalEpochKey(b.manifest, b.control, state.epoch, key))) {
      // A discussion is member-private even when its root publication is
      // public. Never downgrade it to a clear legacy row when epoch material
      // is unavailable.
      return false;
    }
    final lifecycleGeneration = b.manifest.isSpace
        ? state.lifecycleTransitionHash
        : null;
    final scopeBase = b.manifest.isSpace
        ? spacePostId == null
              ? resolvedChannelId!.hex
              : 'post:$spacePostId'
        : 'group';
    final encryptionScope = protectedChannel != null
        ? '$scopeBase|channelEpoch:'
              '${state.protectedChannels[resolvedChannelId!.hex]?.channelEpoch}'
        : descriptor != null && key != null
        ? '$scopeBase|membershipEpoch:${state.epoch}'
        : '$scopeBase|clear';
    final targetScope =
        '$encryptionScope${lifecycleGeneration == null ? '' : '|lifecycle:$lifecycleGeneration'}';
    final retainedSelf = _retainedMessageRows(
      b.manifest,
      b.messages,
    ).where((message) => message.author == _signer.selfId).toList();
    if (_messageForks(
      b.manifest,
      retainedSelf,
    ).containsKey('$targetScope|${_signer.selfId.hex}')) {
      return false;
    }
    final canonicalSelf = _canonicalMessageRows(
      b.manifest,
      retainedSelf,
    ).where((message) => message.author == _signer.selfId).toList();
    final scopedSelf = canonicalSelf
        .where(
          (message) => _messageChainScope(b.manifest, message) == targetScope,
        )
        .toList();
    final selfScopeCut =
        b.retentionCuts[retentionCutKey(targetScope, _signer.selfId)];
    final acceptedScope = _acceptedMessageChain(
      b.manifest,
      canonicalSelf,
      _signer.selfId,
      targetScope,
      cut: selfScopeCut,
    );
    if (acceptedScope.length != scopedSelf.length) {
      // Never author on top of a forked or broken local suffix. Gap-fill must
      // first recover the exact predecessor selected by the signed chain.
      return false;
    }
    var mySeq = _nextSeq(retainedSelf.map((message) => message.seq));
    for (final cut in b.retentionCuts.values) {
      // Physically deleted own rows must never free their sequence numbers:
      // a reused (author, seq) would read as fork evidence on peers that
      // still hold the retired row.
      if (cut.author == _signer.selfId && cut.throughSeq >= mySeq) {
        mySeq = cut.throughSeq + 1;
      }
    }
    // Sovereign device groups are compacted LWW state logs, not user history:
    // removing superseded rows is intentional there, so they retain the
    // legacy unchained shape until that CRDT gets its own checkpoint protocol.
    final prevHash = b.manifest.isSovereignDevice || acceptedScope.isEmpty
        ? ''
        : groupMessageHash(acceptedScope.last);
    if (protectedChannel == null &&
        encryptionEstablished &&
        (descriptor == null ||
            key == null ||
            !_validLocalEpochKey(b.manifest, b.control, state.epoch, key))) {
      return false;
    }
    final createdAt = _now();
    late final GroupMessage unsigned;
    if (protectedChannel != null) {
      final opaque = state.protectedChannels[resolvedChannelId!.hex];
      final channelKey = opaque == null
          ? null
          : b.localChannelEpochKeys[_channelKeyId(
              opaque.channelId,
              opaque.channelEpoch,
            )];
      if (opaque == null ||
          channelKey == null ||
          !_validLocalChannelEpochKey(
            b.manifest,
            b.control,
            opaque.channelId,
            opaque.channelEpoch,
            channelKey,
          )) {
        return false;
      }
      final clear = GroupMessageCleartext(
        body: body,
        attachment: effectiveAttachment,
        replyTo: replyTo,
        customEmoji: customEmoji,
      ).encode();
      try {
        final encrypted = await encryptSpaceChannelMessagePayload(
          spaceId: groupId,
          channelId: opaque.channelId,
          channelEpoch: opaque.channelEpoch,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          clearText: clear,
          channelKey: channelKey,
        );
        unsigned = GroupMessage(
          groupId: groupId,
          channelId: opaque.channelId,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          body: '',
          version: lifecycleGeneration == null ? 3 : 6,
          channelEpoch: opaque.channelEpoch,
          encryptedPayload: encrypted,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
          lifecycleGeneration: lifecycleGeneration,
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else if (descriptor != null && key != null) {
      final clear = GroupMessageCleartext(
        body: body,
        attachment: effectiveAttachment,
        replyTo: replyTo,
        editOf: editOf,
        deleteOf: deleteOf,
        customEmoji: customEmoji,
      ).encode();
      try {
        final encrypted = await encryptGroupPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          clearText: clear,
          epochKey: key,
        );
        unsigned = GroupMessage(
          groupId: groupId,
          channelId: resolvedChannelId,
          spacePostId: spacePostId,
          author: _signer.selfId,
          seq: mySeq,
          prevHash: prevHash,
          body: '',
          version: lifecycleGeneration == null ? 2 : 5,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          policyVersion: state.policyVersion,
          createdAtMs: createdAt,
          signature: Uint8List(0),
          lifecycleGeneration: lifecycleGeneration,
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else {
      unsigned = GroupMessage(
        groupId: groupId,
        channelId: resolvedChannelId,
        spacePostId: spacePostId,
        author: _signer.selfId,
        seq: mySeq,
        prevHash: prevHash,
        body: body,
        policyVersion: state.policyVersion,
        createdAtMs: createdAt,
        signature: Uint8List(0),
        attachment: effectiveAttachment,
        replyTo: replyTo,
        editOf: editOf,
        customEmoji: customEmoji,
        version: lifecycleGeneration == null ? 1 : 4,
        lifecycleGeneration: lifecycleGeneration,
      );
    }
    final signed = _signer.signMessage(unsigned);
    SpacePublicComment? publicComment;
    if (publishPublicComment) {
      final lifecycle = lifecycleGeneration ?? _legacyPostGeneration(groupId);
      final postId = spacePostId;
      if (postId == null) return false;
      final chain = _publicCommentChain(b, postId, _signer.selfId);
      if (chain == null) return false;
      final operation = deleteOf != null
          ? SpacePublicCommentOperation.delete
          : editOf != null
          ? SpacePublicCommentOperation.edit
          : SpacePublicCommentOperation.create;
      final separator = mutationOf?.lastIndexOf(':') ?? -1;
      final targetSeq = separator < 0
          ? null
          : int.tryParse(mutationOf!.substring(separator + 1));
      final unsignedPublic = SpacePublicComment(
        spaceId: groupId,
        postId: postId,
        author: _signer.selfId,
        seq: signed.seq,
        prevHash: chain.isEmpty ? '' : chain.last.recordHash,
        operation: operation,
        targetSeq: targetSeq,
        body: operation == SpacePublicCommentOperation.delete ? '' : body,
        replyTo: operation == SpacePublicCommentOperation.create
            ? replyTo
            : null,
        media: operation == SpacePublicCommentOperation.create
            ? effectiveAttachment
            : null,
        lifecycleGeneration: lifecycle,
        createdAtMs: createdAt,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      final detached = _signer.signDetached(unsignedPublic.canonicalBytes());
      publicComment = unsignedPublic.withSignature(
        detached.signature,
        detached.publicKey,
      );
      if (!publicComment.verify(_signer.verifyDetached)) return false;
    }
    await _save(
      b.copyWith(
        messages: [...b.messages, signed],
        publicComments: [...b.publicComments, ?publicComment],
      ),
    );
    // Ship only the NEW message (delta), not the whole log — a post to a group
    // that already holds an image must not re-chunk that image over the wire.
    if (broadcast) {
      unawaited(
        broadcastDelta(
          groupId,
          messages: [signed],
          publicComments: [?publicComment],
        ),
      );
    }
    return true;
  }

  /// Protected-channel messages never carry a legacy inline payload. Convert
  /// an existing content-path attachment into the strict reference codec and
  /// let the channel AEAD encrypt its metadata; a missing/non-hash CID remains
  /// fail-closed. This also drops legacy thumbnails so every protected media
  /// byte is obtained through the separately authorized scoped content path.
  MediaObject? _protectedMediaReference(MediaObject attachment) {
    if (attachment.inlinePreviewB64 == null &&
        attachment.isReferenceStructurallyValid) {
      return attachment;
    }
    final contentId = attachment.contentId;
    if (contentId == null) return null;
    final duration =
        attachment.durationMs ??
        (attachment.kind == 'voice' || attachment.kind == 'vnote'
            ? attachment.width
            : null);
    final reference = MediaObject(
      kind: attachment.kind,
      contentId: contentId,
      name: attachment.name,
      mimeType: attachment.mimeType,
      size: attachment.size,
      width: attachment.width,
      height: attachment.height,
      durationMs: duration,
    );
    return reference.isReferenceStructurallyValid ? reference : null;
  }

  String _spacePostDraftKey(NodeId spaceId) =>
      'space.post-draft.v1:${spaceId.hex}';

  Future<bool> _canKeepSpacePostDraft(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    return SpaceAcl(state).allows(_signer.selfId, SpacePermission.view);
  }

  /// Load this identity's local draft for [spaceId]. The encrypted blob is
  /// deliberately outside the signed/P2P bundle and is invisible after access
  /// is revoked, even if stale local bytes remain until storage maintenance.
  Future<SpacePostDraft?> spacePostDraft(NodeId spaceId) =>
      _serializeSpacePostDrafts(() async {
        try {
          if (!await _canKeepSpacePostDraft(spaceId)) return null;
          final bytes = await _storage.loadFile(_spacePostDraftKey(spaceId));
          if (bytes == null || bytes.isEmpty) {
            devLog(() => 'xVeil[spaces]: local post draft is not stored');
            return null;
          }
          final draft = SpacePostDraft.fromJson(
            jsonDecode(utf8.decode(bytes, allowMalformed: false)),
            spaceId,
          );
          if (draft == null) {
            devLog(() => 'xVeil[spaces]: ignored malformed local post draft');
          }
          return draft;
        } catch (_) {
          // Storage/corruption must not block opening the publication list.
          devLog(() => 'xVeil[spaces]: failed to load local post draft');
          return null;
        }
      });

  /// Save an identity-local draft. Empty content means an explicit clear.
  /// Writes are serialized with clears so a delayed autosave cannot resurrect
  /// a draft after its signed publication succeeds.
  Future<bool> saveSpacePostDraft(
    NodeId spaceId, {
    required String title,
    required String body,
    required SpacePostType type,
    List<MediaObject> media = const [],
    int? scheduledAtMs,
  }) => _serializeSpacePostDrafts(() async {
    try {
      final draft = SpacePostDraft(
        spaceId: spaceId,
        title: title,
        body: body,
        type: type,
        updatedAtMs: _now(),
        media: List<MediaObject>.unmodifiable(media),
        scheduledAtMs: scheduledAtMs,
      );
      if (!draft.isStructurallyValid ||
          !await _canKeepSpacePostDraft(spaceId)) {
        return false;
      }
      final key = _spacePostDraftKey(spaceId);
      if (!draft.hasContent) {
        await _storage.deleteStoredFile(key);
        return true;
      }
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(draft.toJson())));
      await _storage.storeFile(key, bytes, name: 'space-post-draft');
      return true;
    } catch (_) {
      devLog(() => 'xVeil[spaces]: failed to save local post draft');
      return false;
    }
  });

  Future<bool> clearSpacePostDraft(NodeId spaceId) =>
      _serializeSpacePostDrafts(() async {
        try {
          await _storage.deleteStoredFile(_spacePostDraftKey(spaceId));
          return true;
        } catch (_) {
          devLog(() => 'xVeil[spaces]: failed to clear local post draft');
          return false;
        }
      });

  String _scheduledSpacePostKey(String id) => 'space.scheduled-post.v1:$id';

  Future<List<String>> _scheduledSpacePostIndex() async {
    final raw = await _storage.getSetting(_scheduledSpacePostIndexSetting);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1 || value['ids'] is! List) {
        return const [];
      }
      final ids = <String>[];
      final seen = <String>{};
      for (final value in (value['ids'] as List).take(
        _maxScheduledSpacePosts,
      )) {
        if (value is String &&
            _scheduledSpacePostIdPattern.hasMatch(value) &&
            seen.add(value)) {
          ids.add(value);
        }
      }
      return ids;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _saveScheduledSpacePostIndex(Iterable<String> ids) =>
      _storage.putSetting(
        _scheduledSpacePostIndexSetting,
        jsonEncode({'v': 1, 'ids': ids.take(_maxScheduledSpacePosts).toList()}),
      );

  Future<ScheduledSpacePost?> _loadScheduledSpacePost(String id) async {
    if (!_scheduledSpacePostIdPattern.hasMatch(id)) return null;
    try {
      final bytes = await _storage.loadFile(_scheduledSpacePostKey(id));
      if (bytes == null || bytes.isEmpty) return null;
      return ScheduledSpacePost.fromJson(
        jsonDecode(utf8.decode(bytes, allowMalformed: false)),
        expectedId: id,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeScheduledSpacePost(ScheduledSpacePost post) async {
    await _storage.storeFile(
      _scheduledSpacePostKey(post.id),
      Uint8List.fromList(utf8.encode(jsonEncode(post.toJson()))),
      name: 'scheduled-space-post',
    );
  }

  Future<List<ScheduledSpacePost>> _indexedScheduledSpacePosts({
    bool repair = false,
  }) async {
    final ids = await _scheduledSpacePostIndex();
    final jobs = <ScheduledSpacePost>[];
    final validIds = <String>[];
    for (final id in ids) {
      final job = await _loadScheduledSpacePost(id);
      if (job == null) continue;
      jobs.add(job);
      validIds.add(id);
    }
    if (repair && !_listEquals(ids, validIds)) {
      await _saveScheduledSpacePostIndex(validIds);
    }
    return jobs;
  }

  Future<({String grant, String lifecycle, int policyVersion})?>
  _scheduledSpacePostAuthorization(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    );
    final state = folded.state;
    if (!state.isActive ||
        !SpaceAcl(state).allows(_signer.selfId, SpacePermission.publishPosts)) {
      return null;
    }
    final grant = _postGrantAt(
      bundle.manifest,
      folded.accepted,
      _signer.selfId,
    );
    if (grant == null) return null;
    return (
      grant: grant,
      lifecycle:
          state.lifecycleTransitionHash ?? _legacyPostGeneration(spaceId),
      policyVersion: state.policyVersion,
    );
  }

  bool _sameScheduledSpacePostContent(
    ScheduledSpacePost left,
    ScheduledSpacePost right,
  ) =>
      left.spaceId == right.spaceId &&
      left.scheduledAtMs == right.scheduledAtMs &&
      left.title == right.title &&
      left.body == right.body &&
      left.type == right.type &&
      jsonEncode([for (final item in left.media) item.toJson()]) ==
          jsonEncode([for (final item in right.media) item.toJson()]);

  /// Persist a future publication only inside this identity's encrypted
  /// container. Nothing is signed or advertised until the worker reaches the
  /// due time and revalidates the exact authority generation.
  Future<ScheduledSpacePost?> scheduleSpacePost(
    NodeId spaceId, {
    required String body,
    required int scheduledAtMs,
    String title = '',
    SpacePostType type = SpacePostType.post,
    List<MediaObject> media = const [],
  }) async {
    final result = await _serializeScheduledSpacePosts(() async {
      final queuedAt = _now();
      if (scheduledAtMs <= queuedAt ||
          scheduledAtMs > queuedAt + const Duration(days: 365).inMilliseconds) {
        return null;
      }
      final cleartext = SpacePostCleartext(
        title: title.trim(),
        body: body.trim(),
        media: List<MediaObject>.unmodifiable(media),
      );
      if (!cleartext.isStructurallyValid) return null;
      final authorization = await _scheduledSpacePostAuthorization(spaceId);
      if (authorization == null) return null;
      final candidate = ScheduledSpacePost(
        id: _newSpaceInviteId(),
        spaceId: spaceId,
        title: cleartext.title,
        body: cleartext.body,
        type: type,
        media: cleartext.media,
        queuedAtMs: queuedAt,
        scheduledAtMs: scheduledAtMs,
        membershipGrant: authorization.grant,
        lifecycleGeneration: authorization.lifecycle,
        policyVersion: authorization.policyVersion,
      );
      if (!candidate.isStructurallyValid) return null;
      final jobs = await _indexedScheduledSpacePosts(repair: true);
      for (final existing in jobs) {
        if (_sameScheduledSpacePostContent(existing, candidate)) {
          return existing;
        }
      }
      if (jobs.length >= _maxScheduledSpacePosts) return null;
      await _storeScheduledSpacePost(candidate);
      try {
        await _saveScheduledSpacePostIndex([
          ...jobs.map((job) => job.id),
          candidate.id,
        ]);
      } catch (_) {
        try {
          await _storage.deleteStoredFile(_scheduledSpacePostKey(candidate.id));
        } catch (_) {}
        rethrow;
      }
      changes.value++;
      return candidate;
    });
    if (result != null) _requestScheduledSpacePostMaintenance();
    return result;
  }

  Future<List<ScheduledSpacePost>> scheduledSpacePosts(NodeId spaceId) =>
      _serializeScheduledSpacePosts(() async {
        final jobs = await _indexedScheduledSpacePosts(repair: true);
        final result =
            jobs.where((job) => job.spaceId == spaceId).toList(growable: false)
              ..sort((left, right) {
                final due = left.scheduledAtMs.compareTo(right.scheduledAtMs);
                return due != 0 ? due : left.id.compareTo(right.id);
              });
        return List<ScheduledSpacePost>.unmodifiable(result);
      });

  Future<bool> cancelScheduledSpacePost(NodeId spaceId, String id) async {
    final removed = await _serializeScheduledSpacePosts(() async {
      final ids = await _scheduledSpacePostIndex();
      if (!ids.contains(id)) return false;
      final job = await _loadScheduledSpacePost(id);
      if (job == null || job.spaceId != spaceId) return false;
      await _saveScheduledSpacePostIndex(ids.where((value) => value != id));
      try {
        await _storage.deleteStoredFile(_scheduledSpacePostKey(id));
      } catch (_) {
        // The index is authoritative. A detached encrypted blob is inert and
        // can be reclaimed by storage maintenance without resurrecting work.
      }
      changes.value++;
      return true;
    });
    if (removed) _requestScheduledSpacePostMaintenance();
    return removed;
  }

  bool _scheduledAuthorizationMatches(
    ScheduledSpacePost job,
    ({String grant, String lifecycle, int policyVersion}) authorization,
  ) =>
      job.membershipGrant == authorization.grant &&
      job.lifecycleGeneration == authorization.lifecycle &&
      job.policyVersion == authorization.policyVersion;

  bool _publishedPostMatchesSchedule(
    SpacePostView view,
    ScheduledSpacePost job,
  ) {
    final publicationAt = job.publicationAtMs;
    if (publicationAt == null) return false;
    final root = view.root;
    return root.author == _signer.selfId &&
        root.operation == SpacePostOperation.publish &&
        root.createdAtMs == publicationAt &&
        root.publishedAtMs == publicationAt &&
        root.type == job.type &&
        root.title == job.title &&
        root.body == job.body &&
        jsonEncode([for (final item in root.media) item.toJson()]) ==
            jsonEncode([for (final item in job.media) item.toJson()]);
  }

  Future<bool> _scheduledPostAlreadyPublished(ScheduledSpacePost job) async {
    if (job.publicationAtMs == null) return false;
    final bundle = await load(job.spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final posts = await _postsOfBundle(bundle);
    return posts.any((view) => _publishedPostMatchesSchedule(view, job));
  }

  /// Execute due jobs in a bounded batch. Failed authorization or persistence
  /// is retained as an explicit failed item; it is never silently retried
  /// after a later rejoin or policy change.
  Future<ScheduledSpacePostSweep> runDueScheduledSpacePosts({
    int? nowMs,
    int limit = 16,
  }) => _serializeScheduledSpacePosts(() async {
    if (limit <= 0 || limit > _maxScheduledSpacePosts) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be 1..$_maxScheduledSpacePosts',
      );
    }
    final effectiveNow = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final jobs = await _indexedScheduledSpacePosts(repair: true);
    final ids = jobs.map((job) => job.id).toList();
    final removed = <String>{};
    var scanned = 0;
    var published = 0;
    var failed = 0;
    var reconciled = 0;
    for (final original in jobs) {
      if (scanned >= limit ||
          original.status != ScheduledSpacePostStatus.pending ||
          original.scheduledAtMs > effectiveNow) {
        continue;
      }
      scanned++;
      var job = original;
      final alreadyPublished = await _serialized(
        job.spaceId,
        () => _scheduledPostAlreadyPublished(job),
      );
      if (alreadyPublished) {
        removed.add(job.id);
        reconciled++;
        continue;
      }
      final publicationAt = effectiveNow < job.scheduledAtMs
          ? job.scheduledAtMs
          : effectiveNow;
      job = ScheduledSpacePost(
        id: job.id,
        spaceId: job.spaceId,
        title: job.title,
        body: job.body,
        type: job.type,
        media: job.media,
        queuedAtMs: job.queuedAtMs,
        scheduledAtMs: job.scheduledAtMs,
        membershipGrant: job.membershipGrant,
        lifecycleGeneration: job.lifecycleGeneration,
        policyVersion: job.policyVersion,
        publicationAtMs: publicationAt,
      );
      await _storeScheduledSpacePost(job);
      SpacePost? post;
      try {
        post = await _serialized(job.spaceId, () async {
          if (_disposed) return null;
          final authorization = await _scheduledSpacePostAuthorization(
            job.spaceId,
          );
          if (authorization == null ||
              !_scheduledAuthorizationMatches(job, authorization)) {
            return null;
          }
          return _publishSpacePost(
            job.spaceId,
            body: job.body,
            title: job.title,
            type: job.type,
            media: job.media,
            broadcast: true,
            createdAtMs: publicationAt,
            publishedAtMs: publicationAt,
          );
        });
      } catch (_) {
        post = null;
      }
      if (post != null) {
        removed.add(job.id);
        published++;
        continue;
      }
      if (_disposed) {
        // Lock/identity teardown must not turn an untouched due job into a
        // permanent failure. The next unlocked service instance catches up.
        continue;
      }
      // A storage implementation may report an error after its durable write
      // became visible. Re-read under the group gate before classifying the
      // job as failed, otherwise an explicit retry could duplicate a post
      // which was actually committed.
      final committedDespiteError = await _serialized(
        job.spaceId,
        () => _scheduledPostAlreadyPublished(job),
      );
      if (committedDespiteError) {
        removed.add(job.id);
        reconciled++;
        continue;
      }
      final attemptedAt = effectiveNow < publicationAt
          ? publicationAt
          : effectiveNow;
      final failedJob = ScheduledSpacePost(
        id: job.id,
        spaceId: job.spaceId,
        title: job.title,
        body: job.body,
        type: job.type,
        media: job.media,
        queuedAtMs: job.queuedAtMs,
        scheduledAtMs: job.scheduledAtMs,
        membershipGrant: job.membershipGrant,
        lifecycleGeneration: job.lifecycleGeneration,
        policyVersion: job.policyVersion,
        status: ScheduledSpacePostStatus.failed,
        publicationAtMs: publicationAt,
        lastAttemptAtMs: attemptedAt,
      );
      await _storeScheduledSpacePost(failedJob);
      failed++;
    }
    if (removed.isNotEmpty) {
      await _saveScheduledSpacePostIndex(
        ids.where((id) => !removed.contains(id)),
      );
      for (final id in removed) {
        try {
          await _storage.deleteStoredFile(_scheduledSpacePostKey(id));
        } catch (_) {}
      }
    }
    if (removed.isNotEmpty || failed > 0) changes.value++;
    return ScheduledSpacePostSweep(
      scanned: scanned,
      published: published,
      failed: failed,
      reconciled: reconciled,
    );
  });

  Future<bool> publishScheduledSpacePostNow(NodeId spaceId, String id) async {
    final dueAt = await _serializeScheduledSpacePosts(() async {
      final ids = await _scheduledSpacePostIndex();
      if (!ids.contains(id)) return null;
      final job = await _loadScheduledSpacePost(id);
      if (job == null || job.spaceId != spaceId) return null;
      final authorization = await _scheduledSpacePostAuthorization(spaceId);
      if (authorization == null) return null;
      final now = _now();
      final reset = ScheduledSpacePost(
        id: job.id,
        spaceId: job.spaceId,
        title: job.title,
        body: job.body,
        type: job.type,
        media: job.media,
        queuedAtMs: now,
        scheduledAtMs: now,
        membershipGrant: authorization.grant,
        lifecycleGeneration: authorization.lifecycle,
        policyVersion: authorization.policyVersion,
      );
      await _storeScheduledSpacePost(reset);
      return now;
    });
    if (dueAt == null) return false;
    await runDueScheduledSpacePosts(nowMs: dueAt);
    final remainsIndexed = await _serializeScheduledSpacePosts(
      () async => (await _scheduledSpacePostIndex()).contains(id),
    );
    _requestScheduledSpacePostMaintenance();
    return !remainsIndexed;
  }

  void startScheduledSpacePostMaintenance() {
    if (_scheduledSpacePostMaintenanceStarted || _disposed) return;
    _scheduledSpacePostMaintenanceStarted = true;
    _requestScheduledSpacePostMaintenance();
  }

  void _requestScheduledSpacePostMaintenance() {
    if (!_scheduledSpacePostMaintenanceStarted || _disposed) return;
    _scheduledSpacePostWakeGeneration++;
    _scheduledSpacePostTimer?.cancel();
    _scheduledSpacePostTimer = null;
    if (_scheduledSpacePostMaintenanceRunning) {
      _scheduledSpacePostWakeRequested = true;
      return;
    }
    unawaited(_runScheduledSpacePostMaintenance());
  }

  Future<void> _runScheduledSpacePostMaintenance() async {
    if (_scheduledSpacePostMaintenanceRunning || _disposed) return;
    _scheduledSpacePostMaintenanceRunning = true;
    try {
      await runDueScheduledSpacePosts();
    } catch (_) {
      devLog(() => 'xVeil[spaces]: scheduled publication maintenance failed');
    } finally {
      _scheduledSpacePostMaintenanceRunning = false;
    }
    if (_disposed) return;
    if (_scheduledSpacePostWakeRequested) {
      _scheduledSpacePostWakeRequested = false;
      _requestScheduledSpacePostMaintenance();
      return;
    }
    final wakeGeneration = _scheduledSpacePostWakeGeneration;
    await _armScheduledSpacePostTimer(wakeGeneration);
  }

  Future<void> _armScheduledSpacePostTimer(int wakeGeneration) async {
    if (_disposed || !_scheduledSpacePostMaintenanceStarted) return;
    final jobs = await _serializeScheduledSpacePosts(
      () => _indexedScheduledSpacePosts(repair: true),
    );
    int? nextAt;
    for (final job in jobs) {
      if (job.status != ScheduledSpacePostStatus.pending) continue;
      if (nextAt == null || job.scheduledAtMs < nextAt) {
        nextAt = job.scheduledAtMs;
      }
    }
    if (nextAt == null ||
        _disposed ||
        wakeGeneration != _scheduledSpacePostWakeGeneration) {
      return;
    }
    final remaining = nextAt - DateTime.now().millisecondsSinceEpoch;
    final delayMs = remaining <= 0
        ? 1
        : min(remaining, const Duration(hours: 24).inMilliseconds);
    _scheduledSpacePostTimer = Timer(
      Duration(milliseconds: delayMs),
      _requestScheduledSpacePostMaintenance,
    );
  }

  /// Publish one immutable Space feed row. Public Spaces produce signed
  /// cleartext rows suitable for a future non-member public-feed transport;
  /// private/secret Spaces encrypt the complete content with the current
  /// membership epoch. A draft is local UI state and never enters this log.
  Future<SpacePost?> publishSpacePost(
    NodeId spaceId, {
    required String body,
    String title = '',
    SpacePostType type = SpacePostType.post,
    List<MediaObject> media = const [],
    bool broadcast = true,
  }) => _serialized(
    spaceId,
    () => _publishSpacePost(
      spaceId,
      body: body,
      title: title,
      type: type,
      media: media,
      broadcast: broadcast,
    ),
  );

  Future<SpacePost?> _publishSpacePost(
    NodeId spaceId, {
    required String body,
    required String title,
    required SpacePostType type,
    required List<MediaObject> media,
    required bool broadcast,
    int? createdAtMs,
    int? publishedAtMs,
  }) async {
    final cleartext = SpacePostCleartext(
      title: title.trim(),
      body: body.trim(),
      media: List<MediaObject>.unmodifiable(media),
    );
    if (!cleartext.isStructurallyValid) return null;
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    final currentFold = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final state = currentFold.state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.publishPosts)) {
      _observeSpace(
        SpaceObservationType.aclDenied,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.permissionDenied,
      );
      _observeSpace(
        SpaceObservationType.postPublished,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.permissionDenied,
      );
      return null;
    }
    final lifecycleGeneration = state.lifecycleTransitionHash;
    final generationHash =
        lifecycleGeneration ?? _legacyPostGeneration(spaceId);
    final authored = _acceptedPostChain(
      spaceId,
      bundle.posts,
      _signer.selfId,
      generationHash: generationHash,
    );
    if (!_postMutationChainValid(authored)) return null;
    final acceptedHeadSeq = authored.isEmpty ? -1 : authored.last.seq;
    if (bundle.posts.any(
      (post) =>
          post.author == _signer.selfId &&
          _postGeneration(post) == generationHash &&
          _validPostFor(spaceId, post) &&
          post.seq > acceptedHeadSeq,
    )) {
      return null;
    }
    final checkpointResult = _ensurePostCheckpoint(
      bundle,
      currentFold,
      preferredCheckpointHash: authored.isEmpty
          ? null
          : authored.last.controlCheckpointHash,
    );
    if (checkpointResult == null) return null;
    final workingBundle = checkpointResult.bundle;
    final checkpointHash = controlEntryHash(checkpointResult.entry);
    final seq = _nextSeq(
      bundle.posts
          .where(
            (post) =>
                post.author == _signer.selfId && _validPostFor(spaceId, post),
          )
          .map((post) => post.seq),
    );
    final prevHash = authored.isEmpty ? '' : _spacePostHash(authored.last);
    final now = _now();
    final created = createdAtMs ?? now;
    final published = publishedAtMs ?? now;
    if (created < 0 ||
        published < created ||
        published > created + const Duration(days: 365).inMilliseconds) {
      return null;
    }
    final isPublic = bundle.manifest.visibility == SpaceVisibility.public;
    late final SpacePost unsigned;
    if (isPublic) {
      unsigned = SpacePost(
        spaceId: spaceId,
        author: _signer.selfId,
        seq: seq,
        prevHash: prevHash,
        type: type,
        visibility: SpacePostVisibility.public,
        title: cleartext.title,
        body: cleartext.body,
        media: cleartext.media,
        policyVersion: state.policyVersion,
        createdAtMs: created,
        publishedAtMs: published,
        version: lifecycleGeneration == null ? 5 : 9,
        controlCheckpointHash: checkpointHash,
        lifecycleGeneration: lifecycleGeneration,
        signature: Uint8List(0),
      );
    } else {
      final descriptor = state.epochDescriptor;
      final key = descriptor == null
          ? null
          : bundle.localEpochKeys[state.epoch];
      if (descriptor == null ||
          key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            state.epoch,
            key,
          )) {
        return null;
      }
      final encoded = cleartext.encode();
      try {
        final encrypted = await encryptSpacePostPayload(
          spaceId: spaceId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          postType: type.name,
          visibility: SpacePostVisibility.members.name,
          policyVersion: state.policyVersion,
          createdAtMs: created,
          publishedAtMs: published,
          controlCheckpointHash: checkpointHash,
          lifecycleGeneration: lifecycleGeneration ?? '',
          clearText: encoded,
          epochKey: key,
        );
        unsigned = SpacePost(
          spaceId: spaceId,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          type: type,
          visibility: SpacePostVisibility.members,
          title: '',
          body: '',
          policyVersion: state.policyVersion,
          createdAtMs: created,
          publishedAtMs: published,
          version: lifecycleGeneration == null ? 6 : 10,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          controlCheckpointHash: checkpointHash,
          lifecycleGeneration: lifecycleGeneration,
          signature: Uint8List(0),
        );
      } finally {
        encoded.fillRange(0, encoded.length, 0);
      }
    }
    final signed = _signer.signPost(unsigned);
    if (!_validPostFor(spaceId, signed)) return null;
    await _save(
      workingBundle.copyWith(posts: [...workingBundle.posts, signed]),
    );
    if (broadcast) {
      unawaited(
        broadcastDelta(
          spaceId,
          control: checkpointResult.created == null
              ? const []
              : [checkpointResult.created!],
          posts: [signed],
        ),
      );
    }
    _observeSpace(
      SpaceObservationType.postPublished,
      SpaceObservationOutcome.succeeded,
      amount: 1,
    );
    return signed.withDecryptedContent(cleartext);
  }

  /// Append an author-signed revision while preserving the original post id
  /// and chronological cursor. Only the author can address a root in their
  /// own linear chain; moderator removals use a future distinct operation.
  Future<SpacePostView?> editSpacePost(
    NodeId spaceId,
    String postId, {
    required String title,
    required String body,
    SpacePostType? type,
    List<MediaObject>? media,
    bool broadcast = true,
  }) => _serialized(spaceId, () async {
    final row = await _mutateSpacePost(
      spaceId,
      postId,
      operation: SpacePostOperation.edit,
      title: title,
      body: body,
      type: type,
      media: media,
      broadcast: broadcast,
    );
    if (row == null) return null;
    for (final post in await postsOf(spaceId)) {
      if (post.postId == postId && post.revisionId == row.postId) return post;
    }
    return null;
  });

  /// Append an irreversible author tombstone. The old signed rows remain as
  /// audit/fork evidence but disappear from feed and content grants.
  Future<bool> deleteSpacePost(
    NodeId spaceId,
    String postId, {
    bool broadcast = true,
  }) => _serialized(
    spaceId,
    () async =>
        await _mutateSpacePost(
          spaceId,
          postId,
          operation: SpacePostOperation.delete,
          title: '',
          body: '',
          broadcast: broadcast,
        ) !=
        null,
  );

  /// Pin or unpin one exact visible publication for the whole community.
  /// This is an admin control-log mutation, deliberately separate from the
  /// author's edit chain so moderators can manage another member's post
  /// without impersonating its author or rewriting its signed content.
  Future<bool> setSpacePostPinned(NodeId spaceId, String postId, bool pinned) =>
      _serialized(spaceId, () async {
        if (!_spacePostIdPattern.hasMatch(postId)) return false;
        final bundle = await load(spaceId);
        if (bundle == null || !bundle.manifest.isSpace) return false;
        final fold = foldControlLog(
          owner: bundle.manifest.owner,
          entries: bundle.control,
          verify: (entry) => _validControlFor(bundle.manifest, entry),
          initialName: bundle.manifest.name,
          initialDescription: bundle.manifest.description ?? '',
        );
        if (!SpaceAcl(
          fold.state,
        ).allows(_signer.selfId, SpacePermission.managePosts)) {
          return false;
        }
        SpacePostView? target;
        for (final post in await _postsOfBundle(bundle)) {
          if (post.postId == postId) {
            target = post;
            break;
          }
        }
        if (target == null) return false;
        if (target.pinned == pinned) return true;
        final changedAt = _now();
        final payload = SpacePostPin(
          spaceId: spaceId,
          postAuthor: target.author,
          postSeq: target.seq,
          rootHash: _spacePostHash(target.root),
          pinned: pinned,
          changedAtMs: changedAt,
        );
        return _addControlOp(
          spaceId,
          ControlOp.setPostPin,
          postPin: payload,
          createdAtMs: changedAt,
        );
      });

  Future<SpacePost?> _mutateSpacePost(
    NodeId spaceId,
    String postId, {
    required SpacePostOperation operation,
    required String title,
    required String body,
    SpacePostType? type,
    List<MediaObject>? media,
    required bool broadcast,
  }) async {
    if (operation == SpacePostOperation.publish) return null;
    final separator = postId.lastIndexOf(':');
    if (separator <= 0 || separator == postId.length - 1) return null;
    final targetAuthor = postId.substring(0, separator);
    final targetSeq = int.tryParse(postId.substring(separator + 1));
    if (targetAuthor != _signer.selfId.hex ||
        targetSeq == null ||
        targetSeq < 0) {
      return null;
    }
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return null;
    SpacePostView? target;
    for (final post in await _postsOfBundle(bundle)) {
      if (post.postId == postId) {
        target = post;
        break;
      }
    }
    if (target == null || target.author != _signer.selfId) return null;
    final cleartext = SpacePostCleartext(
      title: operation == SpacePostOperation.delete ? '' : title.trim(),
      body: operation == SpacePostOperation.delete ? '' : body.trim(),
      media: operation == SpacePostOperation.delete
          ? const []
          : List<MediaObject>.unmodifiable(media ?? target.media),
      isTombstone: operation == SpacePostOperation.delete,
    );
    if (!cleartext.isStructurallyValid) return null;
    final currentFold = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final state = currentFold.state;
    final requiredPermission = operation == SpacePostOperation.delete
        ? SpacePermission.view
        : SpacePermission.publishPosts;
    if (!SpaceAcl(state).allows(_signer.selfId, requiredPermission)) {
      return null;
    }
    final lifecycleGeneration = state.lifecycleTransitionHash;
    if (target.effective.lifecycleGeneration != lifecycleGeneration) {
      return null;
    }
    final generationHash =
        lifecycleGeneration ?? _legacyPostGeneration(spaceId);
    final authored = _acceptedPostChain(
      spaceId,
      bundle.posts,
      _signer.selfId,
      generationHash: generationHash,
    );
    if (!_postMutationChainValid(authored)) return null;
    final acceptedHeadSeq = authored.isEmpty ? -1 : authored.last.seq;
    if (bundle.posts.any(
      (post) =>
          post.author == _signer.selfId &&
          _postGeneration(post) == generationHash &&
          _validPostFor(spaceId, post) &&
          post.seq > acceptedHeadSeq,
    )) {
      return null;
    }
    final checkpointResult = _ensurePostCheckpoint(
      bundle,
      currentFold,
      preferredCheckpointHash: authored.isEmpty
          ? null
          : authored.last.controlCheckpointHash,
      removal: operation == SpacePostOperation.delete,
    );
    if (checkpointResult == null) return null;
    final checkpointHash = controlEntryHash(checkpointResult.entry);
    final seq = _nextSeq(
      bundle.posts
          .where(
            (post) =>
                post.author == _signer.selfId && _validPostFor(spaceId, post),
          )
          .map((post) => post.seq),
    );
    if (targetSeq >= seq) return null;
    final prevHash = authored.isEmpty ? '' : _spacePostHash(authored.last);
    final now = _now();
    final postType = type ?? target.type;
    late final SpacePost unsigned;
    if (bundle.manifest.visibility == SpaceVisibility.public) {
      unsigned = SpacePost(
        spaceId: spaceId,
        author: _signer.selfId,
        seq: seq,
        prevHash: prevHash,
        type: postType,
        visibility: SpacePostVisibility.public,
        title: cleartext.title,
        body: cleartext.body,
        media: cleartext.media,
        policyVersion: state.policyVersion,
        createdAtMs: now,
        publishedAtMs: now,
        version: lifecycleGeneration == null ? 7 : 9,
        controlCheckpointHash: checkpointHash,
        operation: operation,
        targetSeq: targetSeq,
        lifecycleGeneration: lifecycleGeneration,
        signature: Uint8List(0),
      );
    } else {
      final descriptor = state.epochDescriptor;
      final key = descriptor == null
          ? null
          : bundle.localEpochKeys[state.epoch];
      if (descriptor == null ||
          key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            state.epoch,
            key,
          )) {
        return null;
      }
      final encoded = cleartext.encode();
      try {
        final encrypted = await encryptSpacePostPayload(
          spaceId: spaceId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          postType: postType.name,
          visibility: SpacePostVisibility.members.name,
          policyVersion: state.policyVersion,
          createdAtMs: now,
          publishedAtMs: now,
          controlCheckpointHash: checkpointHash,
          postOperation: operation.name,
          targetSeq: targetSeq,
          lifecycleGeneration: lifecycleGeneration ?? '',
          clearText: encoded,
          epochKey: key,
        );
        unsigned = SpacePost(
          spaceId: spaceId,
          author: _signer.selfId,
          seq: seq,
          prevHash: prevHash,
          type: postType,
          visibility: SpacePostVisibility.members,
          title: '',
          body: '',
          policyVersion: state.policyVersion,
          createdAtMs: now,
          publishedAtMs: now,
          version: lifecycleGeneration == null ? 8 : 10,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          controlCheckpointHash: checkpointHash,
          operation: operation,
          targetSeq: targetSeq,
          lifecycleGeneration: lifecycleGeneration,
          signature: Uint8List(0),
        );
      } finally {
        encoded.fillRange(0, encoded.length, 0);
      }
    }
    final signed = _signer.signPost(unsigned);
    if (!_validPostFor(spaceId, signed)) return null;
    await _save(
      checkpointResult.bundle.copyWith(
        posts: [...checkpointResult.bundle.posts, signed],
      ),
    );
    if (broadcast) {
      unawaited(
        broadcastDelta(
          spaceId,
          control: checkpointResult.created == null
              ? const []
              : [checkpointResult.created!],
          posts: [signed],
        ),
      );
    }
    return signed.withDecryptedContent(cleartext);
  }

  ({GroupBundle bundle, ControlEntry entry, ControlEntry? created})?
  _ensurePostCheckpoint(
    GroupBundle bundle,
    GroupFoldResult currentFold, {
    String? preferredCheckpointHash,
    bool removal = false,
  }) {
    final currentGeneration = _postGrantAt(
      bundle.manifest,
      currentFold.accepted,
      _signer.selfId,
    );
    final currentAcl = SpaceAcl(currentFold.state);
    if (removal) {
      if (!currentAcl.allows(_signer.selfId, SpacePermission.view)) return null;
    } else if (currentGeneration == null) {
      return null;
    }
    const reuseScanMax = 8;
    final candidates = <ControlEntry>[];
    if (preferredCheckpointHash != null) {
      for (final entry in currentFold.accepted) {
        if (entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == preferredCheckpointHash) {
          candidates.add(entry);
          break;
        }
      }
    }
    for (final entry in currentFold.accepted.reversed) {
      if (candidates.length >= reuseScanMax) break;
      if (entry.op != ControlOp.checkpoint ||
          entry.policyVersion != currentFold.state.policyVersion ||
          candidates.any(
            (candidate) =>
                controlEntryHash(candidate) == controlEntryHash(entry),
          )) {
        continue;
      }
      candidates.add(entry);
    }
    for (final entry in candidates) {
      final historical = _foldAtControlCheckpoint(
        bundle.manifest,
        bundle.control,
        entry,
      );
      if (historical != null &&
          historical.state.policyVersion == currentFold.state.policyVersion &&
          SpaceAcl(historical.state).allows(
            _signer.selfId,
            removal ? SpacePermission.view : SpacePermission.publishPosts,
          ) &&
          (removal ||
              _postGrantAt(
                    bundle.manifest,
                    historical.accepted,
                    _signer.selfId,
                  ) ==
                  currentGeneration)) {
        return (bundle: bundle, entry: entry, created: null);
      }
    }

    final payload = _controlCheckpoint(currentFold.accepted);
    if (payload == null) return null;
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      _signer.selfId,
    );
    if (link.blocked) return null;
    final unsigned = ControlEntry(
      version: 4,
      groupId: bundle.manifest.groupId,
      author: _signer.selfId,
      seq: link.seq,
      prevHash: link.prevHash,
      op: ControlOp.checkpoint,
      target: null,
      role: null,
      controlCheckpoint: payload,
      policyVersion: currentFold.state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
    );
    final signed = _signer.signControl(unsigned);
    if (!_validControlFor(bundle.manifest, signed)) return null;
    final control = [...bundle.control, signed];
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final hash = controlEntryHash(signed);
    if (!folded.accepted.any((entry) => controlEntryHash(entry) == hash) ||
        _foldAtControlCheckpoint(bundle.manifest, control, signed) == null) {
      return null;
    }
    return (
      bundle: bundle.copyWith(control: control),
      entry: signed,
      created: signed,
    );
  }

  String _spacePostHash(SpacePost post) => crypto.sha256.convert([
    ...post.canonicalBytes(),
    ...post.signature,
  ]).toString();

  String _legacyPostGeneration(NodeId spaceId) => crypto.sha256
      .convert(
        utf8.encode('xveil.space-post-lifecycle.genesis.v1|${spaceId.hex}'),
      )
      .toString();

  String _postGeneration(SpacePost post) =>
      post.lifecycleGeneration ?? _legacyPostGeneration(post.spaceId);

  String _reactionHash(GroupReaction reaction) => crypto.sha256.convert([
    ...reaction.canonicalBytes(),
    ...reaction.signature,
  ]).toString();

  bool _validPublicCommentFor(NodeId spaceId, SpacePublicComment comment) =>
      comment.spaceId == spaceId && comment.verify(_signer.verifyDetached);

  bool _validPublicReactionFor(NodeId spaceId, SpacePublicReaction reaction) =>
      reaction.spaceId == spaceId && reaction.verify(_signer.verifyDetached);

  List<SpacePublicComment>? _publicCommentChain(
    GroupBundle bundle,
    String postId,
    NodeId author,
  ) {
    final chain = [
      for (final comment in bundle.publicComments)
        if (comment.author == author &&
            comment.postId == postId &&
            _validPublicCommentFor(bundle.manifest.groupId, comment))
          comment,
    ]..sort((left, right) => left.seq.compareTo(right.seq));
    for (var index = 0; index < chain.length; index++) {
      if ((index > 0 && chain[index].seq <= chain[index - 1].seq) ||
          (index == 0
              ? chain[index].prevHash.isNotEmpty
              : chain[index].prevHash != chain[index - 1].recordHash)) {
        return null;
      }
    }
    return chain;
  }

  List<SpacePublicReaction>? _publicReactionChain(
    GroupBundle bundle,
    String postId,
    NodeId author,
  ) {
    final chain = [
      for (final reaction in bundle.publicReactions)
        if (reaction.author == author &&
            reaction.postId == postId &&
            _validPublicReactionFor(bundle.manifest.groupId, reaction))
          reaction,
    ]..sort((left, right) => left.seq.compareTo(right.seq));
    for (var index = 0; index < chain.length; index++) {
      if ((index > 0 && chain[index].seq <= chain[index - 1].seq) ||
          (index == 0
              ? chain[index].prevHash.isNotEmpty
              : chain[index].prevHash != chain[index - 1].recordHash)) {
        return null;
      }
    }
    return chain;
  }

  String _spaceRepairFingerprint({
    required Iterable<ControlEntry> controls,
    required Iterable<GroupMessage> messages,
    required Iterable<GroupReaction> reactions,
    required Iterable<SpacePost> posts,
    Iterable<SpacePublicComment> publicComments = const [],
    Iterable<SpacePublicReaction> publicReactions = const [],
    required Iterable<GroupEpochRecipientEnvelope> epochEnvelopes,
    required Iterable<GroupEpochRecipientEnvelope> channelEpochEnvelopes,
  }) {
    String envelopeHash(GroupEpochRecipientEnvelope envelope) => crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode(_canonicalSpaceFrontierValue(envelope.toJson())),
          ),
        )
        .toString();

    final objectIds = <String>[
      for (final entry in controls) 'control:${controlEntryHash(entry)}',
      for (final message in messages) 'message:${groupMessageHash(message)}',
      for (final reaction in reactions) 'reaction:${_reactionHash(reaction)}',
      for (final post in posts) 'post:${_spacePostHash(post)}',
      for (final comment in publicComments)
        'publicComment:${comment.recordHash}',
      for (final reaction in publicReactions)
        'publicReaction:${reaction.recordHash}',
      for (final envelope in epochEnvelopes) 'epoch:${envelopeHash(envelope)}',
      for (final envelope in channelEpochEnvelopes)
        'channelEpoch:${envelopeHash(envelope)}',
    ]..sort();
    return crypto.sha256.convert(utf8.encode(objectIds.join('\n'))).toString();
  }

  String _reactionLifecycleScopeHash(GroupReaction reaction) => crypto.sha256
      .convert(
        utf8.encode(
          reaction.isChannelEncrypted
              ? 'xveil.space-reaction-lifecycle-scope.v1|channel|'
                    '${reaction.channelId!.hex}|${reaction.channelEpoch}'
              : reaction.isMembershipEncrypted
              ? 'xveil.space-reaction-lifecycle-scope.v1|membership|'
                    '${reaction.membershipEpoch}'
              : 'xveil.space-reaction-lifecycle-scope.v1|clear|'
                    '${reaction.targetKind.name}',
        ),
      )
      .toString();

  bool _reactionHeadMatches(
    SpaceReactionLifecycleHead head,
    GroupReaction reaction,
  ) =>
      head.generationHash == _reactionGeneration(reaction) &&
      head.author == reaction.author &&
      (head.scopeHash == null ||
          head.scopeHash == _reactionLifecycleScopeHash(reaction));

  String _reactionSyncScope(GroupReaction reaction) =>
      '${reaction.channelId!.hex}|channelEpoch:${reaction.channelEpoch}';

  String _legacyReactionGeneration(NodeId spaceId) => crypto.sha256
      .convert(
        utf8.encode('xveil.space-reaction-lifecycle.genesis.v1|${spaceId.hex}'),
      )
      .toString();

  String _reactionGeneration(GroupReaction reaction) =>
      reaction.lifecycleGeneration ??
      _legacyReactionGeneration(reaction.groupId);

  /// A message chain never crosses a visibility boundary. The channel (for a
  /// Space) and encryption epoch are both part of the scope: a new member who
  /// receives only the post-join epoch must not need an undisclosed historical
  /// predecessor, and a revoked restricted-channel member must not learn the
  /// next epoch's head through a shared sync vector.
  String _messageChainScope(GroupManifest manifest, GroupMessage message) {
    final channel = manifest.isSpace
        ? message.spacePostId == null
              ? (message.channelId ?? defaultSpaceChannelId(manifest.groupId))
                    .hex
              : 'post:${message.spacePostId}'
        : 'group';
    final encryption = message.isChannelEncrypted
        ? 'channelEpoch:${message.channelEpoch}'
        : message.isEncrypted
        ? 'membershipEpoch:${message.membershipEpoch}'
        : 'clear';
    final lifecycle = message.lifecycleGeneration;
    return '$channel|$encryption${lifecycle == null ? '' : '|lifecycle:$lifecycle'}';
  }

  /// Preserve every distinct valid signed row. Same-scope `(author, seq)`
  /// conflicts are evidence and must survive compaction/snapshot propagation;
  /// forgetting one branch would make the winner depend on arrival order.
  List<GroupMessage> _retainedMessageRows(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
  ) {
    final rows = <String, GroupMessage>{};
    for (final message in input) {
      if (!_validMessageFor(manifest.groupId, message)) continue;
      rows[groupMessageHash(message)] = message;
    }
    return rows.values.toList();
  }

  Map<String, ({int seq, Set<String> hashes})> _messageForks(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
  ) {
    final candidates = <String, Set<String>>{};
    final samples = <String, GroupMessage>{};
    for (final message in input) {
      if (!_validMessageFor(manifest.groupId, message)) continue;
      final scope = _messageChainScope(manifest, message);
      final identity = '$scope|${message.author.hex}:${message.seq}';
      candidates
          .putIfAbsent(identity, () => <String>{})
          .add(groupMessageHash(message));
      samples[identity] = message;
    }
    final forks = <String, ({int seq, Set<String> hashes})>{};
    for (final entry in candidates.entries) {
      if (entry.value.length <= 1) continue;
      final sample = samples[entry.key]!;
      final key =
          '${_messageChainScope(manifest, sample)}|${sample.author.hex}';
      final current = forks[key];
      if (current == null || sample.seq < current.seq) {
        forks[key] = (seq: sample.seq, hashes: Set.unmodifiable(entry.value));
      }
    }
    return forks;
  }

  /// Return valid rows outside an equivocated suffix in the same visibility
  /// scope. A fork in a restricted channel cannot suppress unrelated public
  /// channel history for members who are not allowed to learn that the hidden
  /// channel exists.
  List<GroupMessage> _canonicalMessageRows(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
  ) {
    final candidates = <String, Map<String, GroupMessage>>{};
    for (final message in input) {
      if (!_validMessageFor(manifest.groupId, message)) continue;
      final scope = _messageChainScope(manifest, message);
      final identity = '$scope|${message.author.hex}:${message.seq}';
      candidates.putIfAbsent(
        identity,
        () => <String, GroupMessage>{},
      )[groupMessageHash(message)] = message;
    }
    final forkedAt = <String, int>{};
    for (final distinct in candidates.values) {
      if (distinct.length <= 1) continue;
      final sample = distinct.values.first;
      final key =
          '${_messageChainScope(manifest, sample)}|${sample.author.hex}';
      final current = forkedAt[key];
      if (current == null || sample.seq < current) forkedAt[key] = sample.seq;
    }
    return [
      for (final distinct in candidates.values)
        if (distinct.length == 1)
          if (distinct.values.single.seq <
              (forkedAt['${_messageChainScope(manifest, distinct.values.single)}|'
                      '${distinct.values.single.author.hex}'] ??
                  (1 << 62)))
            distinct.values.single,
    ];
  }

  /// Fold one author's chain inside one visibility scope. Legacy rows used an
  /// empty `prevHash`; the first modern row commits to the exact terminal
  /// legacy row and starts strict mode. From that point a missing predecessor,
  /// downgrade to an empty link, or wrong hash hides the whole scoped suffix
  /// until anti-entropy supplies the exact missing row.
  List<GroupMessage> _acceptedMessageChain(
    GroupManifest manifest,
    Iterable<GroupMessage> input,
    NodeId author,
    String scope, {
    SpaceRetentionCut? cut,
  }) {
    final authored =
        _canonicalMessageRows(manifest, input)
            .where(
              (message) =>
                  message.author == author &&
                  _messageChainScope(manifest, message) == scope &&
                  // Rows at or below an accepted cut are retention-retired;
                  // a straggler copy must not fork the re-anchored chain.
                  (cut == null || message.seq > cut.throughSeq),
            )
            .toList()
          ..sort((left, right) => left.seq.compareTo(right.seq));
    final accepted = <GroupMessage>[];
    GroupMessage? predecessor;
    var strict = false;
    for (final message in authored) {
      if (predecessor != null && message.seq <= predecessor.seq) break;
      if (message.prevHash.isEmpty) {
        if (strict) break;
      } else {
        if (predecessor == null) {
          // A retention cut re-anchors the chain at the first surviving row
          // whose prevHash is the deleted boundary row. Matching the hash (not
          // seq+1) is required because an author's seq is global across
          // channels, so a chain scope legitimately has seq gaps. A legacy cut
          // with no hash falls back to the old seq-contiguity check. Any other
          // missing predecessor keeps hiding the scoped suffix until
          // anti-entropy supplies the exact missing row.
          if (cut == null) break;
          if (cut.throughHash.isNotEmpty) {
            if (message.prevHash != cut.throughHash) break;
          } else if (message.seq != cut.throughSeq + 1) {
            break;
          }
        } else if (message.prevHash != groupMessageHash(predecessor)) {
          break;
        }
        strict = true;
      }
      accepted.add(message);
      predecessor = message;
    }
    return accepted;
  }

  List<GroupMessage> _acceptedMessageRows(
    GroupManifest manifest,
    Iterable<GroupMessage> input, {
    Map<String, SpaceRetentionCut> retentionCuts = const {},
  }) {
    final canonical = _canonicalMessageRows(manifest, input);
    final chains = <String, ({NodeId author, String scope})>{};
    for (final message in canonical) {
      final scope = _messageChainScope(manifest, message);
      chains['$scope|${message.author.hex}'] = (
        author: message.author,
        scope: scope,
      );
    }
    final accepted = <GroupMessage>[
      for (final chain in chains.entries)
        ..._acceptedMessageChain(
          manifest,
          canonical,
          chain.value.author,
          chain.value.scope,
          cut: retentionCuts[chain.key],
        ),
    ];
    accepted.sort((left, right) {
      final time = left.createdAtMs.compareTo(right.createdAtMs);
      if (time != 0) return time;
      final author = left.author.hex.compareTo(right.author.hex);
      if (author != 0) return author;
      final seq = left.seq.compareTo(right.seq);
      if (seq != 0) return seq;
      return _messageChainScope(
        manifest,
        left,
      ).compareTo(_messageChainScope(manifest, right));
    });
    return accepted;
  }

  String _messageLifecycleScopeHash(
    GroupManifest manifest,
    GroupMessage message,
  ) => crypto.sha256
      .convert(
        utf8.encode(
          'xveil.space-message-lifecycle-scope.v1|'
          '${_messageChainScope(manifest, message)}',
        ),
      )
      .toString();

  List<SpaceMessageLifecycleHead> _messageLifecycleHeads(GroupBundle bundle) {
    final heads = <String, GroupMessage>{};
    for (final message in _acceptedMessageRows(
      bundle.manifest,
      bundle.messages,
    )) {
      final scopeHash = _messageLifecycleScopeHash(bundle.manifest, message);
      final identity = '$scopeHash|${message.author.hex}';
      final current = heads[identity];
      if (current == null || message.seq > current.seq) {
        heads[identity] = message;
      }
    }
    final ordered = heads.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return [
      for (final entry in ordered)
        SpaceMessageLifecycleHead(
          scopeHash: entry.key.substring(0, 64),
          author: entry.value.author,
          seq: entry.value.seq,
          hash: groupMessageHash(entry.value),
        ),
    ];
  }

  List<SpacePostLifecycleHead> _postLifecycleHeads(GroupBundle bundle) {
    final chains = <String, ({String generation, NodeId author})>{
      for (final post in _canonicalPostRows(
        bundle.manifest.groupId,
        bundle.posts,
      ))
        '${_postGeneration(post)}|${post.author.hex}': (
          generation: _postGeneration(post),
          author: post.author,
        ),
    };
    final heads = <SpacePostLifecycleHead>[];
    for (final entry in chains.values) {
      final chain = _acceptedPostChain(
        bundle.manifest.groupId,
        bundle.posts,
        entry.author,
        generationHash: entry.generation,
      );
      if (chain.isEmpty) continue;
      final terminal = chain.last;
      heads.add(
        SpacePostLifecycleHead(
          generationHash: entry.generation,
          author: entry.author,
          seq: terminal.seq,
          hash: _spacePostHash(terminal),
        ),
      );
    }
    heads.sort((left, right) => left.identity.compareTo(right.identity));
    return heads;
  }

  List<SpaceReactionLifecycleHead> _reactionLifecycleHeads(GroupBundle bundle) {
    final terminals = <String, GroupReaction>{};
    for (final reaction in bundle.reactions) {
      if (!_validReactionFor(bundle.manifest.groupId, reaction)) continue;
      final generation = _reactionGeneration(reaction);
      final scope = _reactionLifecycleScopeHash(reaction);
      final identity = '$generation|$scope|${reaction.author.hex}';
      final current = terminals[identity];
      if (current == null || reaction.seq > current.seq) {
        terminals[identity] = reaction;
      }
    }
    final entries = terminals.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return [
      for (final entry in entries)
        SpaceReactionLifecycleHead(
          generationHash: _reactionGeneration(entry.value),
          scopeHash: _reactionLifecycleScopeHash(entry.value),
          author: entry.value.author,
          seq: entry.value.seq,
          hash: _reactionHash(entry.value),
        ),
    ];
  }

  bool _messageWithinLifecycleBoundary(
    GroupManifest manifest,
    GroupState state,
    GroupMessage message,
  ) {
    final transition = state.lifecycleTransition;
    if (transition == null) return true;
    final scopeHash = _messageLifecycleScopeHash(manifest, message);
    SpaceMessageLifecycleHead? boundary;
    for (final head in transition.messageHeads) {
      if (head.scopeHash == scopeHash && head.author == message.author) {
        boundary = head;
        break;
      }
    }
    if (boundary != null && message.seq <= boundary.seq) {
      return message.seq < boundary.seq ||
          groupMessageHash(message) == boundary.hash;
    }
    if (!state.isActive) return false;
    return message.lifecycleGeneration == state.lifecycleTransitionHash &&
        message.policyVersion >= transition.contentPolicyVersion;
  }

  List<GroupMessage> _acceptedMessagesWithinLifecycle(
    GroupBundle bundle,
    GroupState state,
  ) {
    final accepted = _acceptedMessageRows(
      bundle.manifest,
      bundle.messages,
      retentionCuts: bundle.retentionCuts,
    );
    final transition = state.lifecycleTransition;
    if (transition == null) return accepted;
    final completePrefixes = <String>{};
    for (final head in transition.messageHeads) {
      if (accepted.any(
        (message) =>
            message.author == head.author &&
            _messageLifecycleScopeHash(bundle.manifest, message) ==
                head.scopeHash &&
            message.seq == head.seq &&
            groupMessageHash(message) == head.hash,
      )) {
        completePrefixes.add(head.identity);
      }
    }
    return [
      for (final message in accepted)
        if (() {
          final scopeHash = _messageLifecycleScopeHash(
            bundle.manifest,
            message,
          );
          SpaceMessageLifecycleHead? boundary;
          for (final head in transition.messageHeads) {
            if (head.scopeHash == scopeHash && head.author == message.author) {
              boundary = head;
              break;
            }
          }
          if (boundary != null && message.seq <= boundary.seq) {
            return completePrefixes.contains(boundary.identity);
          }
          return _messageWithinLifecycleBoundary(
            bundle.manifest,
            state,
            message,
          );
        }())
          message,
    ];
  }

  bool _postWithinLifecycleBoundary(GroupState state, SpacePost post) {
    final transition = state.lifecycleTransition;
    if (transition == null) return true;
    final generation = _postGeneration(post);
    SpacePostLifecycleHead? boundary;
    for (final head in transition.postHeads) {
      if (head.generationHash == generation && head.author == post.author) {
        boundary = head;
        break;
      }
    }
    if (boundary != null && post.seq <= boundary.seq) {
      return post.seq < boundary.seq || _spacePostHash(post) == boundary.hash;
    }
    if (!state.isActive) return false;
    return post.lifecycleGeneration == state.lifecycleTransitionHash &&
        post.policyVersion >= transition.contentPolicyVersion;
  }

  bool _reactionWithinLifecycleBoundary(
    GroupState state,
    GroupReaction reaction,
  ) {
    final transition = state.lifecycleTransition;
    if (transition == null) return true;
    SpaceReactionLifecycleHead? boundary;
    for (final head in transition.reactionHeads) {
      if (_reactionHeadMatches(head, reaction)) {
        boundary = head;
        break;
      }
    }
    if (boundary != null && reaction.seq <= boundary.seq) {
      return reaction.seq < boundary.seq ||
          _reactionHash(reaction) == boundary.hash;
    }
    if (!state.isActive) return false;
    return reaction.lifecycleGeneration == state.lifecycleTransitionHash;
  }

  List<GroupReaction> _acceptedReactionsWithinLifecycle(
    GroupBundle bundle,
    GroupState state,
  ) {
    final valid = [
      for (final reaction in bundle.reactions)
        if (_validReactionFor(bundle.manifest.groupId, reaction)) reaction,
    ];
    final transition = state.lifecycleTransition;
    if (transition == null) return valid;
    final completePrefixes = <String>{};
    for (final head in transition.reactionHeads) {
      if (valid.any(
        (reaction) =>
            _reactionHeadMatches(head, reaction) &&
            reaction.seq == head.seq &&
            _reactionHash(reaction) == head.hash,
      )) {
        completePrefixes.add(head.identity);
      }
    }
    return [
      for (final reaction in valid)
        if (() {
          SpaceReactionLifecycleHead? boundary;
          for (final head in transition.reactionHeads) {
            if (_reactionHeadMatches(head, reaction)) {
              boundary = head;
              break;
            }
          }
          if (boundary != null && reaction.seq <= boundary.seq) {
            return completePrefixes.contains(boundary.identity);
          }
          return _reactionWithinLifecycleBoundary(state, reaction);
        }())
          reaction,
    ];
  }

  /// Return valid rows outside an equivocated suffix. Two distinct valid rows
  /// at the same `(author, seq)` quarantine that fork point and every later
  /// row by the author. Publication authority must never be chosen by a hash
  /// lottery because revocation boundaries bind an exact terminal chain.
  List<SpacePost> _canonicalPostRows(
    NodeId spaceId,
    Iterable<SpacePost> input,
  ) {
    final candidates = <String, Map<String, SpacePost>>{};
    for (final post in input) {
      if (!_validPostFor(spaceId, post)) continue;
      final identity =
          '${_postGeneration(post)}|${post.author.hex}:${post.seq}';
      candidates.putIfAbsent(
        identity,
        () => <String, SpacePost>{},
      )[_spacePostHash(post)] = post;
    }
    final forkedAt = <String, int>{};
    for (final distinct in candidates.values) {
      if (distinct.length <= 1) continue;
      final sample = distinct.values.first;
      final chain = '${_postGeneration(sample)}|${sample.author.hex}';
      final current = forkedAt[chain];
      if (current == null || sample.seq < current) {
        forkedAt[chain] = sample.seq;
      }
    }
    return [
      for (final distinct in candidates.values)
        if (distinct.length == 1 &&
            distinct.values.single.seq <
                (forkedAt['${_postGeneration(distinct.values.single)}|'
                        '${distinct.values.single.author.hex}'] ??
                    (1 << 62)))
          distinct.values.single,
    ];
  }

  /// Compaction may remove invalid/identical deliveries, but never distinct
  /// fork evidence: forgetting one branch would resurrect quarantined posts.
  List<SpacePost> _retainedPostRows(NodeId spaceId, Iterable<SpacePost> input) {
    final rows = <String, SpacePost>{};
    for (final post in input) {
      if (_validPostFor(spaceId, post)) rows[_spacePostHash(post)] = post;
    }
    return rows.values.toList();
  }

  List<SpacePost> _acceptedPostChain(
    NodeId spaceId,
    Iterable<SpacePost> input,
    NodeId author, {
    String? generationHash,
  }) {
    final canonical = _canonicalPostRows(
      spaceId,
      input,
    ).where((post) => post.author == author);
    final generations = <String, List<SpacePost>>{};
    for (final post in canonical) {
      final generation = _postGeneration(post);
      if (generationHash == null || generation == generationHash) {
        generations.putIfAbsent(generation, () => []).add(post);
      }
    }
    final accepted = <SpacePost>[];
    for (final entry in generations.entries) {
      final authored = entry.value
        ..sort((left, right) => left.seq.compareTo(right.seq));
      var expectedSeq = 0;
      var expectedPrev = '';
      final lifecycleScoped = authored.first.isLifecycleScoped;
      SpacePost? predecessor;
      for (final post in authored) {
        final sequenceValid = lifecycleScoped
            ? predecessor == null || post.seq > predecessor.seq
            : post.seq == expectedSeq;
        if (!sequenceValid || post.prevHash != expectedPrev) break;
        accepted.add(post);
        predecessor = post;
        expectedSeq++;
        expectedPrev = _spacePostHash(post);
      }
    }
    accepted.sort((left, right) => left.seq.compareTo(right.seq));
    return accepted;
  }

  /// Roots retired by an absorbing tombstone. A valid signed `delete` retires
  /// its target root permanently, even when the delete row lands at a `seq`
  /// that fork-quarantine ([_canonicalPostRows]) later drops from the canonical
  /// chain. Without this, a second distinct row at the tombstone's seq — a
  /// hostile equivocation, or two devices under one identity writing
  /// concurrently while partitioned — would quarantine the whole suffix and
  /// resurrect a deleted publication, re-granting its media. Deletion is a
  /// one-way, branch-independent fact, so it must not be chosen by the same
  /// fork lottery that (correctly) governs publish/edit content authority.
  /// Mirrors the sticky-delete semantics already applied to post comments.
  Set<int> _absorbingDeletedRoots(
    NodeId spaceId,
    Iterable<SpacePost> input,
    NodeId author,
    String generationHash,
  ) {
    final publishedSeqs = <int>{};
    final deleteTargets = <int>{};
    for (final post in input) {
      if (post.author != author ||
          _postGeneration(post) != generationHash ||
          !_validPostFor(spaceId, post)) {
        continue;
      }
      switch (post.operation) {
        case SpacePostOperation.publish:
          publishedSeqs.add(post.seq);
        case SpacePostOperation.delete:
          final target = post.targetSeq;
          if (target != null && post.seq > target) deleteTargets.add(target);
        case SpacePostOperation.edit:
          break;
      }
    }
    return deleteTargets.intersection(publishedSeqs);
  }

  /// Validate only the immutable mutation topology. Content/ACL/AEAD checks
  /// happen elsewhere; this gate prevents a writer from extending a signed but
  /// nonsensical suffix (edit-of-edit, missing root, or resurrection).
  bool _postMutationChainValid(Iterable<SpacePost> chain) {
    final roots = <int>{};
    final deleted = <int>{};
    for (final post in chain) {
      switch (post.operation) {
        case SpacePostOperation.publish:
          roots.add(post.seq);
        case SpacePostOperation.edit:
          final target = post.targetSeq;
          if (target == null ||
              !roots.contains(target) ||
              deleted.contains(target)) {
            return false;
          }
        case SpacePostOperation.delete:
          final target = post.targetSeq;
          if (target == null ||
              !roots.contains(target) ||
              !deleted.add(target)) {
            return false;
          }
      }
    }
    return true;
  }

  SpacePostBoundary _postBoundaryFor(GroupBundle bundle, NodeId author) {
    final chain = _acceptedPostChain(
      bundle.manifest.groupId,
      bundle.posts,
      author,
    );
    if (chain.isEmpty) return const SpacePostBoundary(seq: -1, hash: '');
    final terminal = chain.last;
    return SpacePostBoundary(seq: terminal.seq, hash: _spacePostHash(terminal));
  }

  String? _postGrantAt(
    GroupManifest manifest,
    Iterable<ControlEntry> accepted,
    NodeId author,
  ) {
    String? grant = author == manifest.owner ? 'genesis' : null;
    for (final entry in accepted) {
      final affected = entry.op == ControlOp.leave
          ? entry.author
          : entry.target;
      if (affected != author) continue;
      switch (entry.op) {
        case ControlOp.addMember:
        case ControlOp.unmute:
          grant = controlEntryHash(entry);
        case ControlOp.mute:
        case ControlOp.removeMember:
        case ControlOp.ban:
        case ControlOp.leave:
          grant = null;
        case ControlOp.setRole:
        case ControlOp.transferOwnership:
        case ControlOp.rotateEpoch:
        case ControlOp.setPolicy:
        case ControlOp.setRetention:
        case ControlOp.setName:
        case ControlOp.setDescription:
        case ControlOp.setProfileMedia:
        case ControlOp.publishRules:
        case ControlOp.acceptRules:
        case ControlOp.moderate:
        case ControlOp.revokeModeration:
        case ControlOp.createChannel:
        case ControlOp.updateChannel:
        case ControlOp.archiveSpace:
        case ControlOp.deleteSpace:
        case ControlOp.restoreSpace:
        case ControlOp.setPostPin:
        case ControlOp.setRecommendationCampaign:
        case ControlOp.setRecommendationPolicy:
        case ControlOp.checkpoint:
          break;
      }
    }
    return grant;
  }

  ({bool revoked, SpacePostBoundary? boundary}) _postRevocationForGrant(
    GroupManifest manifest,
    Iterable<ControlEntry> accepted,
    NodeId author,
    String generation,
    int atMs,
  ) {
    final revokedModeration = <String>{
      for (final entry in accepted)
        if (entry.op == ControlOp.revokeModeration &&
            entry.moderationRevocation != null &&
            entry.moderationRevocation!.revokedAtMs <= atMs)
          entry.moderationRevocation!.actionId,
    };
    String? grant = author == manifest.owner ? 'genesis' : null;
    for (final entry in accepted) {
      final affected = entry.op == ControlOp.leave
          ? entry.author
          : entry.target;
      if (affected != author) continue;
      switch (entry.op) {
        case ControlOp.addMember:
        case ControlOp.unmute:
          grant = controlEntryHash(entry);
        case ControlOp.mute:
        case ControlOp.removeMember:
        case ControlOp.ban:
        case ControlOp.leave:
          if (grant == generation) {
            return (revoked: true, boundary: entry.postBoundary);
          }
          grant = null;
        case ControlOp.moderate:
          final action = entry.moderationAction;
          if (action != null &&
              action.kind.blocksPosts &&
              action.createdAtMs <= atMs &&
              (action.expiresAtMs == null || atMs < action.expiresAtMs!) &&
              !revokedModeration.contains('${entry.author.hex}:${entry.seq}')) {
            if (grant == generation) {
              return (revoked: true, boundary: entry.postBoundary);
            }
          }
        case ControlOp.revokeModeration:
          break;
        case ControlOp.setRole:
        case ControlOp.transferOwnership:
        case ControlOp.rotateEpoch:
        case ControlOp.setPolicy:
        case ControlOp.setRetention:
        case ControlOp.setName:
        case ControlOp.setDescription:
        case ControlOp.publishRules:
        case ControlOp.acceptRules:
        case ControlOp.createChannel:
        case ControlOp.updateChannel:
        case ControlOp.archiveSpace:
        case ControlOp.deleteSpace:
        case ControlOp.restoreSpace:
        case ControlOp.setPostPin:
        case ControlOp.setRecommendationCampaign:
        case ControlOp.setRecommendationPolicy:
        case ControlOp.setProfileMedia:
        case ControlOp.checkpoint:
          break;
      }
    }
    return (revoked: false, boundary: null);
  }

  GroupFoldResult? _historicalFoldForPost(
    GroupManifest manifest,
    List<ControlEntry> control,
    SpacePost post,
    Iterable<ControlEntry> acceptedControl,
  ) {
    if (!post.isCausal) return null;
    if (post.isCheckpointed) {
      final checkpointHash = post.controlCheckpointHash;
      if (checkpointHash == null) return null;
      ControlEntry? checkpointEntry;
      for (final entry in acceptedControl) {
        if (entry.op == ControlOp.checkpoint &&
            controlEntryHash(entry) == checkpointHash) {
          checkpointEntry = entry;
          break;
        }
      }
      return checkpointEntry == null
          ? null
          : _foldAtControlCheckpoint(manifest, control, checkpointEntry);
    }
    final frontier = post.controlFrontier;
    return frontier == null
        ? null
        : _foldAtPostFrontier(manifest, control, frontier);
  }

  bool _causalPostAuthorized(
    GroupBundle bundle,
    SpacePost post,
    List<SpacePost> acceptedAuthorChain,
    List<ControlEntry> currentAcceptedControl,
    Map<String, GroupFoldResult> historicalCache,
    Set<String> invalidHistoricalFrontiers,
  ) {
    if (!post.isCausal) return false;
    final historicalKey = post.isCheckpointed
        ? 'checkpoint:${post.controlCheckpointHash}'
        : 'frontier:${jsonEncode(post.controlFrontier?.toJson())}';
    if (invalidHistoricalFrontiers.contains(historicalKey)) return false;
    var historical = historicalCache[historicalKey];
    if (historical == null) {
      historical = _historicalFoldForPost(
        bundle.manifest,
        bundle.control,
        post,
        currentAcceptedControl,
      );
      if (historical == null) {
        invalidHistoricalFrontiers.add(historicalKey);
        return false;
      }
      historicalCache[historicalKey] = historical;
    }
    final removal = post.operation == SpacePostOperation.delete;
    if (historical.state.policyVersion != post.policyVersion ||
        !SpaceAcl(historical.state).allows(
          post.author,
          removal ? SpacePermission.view : SpacePermission.publishPosts,
          atMs: post.createdAtMs,
        )) {
      return false;
    }
    if (removal) return true;
    final generation = _postGrantAt(
      bundle.manifest,
      historical.accepted,
      post.author,
    );
    if (generation == null) return false;
    final revocation = _postRevocationForGrant(
      bundle.manifest,
      currentAcceptedControl,
      post.author,
      generation,
      post.createdAtMs,
    );
    if (!revocation.revoked) return true;
    final boundary = revocation.boundary;
    if (boundary == null || boundary.seq < 0 || post.seq > boundary.seq) {
      return false;
    }
    return acceptedAuthorChain.any(
      (candidate) =>
          candidate.seq == boundary.seq &&
          _spacePostHash(candidate) == boundary.hash,
    );
  }

  bool _causalPostHistoricallyAuthorized(
    GroupManifest manifest,
    List<ControlEntry> control,
    SpacePost post,
  ) {
    if (!post.isCausal) return false;
    final accepted = _acceptedControl(manifest, control);
    final historical = _historicalFoldForPost(
      manifest,
      control,
      post,
      accepted,
    );
    if (historical == null ||
        historical.state.policyVersion != post.policyVersion) {
      return false;
    }
    final removal = post.operation == SpacePostOperation.delete;
    if (!SpaceAcl(historical.state).allows(
      post.author,
      removal ? SpacePermission.view : SpacePermission.publishPosts,
      atMs: post.createdAtMs,
    )) {
      return false;
    }
    return removal ||
        _postGrantAt(manifest, historical.accepted, post.author) != null;
  }

  /// Validated, decrypted publication log for one Space. Legacy per-author
  /// chains are contiguous from seq 0; post-restore chains are independently
  /// scoped by their signed lifecycle generation.
  Future<List<SpacePostView>> postsOf(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const [];
    return _postsOfBundle(bundle, applyLocalRetention: true);
  }

  /// Variant for callers that already loaded the bundle. Keeping validation in
  /// one place avoids a second hidden-volume read for every Space in the merged
  /// feed while preserving the exact same fail-closed path as [postsOf].
  Future<List<SpacePostView>> _postsOfBundle(
    GroupBundle bundle, {
    bool applyLocalRetention = false,
  }) async {
    final spaceId = bundle.manifest.groupId;
    final readAt = DateTime.now().millisecondsSinceEpoch;
    final currentFold = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    );
    final state = currentFold.state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const [];
    }
    final localCutoff = applyLocalRetention
        ? await _localSpaceRetentionCutoff(spaceId, readAt)
        : -1;
    final byChain = <String, ({NodeId author, String generation})>{};
    for (final post in _canonicalPostRows(spaceId, bundle.posts)) {
      final generation = _postGeneration(post);
      byChain['$generation|${post.author.hex}'] = (
        author: post.author,
        generation: generation,
      );
    }
    final visiblePosts = <SpacePostView>[];
    final historicalCache = <String, GroupFoldResult>{};
    final invalidHistoricalFrontiers = <String>{};
    for (final chainKey in byChain.values) {
      final acceptedAuthorChain = _acceptedPostChain(
        spaceId,
        bundle.posts,
        chainKey.author,
        generationHash: chainKey.generation,
      );
      SpacePostLifecycleHead? lifecycleBoundary;
      for (final head in state.lifecycleTransition?.postHeads ?? const []) {
        if (head.generationHash == chainKey.generation &&
            head.author == chainKey.author) {
          lifecycleBoundary = head;
          break;
        }
      }
      if (lifecycleBoundary != null &&
          !acceptedAuthorChain.any(
            (post) =>
                post.seq == lifecycleBoundary!.seq &&
                _spacePostHash(post) == lifecycleBoundary.hash,
          )) {
        // Do not reveal a partial historical prefix until the exact signed
        // archive terminal is present; gap-fill can complete it later.
        continue;
      }
      final roots = <int, SpacePostView>{};
      final deletedRoots = <int>{};
      final absorbedDeleted = _absorbingDeletedRoots(
        spaceId,
        bundle.posts,
        chainKey.author,
        chainKey.generation,
      );
      for (final post in acceptedAuthorChain) {
        if (!_postWithinLifecycleBoundary(state, post)) break;
        final authorized = post.isCausal
            ? _causalPostAuthorized(
                bundle,
                post,
                acceptedAuthorChain,
                currentFold.accepted,
                historicalCache,
                invalidHistoricalFrontiers,
              )
            : SpaceAcl(state).allows(
                post.author,
                SpacePermission.publishPosts,
                atMs: post.createdAtMs,
              );
        if (!authorized) {
          break;
        }
        if (post.visibility == SpacePostVisibility.public &&
            bundle.manifest.visibility != SpaceVisibility.public) {
          break;
        }
        final visible = post.isEncrypted
            ? await _materializeEncryptedPost(bundle, post)
            : post;
        if (visible == null) break;
        var semanticValid = true;
        switch (visible.operation) {
          case SpacePostOperation.publish:
            roots[visible.seq] = SpacePostView(
              root: visible,
              effective: visible,
            );
          case SpacePostOperation.edit:
            final target = roots[visible.targetSeq];
            if (target == null || deletedRoots.contains(visible.targetSeq)) {
              semanticValid = false;
              break;
            }
            roots[visible.targetSeq!] = SpacePostView(
              root: target.root,
              effective: visible,
            );
          case SpacePostOperation.delete:
            if (!roots.containsKey(visible.targetSeq) ||
                !deletedRoots.add(visible.targetSeq!)) {
              semanticValid = false;
            }
        }
        if (!semanticValid) break;
      }
      for (final entry in roots.entries) {
        final view = entry.value;
        final pin = state.postPinFor(view.postId);
        final pinned =
            pin?.pinned == true && pin!.rootHash == _spacePostHash(view.root);
        final mediaExpired =
            !pinned &&
            state.isRetentionMediaExpired(
              // An edit that replaces media starts a new media lifetime while
              // the immutable root keeps the publication's text lifetime.
              createdAtMs: view.effective.createdAtMs,
              atMs: readAt,
            );
        if (deletedRoots.contains(entry.key) ||
            absorbedDeleted.contains(entry.key) ||
            state.isModeratedContentRemoved(
              kind: SpaceModerationReferenceKind.spacePost,
              author: view.root.author,
              seq: view.root.seq,
              atMs: readAt,
            ) ||
            (!pinned &&
                state.isRetentionExpired(
                  createdAtMs: view.root.createdAtMs,
                  atMs: readAt,
                )) ||
            (!pinned && view.root.createdAtMs <= localCutoff)) {
          continue;
        }
        final projected = mediaExpired
            ? view.withMediaHiddenByRetention()
            : view;
        visiblePosts.add(
          projected.withPin(pinned: pinned, pinnedAtMs: pin?.changedAtMs),
        );
      }
    }
    visiblePosts.sort((left, right) {
      final time = left.publishedAtMs.compareTo(right.publishedAtMs);
      if (time != 0) return time;
      final author = left.author.hex.compareTo(right.author.hex);
      if (author != 0) return author;
      return left.seq.compareTo(right.seq);
    });
    return visiblePosts;
  }

  String _publicSubscriptionSnapshotFileId(NodeId spaceId) =>
      'space-public-subscription:${spaceId.hex}';

  Future<({Set<String> ids, bool complete})>
  _loadPublicSubscriptionIndex() async {
    final Uint8List? bytes;
    try {
      bytes = await _storage.loadFile(_publicSubscriptionIndexFileId);
    } catch (_) {
      return (ids: <String>{}, complete: false);
    }
    if (bytes == null) return (ids: <String>{}, complete: true);
    if (bytes.isEmpty || bytes.length > _kPublicSubscriptionIndexMaxBytes) {
      return (ids: <String>{}, complete: false);
    }
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (decoded is! Map ||
          decoded.length != 2 ||
          decoded['v'] != 1 ||
          decoded['items'] is! List) {
        return (ids: <String>{}, complete: false);
      }
      final items = decoded['items'] as List;
      if (items.length > _kMaxPublicSubscriptions) {
        return (ids: <String>{}, complete: false);
      }
      final ids = <String>{};
      for (final value in items) {
        if (value is! String ||
            !_sharedContentIdPattern.hasMatch(value) ||
            !ids.add(value)) {
          return (ids: <String>{}, complete: false);
        }
      }
      return (ids: ids, complete: true);
    } catch (_) {
      return (ids: <String>{}, complete: false);
    }
  }

  Future<void> _savePublicSubscriptionIndex(Set<String> ids) async {
    if (ids.length > _kMaxPublicSubscriptions) {
      throw StateError('too many public Space subscriptions');
    }
    final sorted = ids.toList()..sort();
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode({'v': 1, 'items': sorted})),
    );
    if (bytes.length > _kPublicSubscriptionIndexMaxBytes) {
      throw StateError('public Space subscription index is too large');
    }
    await _storage.storeFile(
      _publicSubscriptionIndexFileId,
      bytes,
      name: 'public-space-subscriptions',
    );
  }

  Future<SpacePublicSubscriptionSnapshot?> _loadPublicSubscriptionSnapshot(
    NodeId spaceId,
  ) async {
    final cached = _publicSubscriptionSnapshots[spaceId.hex];
    if (cached != null) return cached;
    final Uint8List? bytes;
    try {
      bytes = await _storage.loadFile(
        _publicSubscriptionSnapshotFileId(spaceId),
      );
    } catch (_) {
      return null;
    }
    final snapshot = bytes == null
        ? null
        : SpacePublicSubscriptionSnapshot.fromBytes(bytes);
    if (snapshot == null ||
        snapshot.package.descriptor.spaceId != spaceId ||
        !snapshot.verifyStored(
          verifySignature: _signer.verifyDetached,
          verifyPost: _signer.verifyPost,
        )) {
      return null;
    }
    _publicSubscriptionSnapshots[spaceId.hex] = snapshot;
    return snapshot;
  }

  Future<SpaceSubscription?> _storedSpaceSubscription(NodeId spaceId) async {
    final stored = await _storage.getSetting(_spaceSubscriptionKey(spaceId));
    if (stored == null || stored.isEmpty) return null;
    try {
      return SpaceSubscription.fromJson(jsonDecode(stored), spaceId);
    } catch (_) {
      return null;
    }
  }

  Future<bool> _hasActiveSpaceMembership(NodeId spaceId) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    return SpaceAcl(state).allows(_signer.selfId, SpacePermission.view);
  }

  SpacePublicSubscriptionView _publicSubscriptionView(
    SpacePublicSubscriptionSnapshot snapshot,
    SpaceSubscription subscription,
  ) => SpacePublicSubscriptionView(
    subscription: subscription,
    descriptor: snapshot.package.descriptor,
    feed: snapshot.package.projection,
    verifiedAtMs: snapshot.verifiedAtMs,
    stale: snapshot.isStaleAt(_now()),
  );

  Future<SpacePublicSubscriptionView?> publicSpaceSubscription(
    NodeId spaceId,
  ) async {
    final index = await _loadPublicSubscriptionIndex();
    if (!index.complete ||
        !index.ids.contains(spaceId.hex) ||
        await _hasActiveSpaceMembership(spaceId)) {
      return null;
    }
    final snapshot = await _loadPublicSubscriptionSnapshot(spaceId);
    if (snapshot == null) return null;
    final stored = await _storedSpaceSubscription(spaceId);
    final subscription = stored?.publicOnly == true
        ? stored!
        : SpaceSubscription.publicDefault(spaceId);
    return _publicSubscriptionView(snapshot, subscription);
  }

  /// Return the author-signed public discussion for one subscribed post.
  ///
  /// The public snapshot has already passed its owner manifest gate. Folding
  /// here verifies every contributing author again and rejects broken chains,
  /// so UI callers never need access to the service's private signer.
  Future<List<SpacePublicCommentView>> publicSpacePostComments(
    NodeId spaceId,
    String postId,
  ) async {
    final view = await publicSpaceSubscription(spaceId);
    if (view == null || !view.feed.posts.any((post) => post.postId == postId)) {
      return const [];
    }
    final comments = view.feed.commentsFor(postId, _signer.verifyDetached);
    return _withoutBlockedSpaceAuthors(comments, (comment) => comment.author);
  }

  Future<SpacePublicReactions> publicSpacePostReactions(
    NodeId spaceId,
    String postId,
  ) async {
    final view = await publicSpaceSubscription(spaceId);
    if (view == null || !view.feed.posts.any((post) => post.postId == postId)) {
      return const {};
    }
    return view.feed.reactionsFor(postId, _signer.verifyDetached);
  }

  /// Stable public root refs known to an active member. The composer uses this
  /// to prevent accidentally marking a reply public when its parent was
  /// members-only (which would otherwise be rejected by the service).
  Future<Set<String>> publicSpacePostCommentRefs(
    NodeId spaceId,
    String postId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null ||
        bundle.manifest.visibility != SpaceVisibility.public) {
      return const {};
    }
    return {
      for (final comment in foldSpacePublicComments(
        comments: bundle.publicComments,
        spaceId: spaceId,
        postId: postId,
        verifySignature: _signer.verifyDetached,
      ))
        comment.ref,
    };
  }

  Future<List<SpacePublicSubscriptionView>> publicSpaceSubscriptions() async {
    final index = await _loadPublicSubscriptionIndex();
    if (!index.complete) return const [];
    final views = <SpacePublicSubscriptionView>[];
    for (final hex in index.ids) {
      final NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        continue;
      }
      if (await _hasActiveSpaceMembership(spaceId)) continue;
      final snapshot = await _loadPublicSubscriptionSnapshot(spaceId);
      if (snapshot == null) continue;
      final stored = await _storedSpaceSubscription(spaceId);
      final subscription = stored?.publicOnly == true
          ? stored!
          : SpaceSubscription.publicDefault(spaceId);
      views.add(_publicSubscriptionView(snapshot, subscription));
    }
    views.sort((left, right) {
      final name = left.descriptor.name.compareTo(right.descriptor.name);
      return name != 0
          ? name
          : left.descriptor.spaceId.hex.compareTo(right.descriptor.spaceId.hex);
    });
    return List<SpacePublicSubscriptionView>.unmodifiable(views);
  }

  /// Activate or refresh a read-only public subscription from one exact,
  /// currently verified descriptor/feed pair.
  ///
  /// The snapshot and preference are written before the compact index. The
  /// index is the sole activation point, so a crash cannot expose a preference
  /// whose signed bytes are absent. Existing snapshots also impose monotonic
  /// descriptor and feed revisions to reject a validly signed rollback.
  Future<SpacePublicSubscriptionView?> subscribeToPublicSpace(
    SpacePublicDescriptor descriptor,
    Iterable<SpacePublicHolderAnnouncement> holders,
  ) => _serializeSpaceFeedPreferences(() async {
    final nowMs = _now();
    if (!descriptor.verifyAt(nowMs, _signer.verifyDetached) ||
        descriptor.genesisManifest.visibility != SpaceVisibility.public ||
        await _hasActiveSpaceMembership(descriptor.spaceId)) {
      return null;
    }
    final exactHolders = <String, SpacePublicHolderAnnouncement>{};
    for (final holder in holders) {
      if (holder.holder == selfId ||
          holder.spaceId != descriptor.spaceId ||
          holder.descriptorHash != descriptor.descriptorHash ||
          holder.publicFeedManifestHash != descriptor.publicFeedManifestHash ||
          !holder.verifyAt(nowMs, _signer.verifyDetached)) {
        continue;
      }
      exactHolders[holder.holder.hex] = holder;
    }
    if (exactHolders.isEmpty) return null;

    final index = await _loadPublicSubscriptionIndex();
    if (!index.complete ||
        (!index.ids.contains(descriptor.spaceId.hex) &&
            index.ids.length >= _kMaxPublicSubscriptions)) {
      return null;
    }
    final prior = index.ids.contains(descriptor.spaceId.hex)
        ? await _loadPublicSubscriptionSnapshot(descriptor.spaceId)
        : null;
    if (prior != null) {
      final current = prior.package.descriptor;
      final authorityOrder = descriptor.authorityGeneration.compareTo(
        current.authorityGeneration,
      );
      final sameGeneration = authorityOrder == 0;
      final authorityForkOrder = descriptor.authorityHash.compareTo(
        current.authorityHash,
      );
      if (authorityOrder < 0 ||
          (sameGeneration && authorityForkOrder < 0) ||
          (sameGeneration &&
              authorityForkOrder == 0 &&
              (descriptor.revision < current.revision ||
                  descriptor.publicFeedRevision < current.publicFeedRevision ||
                  descriptor.publicFeedUpdatedAtMs <
                      current.publicFeedUpdatedAtMs))) {
        return null;
      }
    }

    SpacePublicFeedProjection? feed;
    final cached = await _loadVerifiedPublicFeed(
      descriptor.spaceId,
      descriptor.publicFeedManifestHash,
    );
    if (cached != null &&
        cached.descriptor.descriptorHash == descriptor.descriptorHash) {
      feed = cached.feed;
    }
    feed ??= await fetchVerifiedPublicSpaceFeed(
      descriptor,
      exactHolders.values,
    );
    if (feed == null) return null;
    final package = SpacePublicFeedPackage(
      descriptor: descriptor,
      projection: feed,
    );
    if (!package.verifyAt(
      nowMs: nowMs,
      verifySignature: _signer.verifyDetached,
      verifyPost: _signer.verifyPost,
    )) {
      return null;
    }
    if (prior != null &&
        prior.package.descriptor.descriptorHash == descriptor.descriptorHash &&
        prior.package.projection.manifest.manifestHash ==
            feed.manifest.manifestHash) {
      final stored = await _storedSpaceSubscription(descriptor.spaceId);
      return _publicSubscriptionView(
        prior,
        stored?.publicOnly == true
            ? stored!
            : SpaceSubscription.publicDefault(descriptor.spaceId),
      );
    }
    final snapshot = SpacePublicSubscriptionSnapshot(
      verifiedAtMs: nowMs,
      package: package,
    );
    final snapshotBytes = snapshot.toBytes();
    if (snapshotBytes.length > kSpacePublicSubscriptionSnapshotMaxBytes) {
      return null;
    }

    final stored = index.ids.contains(descriptor.spaceId.hex)
        ? await _storedSpaceSubscription(descriptor.spaceId)
        : null;
    final subscription =
        (stored?.publicOnly == true
                ? stored!
                : SpaceSubscription.publicDefault(descriptor.spaceId))
            .copyWith(publicOnly: true, updatedAtMs: nowMs);
    await _storage.storeFile(
      _publicSubscriptionSnapshotFileId(descriptor.spaceId),
      snapshotBytes,
      name: 'public-space-subscription',
    );
    await _saveSpaceSubscription(subscription);
    await _storage.putSetting(_spaceFeedEnabledKey(descriptor.spaceId), '');
    await _savePublicSubscriptionIndex({...index.ids, descriptor.spaceId.hex});
    _publicSubscriptionSnapshots[descriptor.spaceId.hex] = snapshot;
    changes.value++;
    feedAccessChanges.value++;
    if (prior != null) {
      final priorPostIds = {
        for (final post in prior.package.projection.posts) post.postId,
      };
      final priorCommentRefs = <String>{};
      for (final post in prior.package.projection.posts) {
        priorCommentRefs.addAll(
          prior.package.projection
              .commentsFor(post.postId, _signer.verifyDetached)
              .map((comment) => comment.ref),
        );
      }
      for (final post in feed.posts) {
        if (post.author != selfId && !priorPostIds.contains(post.postId)) {
          _incomingPublicPostCtl.add((spaceId: descriptor.spaceId, post: post));
        }
        for (final comment in feed.commentsFor(
          post.postId,
          _signer.verifyDetached,
        )) {
          if (comment.author != selfId &&
              !priorCommentRefs.contains(comment.ref)) {
            _incomingPublicCommentCtl.add((
              spaceId: descriptor.spaceId,
              comment: comment,
            ));
          }
        }
      }
    }
    return _publicSubscriptionView(snapshot, subscription);
  });

  Future<SpacePublicSubscriptionView?> subscribeToPublicSpaceDiscovery(
    SpacePublicDiscoveryResult result,
  ) => subscribeToPublicSpace(result.descriptor, result.holders);

  Future<SpacePublicSubscriptionView?> refreshPublicSpaceSubscription(
    NodeId spaceId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (await publicSpaceSubscription(spaceId) == null) return null;
    final discovery = await resolvePublicSpaceDiscovery(
      spaceId,
      timeout: timeout,
    );
    return discovery == null
        ? null
        : subscribeToPublicSpaceDiscovery(discovery);
  }

  /// Refresh the exact public descriptor/holders before opening a media grant.
  /// Stored bytes remain usable offline, but a new transfer never relies on an
  /// expired holder captured in a local snapshot.
  Future<bool> requestSubscribedPublicSpaceMedia(
    NodeId spaceId,
    String contentId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final current = await publicSpaceSubscription(spaceId);
    if (current == null ||
        !current.feed
            .verifiedReferencedContentIds(_signer.verifyDetached)
            .contains(contentId)) {
      return false;
    }
    final discovery = await resolvePublicSpaceDiscovery(
      spaceId,
      timeout: timeout,
    );
    if (discovery == null) return false;
    final refreshed = await subscribeToPublicSpaceDiscovery(discovery);
    if (refreshed == null ||
        !refreshed.feed
            .verifiedReferencedContentIds(_signer.verifyDetached)
            .contains(contentId)) {
      return false;
    }
    return requestPublicSpaceMedia(
      discovery.descriptor,
      discovery.holders,
      contentId,
    );
  }

  /// Deactivate first, then best-effort scrub the now-unreachable public
  /// snapshot. Shared downloaded media is reclaimed only by the global GC.
  Future<bool> unsubscribeFromPublicSpace(NodeId spaceId) =>
      _serializeSpaceFeedPreferences(() async {
        final index = await _loadPublicSubscriptionIndex();
        if (!index.complete || !index.ids.contains(spaceId.hex)) return false;
        final next = Set<String>.of(index.ids)..remove(spaceId.hex);
        await _savePublicSubscriptionIndex(next);
        _publicSubscriptionSnapshots.remove(spaceId.hex);
        try {
          await _storage.putSetting(_spaceSubscriptionKey(spaceId), '');
          await _storage.putSetting(_spaceFeedSeenKey(spaceId), '');
          await _storage.deleteStoredFile(
            _publicSubscriptionSnapshotFileId(spaceId),
          );
        } catch (_) {
          // The activation index is already authoritative. Any orphaned
          // public bytes are inert and can be scrubbed by later maintenance.
        }
        changes.value++;
        feedAccessChanges.value++;
        return true;
      });

  String _spaceFeedEnabledKey(NodeId spaceId) =>
      'space.feed.enabled:${spaceId.hex}';
  String _spaceSubscriptionKey(NodeId spaceId) =>
      'space.subscription.v1:${spaceId.hex}';
  String _spaceFeedSeenKey(NodeId spaceId) => 'space.feed.seen:${spaceId.hex}';
  static const String _spaceFeedTypesKey = 'space.feed.types.v1';
  static const String _spaceFeedHiddenStoreKey = 'space.feed.hidden.v1';
  static const int _maxHiddenSpaceFeedPosts = 4096;
  Future<void> _spaceFeedPreferenceMutationTail = Future<void>.value();

  String _hiddenSpaceFeedPostKey(NodeId spaceId, String postId) =>
      '${spaceId.hex}:$postId';

  Future<T> _serializeSpaceFeedPreferences<T>(
    Future<T> Function() action,
  ) async {
    final previous = _spaceFeedPreferenceMutationTail;
    final gate = Completer<void>();
    _spaceFeedPreferenceMutationTail = gate.future;
    try {
      try {
        await previous;
      } catch (_) {
        // A prior preference write reports its own failure; keep the queue live.
      }
      return await action();
    } finally {
      gate.complete();
    }
  }

  /// Device-local feed dismissals. They live in the active identity's
  /// encrypted store and never mutate, tombstone, or relay the signed post.
  Future<Map<String, int>> _hiddenSpaceFeedPosts() async {
    final blob = await _storage.loadFile(_spaceFeedHiddenStoreKey);
    if (blob == null || blob.isEmpty) return <String, int>{};
    try {
      final raw = utf8.decode(blob);
      final value = jsonDecode(raw);
      if (value is! Map || value['v'] != 1 || value['items'] is! List) {
        return <String, int>{};
      }
      final result = <String, int>{};
      for (final item in value['items'] as List) {
        if (item is! Map ||
            item['sid'] is! String ||
            item['post'] is! String ||
            item['at'] is! int ||
            item['at'] as int < 0 ||
            !_spacePostIdPattern.hasMatch(item['post'] as String)) {
          continue;
        }
        final NodeId spaceId;
        try {
          spaceId = NodeId.fromHex(item['sid'] as String);
        } catch (_) {
          continue;
        }
        result[_hiddenSpaceFeedPostKey(spaceId, item['post'] as String)] =
            item['at'] as int;
      }
      return result;
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _saveHiddenSpaceFeedPosts(Map<String, int> hidden) async {
    final entries = hidden.entries.toList()
      ..sort((left, right) => right.value.compareTo(left.value));
    final bounded = entries.take(_maxHiddenSpaceFeedPosts);
    final json = jsonEncode({
      'v': 1,
      'items': [
        for (final entry in bounded)
          {
            'sid': entry.key.substring(0, 64),
            'post': entry.key.substring(65),
            'at': entry.value,
          },
      ],
    });
    // The bounded list may still be hundreds of KiB. Use the encrypted
    // chunked store rather than the ~4 KiB single-setting path.
    await _storage.storeFile(
      _spaceFeedHiddenStoreKey,
      Uint8List.fromList(utf8.encode(json)),
      name: 'feed-hidden',
    );
  }

  /// Complete device-local Feed filter. The original v1 value contained only
  /// publication types; [SpaceFeedFilter.fromJson] migrates it in place.
  Future<SpaceFeedFilter> spaceFeedFilter() async {
    final stored = await _storage.getSetting(_spaceFeedTypesKey);
    if (stored == null || stored.isEmpty) return SpaceFeedFilter.defaults();
    try {
      return SpaceFeedFilter.fromJson(jsonDecode(stored)) ??
          SpaceFeedFilter.defaults();
    } catch (_) {
      // Corrupt local UI state must never make the user's Feed disappear.
      return SpaceFeedFilter.defaults();
    }
  }

  Future<Set<SpacePostType>> spaceFeedTypeFilter() async =>
      (await spaceFeedFilter()).types;

  Future<void> _writeSpaceFeedFilter(SpaceFeedFilter next) async {
    final current = await spaceFeedFilter();
    if (jsonEncode(current.toJson()) == jsonEncode(next.toJson())) return;
    await _storage.putSetting(
      _spaceFeedTypesKey,
      next.isDefault ? '' : jsonEncode(next.toJson()),
    );
    changes.value++;
  }

  Future<void> setSpaceFeedFilter(SpaceFeedFilter filter) {
    if (!filter.isStructurallyValid) {
      return Future<void>.error(
        ArgumentError.value(filter, 'filter', 'invalid Feed filter'),
      );
    }
    return _serializeSpaceFeedPreferences(() => _writeSpaceFeedFilter(filter));
  }

  /// Compatibility surface for the REST type-filter endpoint. Updating types
  /// preserves the mention, time and community dimensions selected in the UI.
  Future<void> setSpaceFeedTypeFilter(Set<SpacePostType> types) =>
      _serializeSpaceFeedPreferences(() async {
        final current = await spaceFeedFilter();
        await _writeSpaceFeedFilter(current.copyWith(types: types));
      });

  Future<bool> isSpaceFeedPostHidden(NodeId spaceId, String postId) async {
    if (!_spacePostIdPattern.hasMatch(postId)) return false;
    return (await _hiddenSpaceFeedPosts()).containsKey(
      _hiddenSpaceFeedPostKey(spaceId, postId),
    );
  }

  /// Hide or restore one publication only in this identity's merged Feed.
  /// The community's own publication history remains intact and visible.
  Future<void> setSpaceFeedPostHidden(
    NodeId spaceId,
    String postId,
    bool hidden,
  ) => _serializeSpaceFeedPreferences(() async {
    if (!_spacePostIdPattern.hasMatch(postId)) {
      throw ArgumentError.value(postId, 'postId', 'invalid Space post id');
    }
    final bundle = await load(spaceId);
    final publicSubscription = bundle == null
        ? await publicSpaceSubscription(spaceId)
        : null;
    if ((bundle == null || !bundle.manifest.isSpace) &&
        publicSubscription == null) {
      throw ArgumentError.value(spaceId.hex, 'spaceId', 'unknown Space');
    }
    if (hidden) {
      final visible =
          publicSubscription?.feed.posts ??
          await _postsOfBundle(bundle!, applyLocalRetention: true);
      if (!visible.any((post) => post.postId == postId)) {
        throw ArgumentError.value(postId, 'postId', 'unknown visible post');
      }
    }
    final values = await _hiddenSpaceFeedPosts();
    final key = _hiddenSpaceFeedPostKey(spaceId, postId);
    final bool changed;
    if (hidden) {
      changed = !values.containsKey(key);
      if (changed) values[key] = _now();
    } else {
      changed = values.remove(key) != null;
    }
    if (!changed) return;
    await _saveHiddenSpaceFeedPosts(values);
    changes.value++;
  });

  /// Membership and feed subscription are intentionally separate. An active
  /// member follows publications by default but can disable them locally
  /// without leaving the Space or mutating its signed control log.
  Future<SpaceSubscription> spaceSubscription(NodeId spaceId) async {
    final stored = await _storedSpaceSubscription(spaceId);
    if (await _hasActiveSpaceMembership(spaceId)) {
      if (stored != null && !stored.publicOnly) return stored;
      // One-version migration from the boolean key introduced by the first
      // feed slice. It is local-only and can be rewritten atomically on next
      // change.
      final legacy = await _storage.getSetting(_spaceFeedEnabledKey(spaceId));
      return SpaceSubscription.memberDefault(
        spaceId,
      ).copyWith(feedEnabled: legacy != '0');
    }
    final index = await _loadPublicSubscriptionIndex();
    if (index.complete &&
        index.ids.contains(spaceId.hex) &&
        await _loadPublicSubscriptionSnapshot(spaceId) != null) {
      if (stored != null && stored.publicOnly) return stored;
      return SpaceSubscription.publicDefault(spaceId);
    }
    // Preserve the legacy behavior for unknown/inactive Spaces. Callers that
    // need to mutate still prove active membership or an activated public
    // snapshot in [updateSpaceSubscription].
    final legacy = await _storage.getSetting(_spaceFeedEnabledKey(spaceId));
    return SpaceSubscription.memberDefault(
      spaceId,
    ).copyWith(feedEnabled: legacy != '0');
  }

  Future<bool> isSpaceFeedEnabled(NodeId spaceId) async =>
      (await spaceSubscription(spaceId)).feedEnabled;

  Future<void> _saveSpaceSubscription(SpaceSubscription subscription) =>
      _storage.putSetting(
        _spaceSubscriptionKey(subscription.spaceId),
        jsonEncode(subscription.toJson()),
      );

  /// Atomically updates the device-local subscription preferences for one
  /// Space. The three switches share one encrypted record, so every
  /// read-modify-write must use the same queue or concurrent UI/API writes can
  /// silently restore an older sibling field.
  Future<SpaceSubscription> updateSpaceSubscription(
    NodeId spaceId, {
    bool? feedEnabled,
    bool? notificationsEnabled,
    SpaceCommentNotificationMode? commentNotifications,
    bool? hiddenFromRecommendations,
  }) => _serializeSpaceFeedPreferences(() async {
    final current = await spaceSubscription(spaceId);
    if (current.publicOnly) {
      if (await publicSpaceSubscription(spaceId) == null) {
        throw StateError('public Space subscription is not active');
      }
    } else {
      final bundle = await load(spaceId);
      if (bundle == null || !bundle.manifest.isSpace) {
        throw ArgumentError.value(spaceId.hex, 'spaceId', 'unknown Space');
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
        throw StateError('Space subscription requires active membership');
      }
    }
    final next = current.copyWith(
      feedEnabled: feedEnabled,
      notificationsEnabled: notificationsEnabled,
      commentNotifications: commentNotifications,
      hiddenFromRecommendations: hiddenFromRecommendations,
      updatedAtMs: _now(),
    );
    final changed =
        current.feedEnabled != next.feedEnabled ||
        current.notificationsEnabled != next.notificationsEnabled ||
        current.commentNotifications != next.commentNotifications ||
        current.hiddenFromRecommendations != next.hiddenFromRecommendations;
    // Retire the one-field legacy preference even when this write is a no-op,
    // otherwise a later recovery from a damaged v1 record could resurrect it.
    await _storage.putSetting(_spaceFeedEnabledKey(spaceId), '');
    if (!changed) return current;
    await _saveSpaceSubscription(next);
    changes.value++;
    return next;
  });

  Future<void> setSpaceFeedEnabled(NodeId spaceId, bool enabled) async {
    await updateSpaceSubscription(spaceId, feedEnabled: enabled);
  }

  Future<void> setSpaceNotificationsEnabled(
    NodeId spaceId,
    bool enabled,
  ) async {
    await updateSpaceSubscription(spaceId, notificationsEnabled: enabled);
  }

  Future<void> setSpaceCommentNotifications(
    NodeId spaceId,
    SpaceCommentNotificationMode mode,
  ) async {
    await updateSpaceSubscription(spaceId, commentNotifications: mode);
  }

  Future<void> setSpaceHiddenFromRecommendations(
    NodeId spaceId,
    bool hidden,
  ) async {
    await updateSpaceSubscription(spaceId, hiddenFromRecommendations: hidden);
  }

  /// Merge subscribed Space logs in descending chronological order. The
  /// signed `(publishedAt, spaceId, author, seq)` tuple is a stable cursor and
  /// the identity set prevents duplicates regardless of roles or sync paths.
  Future<List<SpaceFeedItem>> spaceFeed({
    SpaceFeedCursor? before,
    int limit = 50,
    Set<SpacePostType>? types,
    SpaceFeedFilter? filter,
    bool? pinned,
  }) async {
    final boundedLimit = limit.clamp(1, 200);
    var selectedFilter = filter ?? await spaceFeedFilter();
    if (types != null) selectedFilter = selectedFilter.copyWith(types: types);
    final readAt = DateTime.now().millisecondsSinceEpoch;
    final items = <SpaceFeedItem>[];
    final seen = <String>{};
    final memberSpaceIds = <String>{};
    final hidden = await _hiddenSpaceFeedPosts();
    final blockedAuthors = <String, Future<bool>>{};
    Future<bool> isBlockedAuthor(NodeId author) {
      if (author == _signer.selfId) return Future<bool>.value(false);
      return blockedAuthors.putIfAbsent(
        author.hex,
        () async =>
            (await _storage.getContact(author))?.status ==
            ContactStatus.blocked,
      );
    }

    for (final id in await _index()) {
      final NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(id);
      } catch (_) {
        continue;
      }
      if (selectedFilter.spaceIds.isNotEmpty &&
          !selectedFilter.spaceIds.contains(spaceId)) {
        continue;
      }
      final bundle = await load(spaceId);
      if (bundle == null || !bundle.manifest.isSpace) continue;
      final folded = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (entry) => _validControlFor(bundle.manifest, entry),
        initialName: bundle.manifest.name,
      );
      final state = folded.state;
      final acl = SpaceAcl(state);
      if (!acl.allows(_signer.selfId, SpacePermission.view)) {
        continue;
      }
      memberSpaceIds.add(spaceId.hex);
      if (!await isSpaceFeedEnabled(spaceId)) continue;
      final canManagePosts = acl.allows(
        _signer.selfId,
        SpacePermission.managePosts,
      );
      final visiblePosts = await _postsOfBundle(
        bundle,
        applyLocalRetention: true,
      );
      final feedPosts = <SpacePostView>[];
      for (final post in visiblePosts) {
        if (hidden.containsKey(_hiddenSpaceFeedPostKey(spaceId, post.postId)) ||
            await isBlockedAuthor(post.author)) {
          continue;
        }
        feedPosts.add(post);
      }
      final reactions = await _spacePostReactionsOfBundle(
        bundle,
        visiblePostIds: {for (final post in feedPosts) post.postId},
      );
      final commentsByPost = selectedFilter.mentionsOnly
          ? (await spacePostsAndCommentsOf(spaceId)).commentsByPost
          : const <String, List<SpacePostCommentView>>{};
      for (final post in feedPosts) {
        var relatedMention = false;
        if (selectedFilter.mentionsOnly) {
          for (final comment
              in commentsByPost[post.postId] ??
                  const <SpacePostCommentView>[]) {
            if (comment.author != _signer.selfId &&
                messageMentionsNode(comment.body, _signer.selfId) &&
                !await isBlockedAuthor(comment.author)) {
              relatedMention = true;
              break;
            }
          }
        }
        if (!selectedFilter.allowsPost(
          post,
          viewer: _signer.selfId,
          nowMs: readAt,
          relatedMention: relatedMention,
        )) {
          continue;
        }
        if (pinned != null && post.pinned != pinned) continue;
        final cursor = SpaceFeedCursor.fromView(post);
        if (before != null && cursor.compareTo(before) >= 0) continue;
        if (!seen.add('${spaceId.hex}:${post.postId}')) continue;
        items.add(
          SpaceFeedItem(
            spaceId: spaceId,
            spaceName: state.name,
            post: post,
            reactions: reactions[post.postId] ?? const {},
            canDeletePost:
                post.author == _signer.selfId &&
                state.isActive &&
                post.effective.lifecycleGeneration ==
                    state.lifecycleTransitionHash,
            canModeratePost:
                post.author != _signer.selfId &&
                acl.allowsControl(
                  _signer.selfId,
                  ControlOp.moderate,
                  target: post.author,
                  moderationTargetsRemovedContent: true,
                ),
            canManagePosts: canManagePosts,
          ),
        );
      }
    }
    for (final public in await publicSpaceSubscriptions()) {
      final spaceId = public.descriptor.spaceId;
      if (memberSpaceIds.contains(spaceId.hex) ||
          !public.subscription.feedEnabled ||
          (selectedFilter.spaceIds.isNotEmpty &&
              !selectedFilter.spaceIds.contains(spaceId))) {
        continue;
      }
      for (final post in public.feed.posts) {
        var relatedMention = false;
        if (selectedFilter.mentionsOnly) {
          for (final comment in public.feed.commentsFor(
            post.postId,
            _signer.verifyDetached,
          )) {
            if (comment.author != _signer.selfId &&
                messageMentionsNode(comment.body, _signer.selfId) &&
                !await isBlockedAuthor(comment.author)) {
              relatedMention = true;
              break;
            }
          }
        }
        if (hidden.containsKey(_hiddenSpaceFeedPostKey(spaceId, post.postId)) ||
            await isBlockedAuthor(post.author) ||
            !selectedFilter.allowsPost(
              post,
              viewer: _signer.selfId,
              nowMs: readAt,
              relatedMention: relatedMention,
            ) ||
            (pinned != null && post.pinned != pinned)) {
          continue;
        }
        final cursor = SpaceFeedCursor.fromView(post);
        if (before != null && cursor.compareTo(before) >= 0) continue;
        if (!seen.add('${spaceId.hex}:${post.postId}')) continue;
        items.add(
          SpaceFeedItem(
            spaceId: spaceId,
            spaceName: public.descriptor.name,
            post: post,
            reactions: public.feed.reactionsFor(
              post.postId,
              _signer.verifyDetached,
            ),
            canDeletePost: false,
            canModeratePost: false,
            canManagePosts: false,
            publicOnly: true,
          ),
        );
      }
    }
    items.sort((left, right) {
      final order = SpaceFeedCursor.fromView(
        right.post,
      ).compareTo(SpaceFeedCursor.fromView(left.post));
      return order;
    });
    final result = items.length <= boundedLimit
        ? items
        : items.sublist(0, boundedLimit);
    _observeSpace(
      SpaceObservationType.feedRead,
      result.isEmpty
          ? SpaceObservationOutcome.noOp
          : SpaceObservationOutcome.succeeded,
      amount: result.length,
    );
    return result;
  }

  Future<int> unreadSpacePosts(NodeId spaceId) async {
    return (await unreadSpacePostViews(spaceId)).length;
  }

  Future<List<SpacePostView>> _spaceFeedPostsForReadState(
    NodeId spaceId,
  ) async {
    if (await _hasActiveSpaceMembership(spaceId)) {
      return postsOf(spaceId);
    }
    final public = await publicSpaceSubscription(spaceId);
    return public?.feed.posts ?? const [];
  }

  Future<List<SpacePostView>> unreadSpacePostViews(NodeId spaceId) async {
    final hidden = await _hiddenSpaceFeedPosts();
    final seen = SpaceFeedCursor.decode(
      await _storage.getSetting(_spaceFeedSeenKey(spaceId)),
    );
    final posts = await _spaceFeedPostsForReadState(spaceId);
    final visible = <SpacePostView>[];
    for (final post in posts) {
      if (hidden.containsKey(_hiddenSpaceFeedPostKey(spaceId, post.postId)) ||
          post.author == _signer.selfId ||
          (await _storage.getContact(post.author))?.status ==
              ContactStatus.blocked ||
          (seen != null &&
              SpaceFeedCursor.fromView(post).compareTo(seen) <= 0)) {
        continue;
      }
      visible.add(post);
    }
    return List<SpacePostView>.unmodifiable(visible);
  }

  Future<void> markSpaceFeedSeen(NodeId spaceId) async {
    final posts = await _spaceFeedPostsForReadState(spaceId);
    if (posts.isEmpty) return;
    final latest = posts
        .map(SpaceFeedCursor.fromView)
        .reduce((left, right) => left.compareTo(right) >= 0 ? left : right);
    final prior = SpaceFeedCursor.decode(
      await _storage.getSetting(_spaceFeedSeenKey(spaceId)),
    );
    if (prior != null && prior.compareTo(latest) >= 0) return;
    await _storage.putSetting(_spaceFeedSeenKey(spaceId), latest.encode());
    changes.value++;
  }

  // ── Group log gap-fill (reliability brick G1) ─────────────────────────────
  // A delta that dies while EVERY entry node is down is lost for good — the
  // full snapshot only ships on join. Each device therefore sends a compact
  // per-author high-water VECTOR to its deterministic XOR neighbours on boot;
  // a
  // member that holds more replies with ONLY the missing entries. Bandwidth
  // is one small JSON each way when in sync; convergence is eventual (a
  // sampled member that is itself behind just yields nothing this round).

  /// Number of outbound XOR neighbours in the sparse chat-sync overlay.
  static const int kGroupSyncNeighbors = 5;
  static const int kMinGroupSyncNeighbors = 1;
  static const int kMaxGroupSyncNeighbors = 20;

  /// Compatibility name for debug/test callers from before the XOR overlay.
  @Deprecated('Use kGroupSyncNeighbors')
  static const int kGroupSyncFanout = kGroupSyncNeighbors;

  String _groupSyncNeighborsKey(NodeId groupId) =>
      'group.sync.neighbors:${groupId.hex}';

  /// Local outbound overlay degree for one chat. It is deliberately a local
  /// transport preference: each member may choose a different resource /
  /// redundancy trade-off without mutating the signed group policy.
  Future<int> groupSyncNeighborCount(NodeId groupId) async {
    final raw = await _storage.getSetting(_groupSyncNeighborsKey(groupId));
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null ||
        parsed < kMinGroupSyncNeighbors ||
        parsed > kMaxGroupSyncNeighbors) {
      return kGroupSyncNeighbors;
    }
    return parsed;
  }

  Future<void> setGroupSyncNeighborCount(NodeId groupId, int count) async {
    if (count < kMinGroupSyncNeighbors || count > kMaxGroupSyncNeighbors) {
      throw RangeError.range(
        count,
        kMinGroupSyncNeighbors,
        kMaxGroupSyncNeighbors,
        'count',
      );
    }
    await _storage.putSetting(
      _groupSyncNeighborsKey(groupId),
      count == kGroupSyncNeighbors ? '' : '$count',
    );
    changes.value++;
  }

  /// The compact "what I hold" vector for [groupId], or null when unknown.
  Future<Map<String, dynamic>?> buildGroupSyncRequest(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return null;
    return _buildGroupSyncRequest(b);
  }

  /// Build a sync vector from an already validated bundle. Snapshot and
  /// receipt paths use this to keep one coherent storage read per Space.
  Map<String, dynamic> _buildGroupSyncRequest(GroupBundle b) {
    final groupId = b.manifest.groupId;
    final syncState = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (entry) => _validControlFor(b.manifest, entry),
      initialName: b.manifest.name,
      initialDescription: b.manifest.description ?? '',
    ).state;
    final retainedMessages = _retainedMessageRows(b.manifest, b.messages)
        .where(
          (message) =>
              _messageWithinLifecycleBoundary(b.manifest, syncState, message),
        )
        .toList();
    final acceptedMessages = _acceptedMessagesWithinLifecycle(b, syncState);
    final acceptedReactions = _acceptedReactionsWithinLifecycle(b, syncState);
    Map<String, int> vector(Iterable<(NodeId, int)> entries) {
      final v = <String, int>{};
      for (final (a, s) in entries) {
        // Seqs start at 0 (_nextSeq), so the floor is -1 — with a 0 floor an
        // author whose ONLY entry is seq 0 was absent from the vector and the
        // responder (old default 0) never shipped seq-0 entries at all: the
        // FIRST lost entry of any author was unrecoverable (latent G1 bug,
        // caught by the reaction remainder).
        if (s > (v[a.hex] ?? -1)) v[a.hex] = s;
      }
      return v;
    }

    Map<String, Object> messageVector(Iterable<GroupMessage> messages) {
      final rows = messages.toList(growable: false);
      final result = <String, Object>{};
      final forks = _messageForks(b.manifest, rows);
      final authors = <String, NodeId>{
        for (final message in rows) message.author.hex: message.author,
      };
      for (final author in authors.values) {
        final authored = rows.where((message) => message.author == author);
        if (authored.isEmpty) continue;
        final scope = _messageChainScope(b.manifest, authored.first);
        final chain = _acceptedMessageChain(b.manifest, rows, author, scope);
        final fork = forks['$scope|${author.hex}'];
        final value = <String, Object>{
          's': chain.isEmpty ? -1 : chain.last.seq,
          if (chain.isNotEmpty) 'h': groupMessageHash(chain.last),
          if (fork != null)
            'f': {'s': fork.seq, 'h': fork.hashes.toList()..sort()},
        };
        result[author.hex] = value;
      }
      return result;
    }

    Map<String, Object> postVector() {
      final byAuthor = <String, List<SpacePost>>{};
      for (final post in _canonicalPostRows(groupId, b.posts).where(
        (post) =>
            !post.isLifecycleScoped &&
            _postWithinLifecycleBoundary(syncState, post),
      )) {
        byAuthor.putIfAbsent(post.author.hex, () => []).add(post);
      }
      final result = <String, Object>{};
      for (final entry in byAuthor.entries) {
        final authored = entry.value
          ..sort((left, right) => left.seq.compareTo(right.seq));
        var expectedSeq = 0;
        var expectedPrev = '';
        for (final post in authored) {
          if (post.seq != expectedSeq || post.prevHash != expectedPrev) break;
          result[entry.key] = {'s': post.seq, 'h': _spacePostHash(post)};
          expectedSeq++;
          expectedPrev = _spacePostHash(post);
        }
      }
      return result;
    }

    Map<String, Object> postGenerationVector() {
      final result = <String, Object>{};
      final generations = <String, Map<String, NodeId>>{};
      for (final post in _canonicalPostRows(groupId, b.posts)) {
        if (!post.isLifecycleScoped ||
            !_postWithinLifecycleBoundary(syncState, post)) {
          continue;
        }
        generations.putIfAbsent(
          _postGeneration(post),
          () => <String, NodeId>{},
        )[post.author.hex] = post.author;
      }
      for (final generation in generations.entries) {
        final vector = <String, Object>{};
        for (final author in generation.value.values) {
          final chain = _acceptedPostChain(
            groupId,
            b.posts,
            author,
            generationHash: generation.key,
          );
          if (chain.isNotEmpty) {
            vector[author.hex] = {
              's': chain.last.seq,
              'h': _spacePostHash(chain.last),
            };
          }
        }
        result[generation.key] = vector;
      }
      return result;
    }

    Map<String, Object> controlVector() {
      final result = <String, Object>{};
      for (final entry in _acceptedControl(b.manifest, b.control)) {
        final current = result[entry.author.hex];
        final currentSeq = current is Map && current['s'] is int
            ? current['s'] as int
            : -1;
        if (entry.seq > currentSeq) {
          result[entry.author.hex] = {
            's': entry.seq,
            'h': controlEntryHash(entry),
          };
        }
      }
      return result;
    }

    Map<String, Object> channelMessageVector() {
      final result = <String, Object>{};
      final byChannel = <String, List<GroupMessage>>{};
      for (final message in retainedMessages) {
        if (message.isChannelEncrypted) {
          byChannel
              .putIfAbsent(
                _messageChainScope(b.manifest, message),
                () => <GroupMessage>[],
              )
              .add(message);
        }
      }
      for (final entry in byChannel.entries) {
        result[entry.key] = messageVector(entry.value);
      }
      return result;
    }

    Map<String, Object> openChannelMessageVector() {
      final result = <String, Object>{};
      final byChannel = <String, List<GroupMessage>>{};
      for (final message in retainedMessages) {
        if (message.isChannelEncrypted) continue;
        final scope = _messageChainScope(b.manifest, message);
        byChannel.putIfAbsent(scope, () => <GroupMessage>[]).add(message);
      }
      for (final entry in byChannel.entries) {
        result[entry.key] = messageVector(entry.value);
      }
      return result;
    }

    Map<String, Object> groupMessageScopeVector() {
      final result = <String, Object>{};
      final byScope = <String, List<GroupMessage>>{};
      for (final message in retainedMessages) {
        final scope = _messageChainScope(b.manifest, message);
        byScope.putIfAbsent(scope, () => <GroupMessage>[]).add(message);
      }
      for (final entry in byScope.entries) {
        result[entry.key] = messageVector(entry.value);
      }
      return result;
    }

    Map<String, Object> channelReactionVector() {
      final result = <String, Object>{};
      final byScope = <String, List<GroupReaction>>{};
      for (final reaction in acceptedReactions) {
        if (!reaction.isChannelEncrypted) continue;
        byScope
            .putIfAbsent(_reactionSyncScope(reaction), () => <GroupReaction>[])
            .add(reaction);
      }
      for (final entry in byScope.entries) {
        result[entry.key] = vector(
          entry.value.map((reaction) => (reaction.author, reaction.seq)),
        );
      }
      return result;
    }

    Map<String, Object> publicCommentVector() {
      final result = <String, Object>{};
      final postIds = {
        for (final comment in b.publicComments)
          if (_validPublicCommentFor(groupId, comment)) comment.postId,
      };
      for (final postId in postIds) {
        final authors = {
          for (final comment in b.publicComments)
            if (comment.postId == postId &&
                _validPublicCommentFor(groupId, comment))
              comment.author,
        };
        final scoped = <String, Object>{};
        for (final author in authors) {
          final chain = _publicCommentChain(b, postId, author);
          if (chain != null && chain.isNotEmpty) {
            scoped[author.hex] = {
              's': chain.last.seq,
              'h': chain.last.recordHash,
            };
          }
        }
        if (scoped.isNotEmpty) result[postId] = scoped;
      }
      return result;
    }

    Map<String, Object> publicReactionVector() {
      final result = <String, Object>{};
      final postIds = {
        for (final reaction in b.publicReactions)
          if (_validPublicReactionFor(groupId, reaction)) reaction.postId,
      };
      for (final postId in postIds) {
        final authors = {
          for (final reaction in b.publicReactions)
            if (reaction.postId == postId &&
                _validPublicReactionFor(groupId, reaction))
              reaction.author,
        };
        final scoped = <String, Object>{};
        for (final author in authors) {
          final chain = _publicReactionChain(b, postId, author);
          if (chain != null && chain.isNotEmpty) {
            scoped[author.hex] = {
              's': chain.last.seq,
              'h': chain.last.recordHash,
            };
          }
        }
        if (scoped.isNotEmpty) result[postId] = scoped;
      }
      return result;
    }

    return {
      'sreq': 1,
      'gid': groupId.hex,
      // Legacy Space peers still consume the flat high-water vector. New
      // peers use `mg`, scoped by visible channel, so alternating between
      // channels cannot skip a lower-seq missing row.
      'g': vector(
        acceptedMessages
            .where((message) => !message.isChannelEncrypted)
            .map((message) => (message.author, message.seq)),
      ),
      if (!b.manifest.isSpace && !b.manifest.isSovereignDevice)
        'ms': groupMessageScopeVector(),
      if (b.manifest.isSpace) 'mg': openChannelMessageVector(),
      if (b.manifest.isSpace) 'cg': channelMessageVector(),
      // V2 adds the accepted head hash. A legacy peer treats the object value
      // as unseen and safely over-ships; a new peer detects same-seq forks
      // instead of declaring two different heads "in sync".
      'c': controlVector(),
      // Reactions ride the same per-author high-water scheme (each author's
      // reaction seq is monotonic). Protected reactions have an independent
      // per-channel vector: a higher public reaction seq must not hide a lower
      // missing channel row, and vice versa.
      'r': vector(
        acceptedReactions
            .where((reaction) => !reaction.isChannelEncrypted)
            .map((reaction) => (reaction.author, reaction.seq)),
      ),
      if (b.manifest.isSpace) 'cr': channelReactionVector(),
      if (b.manifest.isSpace) 'p': postVector(),
      if (b.manifest.isSpace) 'pg': postGenerationVector(),
      if (b.manifest.isSpace) 'pc': publicCommentVector(),
      if (b.manifest.isSpace) 'pr': publicReactionVector(),
      if (b.localEpochKeys.isNotEmpty)
        'ke': (b.localEpochKeys.keys.toList()..sort()),
      if (b.localChannelEpochKeys.isNotEmpty)
        'cke': (b.localChannelEpochKeys.keys.toList()..sort()),
    };
  }

  /// Answer a member's sync vector: ship ONLY the entries [peer] lacks (their
  /// vector's high-water per author, unseen author = everything). Non-members
  /// are dropped silently — no membership oracle. Returns whether a reply
  /// delta was sent.
  Future<bool> handleGroupSyncRequest(NodeId peer, Map req) async {
    final send = _send;
    if (send == null) return false;
    final gidHex = req['gid'];
    if (gidHex is! String || !(await _index()).contains(gidHex)) return false;
    final NodeId gid;
    try {
      gid = NodeId.fromHex(gidHex);
    } catch (_) {
      return false;
    }
    final b = await load(gid);
    if (b == null) return false;
    final attempt = Stopwatch()..start();
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final retention = b.manifest.isSpace
        ? await _materializedRetentionHistory(b, state)
        : null;
    final retireAtMs = _now();
    final retainedMessages = _retainedMessageRows(b.manifest, b.messages)
        .where(
          (message) =>
              _messageWithinLifecycleBoundary(b.manifest, state, message) &&
              (retention == null ||
                  !_retentionRetiresMessage(
                    manifest: b.manifest,
                    revisions: retention.revisions,
                    hiddenThroughMs: retention.hiddenThroughMs,
                    message: message,
                    atMs: retireAtMs,
                  )),
        )
        .toList();
    final localMessageForks = _messageForks(b.manifest, retainedMessages);
    if (!SpaceAcl(state).allows(peer, SpacePermission.distributeContent)) {
      devLog(() => 'xVeil[groups]: sync request from non-member — drop');
      if (b.manifest.isSpace) {
        _observeSpace(
          SpaceObservationType.aclDenied,
          SpaceObservationOutcome.rejected,
          reason: SpaceObservationReason.notMember,
        );
        _observeSpace(
          SpaceObservationType.p2pBackfill,
          SpaceObservationOutcome.rejected,
          reason: SpaceObservationReason.notMember,
          duration: attempt.elapsed,
        );
        if (_wasRevokedSpaceMember(b, peer)) {
          _observeSpace(
            SpaceObservationType.revokedDeliveryPrevented,
            SpaceObservationOutcome.rejected,
            reason: SpaceObservationReason.notMember,
          );
        }
      }
      return false;
    }
    // -1, not 0: seqs start at 0, so "never seen this author" must sit BELOW
    // the first seq or seq-0 entries can never gap-fill (see [vector]).
    int seen(Object? vec, NodeId author) {
      if (vec is! Map) return -1;
      final value = vec[author.hex];
      if (value is int) return value;
      if (value is Map && value['s'] is int) return value['s'] as int;
      return -1;
    }

    String? seenRowHash(Object? vec, NodeId author) {
      if (vec is! Map) return null;
      final value = vec[author.hex];
      return value is Map && value['h'] is String ? value['h'] as String : null;
    }

    bool hasRowHash(Object? vec, NodeId author) =>
        vec is Map &&
        vec[author.hex] is Map &&
        (vec[author.hex] as Map)['h'] is String;
    Set<String> knownForkHashes(Object? vec, NodeId author, int seq) {
      if (vec is! Map || vec[author.hex] is! Map) return const {};
      final fork = (vec[author.hex] as Map)['f'];
      if (fork is! Map || fork['s'] != seq || fork['h'] is! List) {
        return const {};
      }
      return (fork['h'] as List).whereType<String>().toSet();
    }

    String? seenControlHash(Object? vec, NodeId author) =>
        seenRowHash(vec, author);
    bool hasControlHash(Object? vec, NodeId author) => hasRowHash(vec, author);
    String? seenPostHash(Object? vec, NodeId author) =>
        seenRowHash(vec, author);
    bool hasPostHash(Object? vec, NodeId author) => hasRowHash(vec, author);
    Object? postVectorFor(SpacePost post) {
      if (!post.isLifecycleScoped) return req['p'];
      final generations = req['pg'];
      return generations is Map ? generations[_postGeneration(post)] : null;
    }

    final heldEpochs = req['ke'] is List
        ? (req['ke'] as List).whereType<int>().toSet()
        : const <int>{};
    final heldChannelEpochs = req['cke'] is List
        ? (req['cke'] as List).whereType<String>().toSet()
        : const <String>{};
    final missingEpochEnvelopes = [
      for (final envelope in _epochEnvelopesFor(b, peer))
        if (!heldEpochs.contains(envelope.epoch)) envelope,
    ];
    final missingChannelEpochEnvelopes = [
      for (final envelope in _channelEpochEnvelopesFor(b, peer))
        if (!heldChannelEpochs.contains(
          _channelKeyId(envelope.groupId, envelope.epoch),
        ))
          envelope,
    ];
    Object? messageVectorFor(GroupMessage message) {
      if (message.isChannelEncrypted) {
        final channels = req['cg'];
        if (channels is! Map) return null;
        return channels[_messageChainScope(b.manifest, message)] ??
            channels[message.channelId!.hex];
      }
      if (b.manifest.isSpace) {
        return req['mg'] is Map
            ? (req['mg'] as Map)[_messageChainScope(b.manifest, message)]
            : null;
      }
      if (!b.manifest.isSovereignDevice) {
        return req['ms'] is Map
            ? (req['ms'] as Map)[_messageChainScope(b.manifest, message)]
            : null;
      }
      return req['g'];
    }

    Object? reactionVectorFor(GroupReaction reaction) {
      if (!reaction.isChannelEncrypted) return req['r'];
      final channels = req['cr'];
      return channels is Map ? channels[_reactionSyncScope(reaction)] : null;
    }

    Object? publicVectorFor(String key, String postId) {
      final byPost = req[key];
      return byPost is Map ? byPost[postId] : null;
    }

    bool peerNeedsMessage(GroupMessage message) {
      if (!_validMessageFor(gid, message)) return false;
      final messageVector = messageVectorFor(message);
      final peerSeq = seen(messageVector, message.author);
      final scope = _messageChainScope(b.manifest, message);
      final fork = localMessageForks['$scope|${message.author.hex}'];
      final knownFork = fork == null
          ? const <String>{}
          : knownForkHashes(messageVector, message.author, fork.seq);
      bool missing;
      if (fork != null && message.seq >= fork.seq) {
        if (knownFork.containsAll(fork.hashes)) return false;
        // The conflicting rows themselves are sufficient evidence to
        // quarantine the suffix. Do not waste bandwidth shipping a suffix
        // that neither side may materialize until the fork is resolved by a
        // future explicit protocol.
        if (message.seq > fork.seq) return false;
        missing = !knownFork.contains(groupMessageHash(message));
      } else {
        missing =
            message.seq > peerSeq ||
            (message.seq == peerSeq &&
                hasRowHash(messageVector, message.author) &&
                seenRowHash(messageVector, message.author) !=
                    groupMessageHash(message));
      }
      if (!missing) return false;
      if (message.isChannelEncrypted) {
        return _peerCanDecryptChannelEpoch(
          b,
          peer,
          message.channelId!,
          message.channelEpoch!,
        );
      }
      return !_encryptionEstablished(b.manifest, b.control) ||
          (message.isEncrypted &&
              _peerCanDecryptEpoch(b, peer, message.membershipEpoch!));
    }

    final missingMsgs = [
      for (final message in retainedMessages)
        if (peerNeedsMessage(message)) message,
    ];
    final missingCtl = [
      for (final e in b.control)
        if (_validControlFor(b.manifest, e) &&
            (e.seq > seen(req['c'], e.author) ||
                (e.seq == seen(req['c'], e.author) &&
                    hasControlHash(req['c'], e.author) &&
                    seenControlHash(req['c'], e.author) !=
                        controlEntryHash(e))))
          e,
    ];
    // A requester from before the 'r' vector sends none — `seen` reads 0 and
    // every held reaction ships; the ingest dedup by (author, seq) makes the
    // over-send harmless.
    final missingRx = [
      for (final r in _acceptedReactionsWithinLifecycle(b, state))
        if (_validReactionFor(gid, r) &&
            (retention == null ||
                !_retentionRetiresReaction(
                  manifest: b.manifest,
                  revisions: retention.revisions,
                  hiddenThroughMs: retention.hiddenThroughMs,
                  reaction: r,
                  atMs: retireAtMs,
                )) &&
            r.seq > seen(reactionVectorFor(r), r.author) &&
            (r.isChannelEncrypted
                ? _peerCanDecryptChannelEpoch(
                    b,
                    peer,
                    r.channelId!,
                    r.channelEpoch!,
                  )
                : !_encryptionEstablished(b.manifest, b.control) ||
                      (r.isMembershipEncrypted &&
                          _peerCanDecryptEpoch(b, peer, r.membershipEpoch!))))
          r,
    ];
    final missingPosts = [
      for (final post in _retainedPostRows(gid, b.posts))
        if (_validPostFor(gid, post) &&
            _postWithinLifecycleBoundary(state, post) &&
            (retention == null ||
                !_retentionRetiresPost(
                  manifest: b.manifest,
                  state: state,
                  revisions: retention.revisions,
                  post: post,
                  atMs: retireAtMs,
                )) &&
            (post.seq > seen(postVectorFor(post), post.author) ||
                (post.seq == seen(postVectorFor(post), post.author) &&
                    hasPostHash(postVectorFor(post), post.author) &&
                    seenPostHash(postVectorFor(post), post.author) !=
                        _spacePostHash(post))) &&
            (!post.isEncrypted ||
                _peerCanDecryptEpoch(b, peer, post.membershipEpoch!)))
          post,
    ];
    final missingPublicComments = [
      for (final comment in b.publicComments)
        if (_validPublicCommentFor(gid, comment) &&
            comment.lifecycleGeneration ==
                (state.lifecycleTransitionHash ?? _legacyPostGeneration(gid)) &&
            (comment.seq >
                    seen(
                      publicVectorFor('pc', comment.postId),
                      comment.author,
                    ) ||
                (comment.seq ==
                        seen(
                          publicVectorFor('pc', comment.postId),
                          comment.author,
                        ) &&
                    hasRowHash(
                      publicVectorFor('pc', comment.postId),
                      comment.author,
                    ) &&
                    seenRowHash(
                          publicVectorFor('pc', comment.postId),
                          comment.author,
                        ) !=
                        comment.recordHash)))
          comment,
    ];
    final missingPublicReactions = [
      for (final reaction in b.publicReactions)
        if (_validPublicReactionFor(gid, reaction) &&
            reaction.lifecycleGeneration ==
                (state.lifecycleTransitionHash ?? _legacyPostGeneration(gid)) &&
            (reaction.seq >
                    seen(
                      publicVectorFor('pr', reaction.postId),
                      reaction.author,
                    ) ||
                (reaction.seq ==
                        seen(
                          publicVectorFor('pr', reaction.postId),
                          reaction.author,
                        ) &&
                    hasRowHash(
                      publicVectorFor('pr', reaction.postId),
                      reaction.author,
                    ) &&
                    seenRowHash(
                          publicVectorFor('pr', reaction.postId),
                          reaction.author,
                        ) !=
                        reaction.recordHash)))
          reaction,
    ];
    final missingCount =
        missingCtl.length +
        missingMsgs.length +
        missingRx.length +
        missingPosts.length +
        missingPublicComments.length +
        missingPublicReactions.length +
        missingEpochEnvelopes.length +
        missingChannelEpochEnvelopes.length;
    final repairFingerprint = b.manifest.isSpace && missingCount > 0
        ? _spaceRepairFingerprint(
            controls: missingCtl,
            messages: missingMsgs,
            reactions: missingRx,
            posts: missingPosts,
            publicComments: missingPublicComments,
            publicReactions: missingPublicReactions,
            epochEnvelopes: missingEpochEnvelopes,
            channelEpochEnvelopes: missingChannelEpochEnvelopes,
          )
        : null;
    _AcceptedSpaceReceipt? acceptedReceipt;
    if (b.manifest.isSpace) {
      _observeSpace(
        SpaceObservationType.p2pMissingObjects,
        missingCount == 0
            ? SpaceObservationOutcome.noOp
            : SpaceObservationOutcome.succeeded,
        amount: missingCount,
      );
      if (missingCount > 0) {
        _spaceHolderProofs.remove(_spaceHolderProofKey(gid, peer));
      }
      acceptedReceipt = await _acceptSpaceReceipt(
        peer,
        b,
        req['rack'],
        caughtUp: missingCount == 0,
      );
      if (repairFingerprint != null &&
          acceptedReceipt?.repairFingerprint == repairFingerprint) {
        final token = req['rack'];
        if (token is String) {
          _rememberStalledSpaceReceipt(token, gid, peer, repairFingerprint);
        }
        _observeSpace(
          SpaceObservationType.p2pBackfill,
          SpaceObservationOutcome.noOp,
          reason: SpaceObservationReason.duplicate,
          amount: missingCount,
          duration: attempt.elapsed,
        );
        return false;
      }
    }
    if (missingMsgs.isEmpty &&
        missingCtl.isEmpty &&
        missingRx.isEmpty &&
        missingPosts.isEmpty &&
        missingPublicComments.isEmpty &&
        missingPublicReactions.isEmpty &&
        missingEpochEnvelopes.isEmpty &&
        missingChannelEpochEnvelopes.isEmpty) {
      if (b.manifest.isSpace) {
        _observeSpace(
          SpaceObservationType.p2pBackfill,
          SpaceObservationOutcome.noOp,
          amount: 0,
          duration: attempt.elapsed,
        );
      }
      return false;
    }
    final overlayId =
        b.manifest.name != kDeviceGroupName &&
            missingCtl.isEmpty &&
            (missingMsgs.isNotEmpty ||
                missingRx.isNotEmpty ||
                missingPosts.isNotEmpty ||
                missingPublicComments.isNotEmpty ||
                missingPublicReactions.isNotEmpty)
        ? _overlayDeltaId(
            gid,
            missingMsgs,
            missingRx,
            missingPosts,
            missingPublicComments,
            missingPublicReactions,
          )
        : null;
    if (overlayId != null) _rememberOverlayDelta(overlayId);
    // Cuts covering the read-time-excluded prefix so the peer can re-anchor the
    // retained suffix served above even before either side has swept.
    final syncServeCuts = retention == null
        ? b.retentionCuts
        : _serveRetentionCuts(
            b,
            retention.revisions,
            retention.hiddenThroughMs,
            retireAtMs,
          );
    final receipt = _beginSpaceReceipt(
      b,
      peer,
      repairFingerprint: repairFingerprint,
    );
    try {
      await send(
        peer,
        gid,
        jsonEncode({
          'm': b.manifest.toJson(),
          'c': [for (final e in missingCtl) e.toJson()],
          'g': [for (final m in missingMsgs) m.toJson()],
          'r': [for (final r in missingRx) r.toJson()],
          if (missingPosts.isNotEmpty)
            'p': [for (final post in missingPosts) post.toJson()],
          if (missingPublicComments.isNotEmpty)
            'pc': [
              for (final comment in missingPublicComments) comment.toJson(),
            ],
          if (missingPublicReactions.isNotEmpty)
            'pr': [
              for (final reaction in missingPublicReactions) reaction.toJson(),
            ],
          if (missingEpochEnvelopes.isNotEmpty)
            'ke': [
              for (final envelope in missingEpochEnvelopes) envelope.toJson(),
            ],
          if (missingChannelEpochEnvelopes.isNotEmpty)
            'cke': [
              for (final envelope in missingChannelEpochEnvelopes)
                envelope.toJson(),
            ],
          if (syncServeCuts.isNotEmpty)
            'rcut': [for (final cut in syncServeCuts.values) cut.toJson()],
          'ov': ?overlayId,
          'rcpt': ?receipt,
        }),
      );
    } catch (_) {
      _cancelSpaceReceipt(receipt);
      if (b.manifest.isSpace) {
        _observeSpace(
          SpaceObservationType.p2pBackfill,
          SpaceObservationOutcome.failed,
          reason: SpaceObservationReason.transportFailed,
          amount: missingCount,
          duration: attempt.elapsed,
        );
      }
      rethrow;
    }
    if (b.manifest.isSpace) {
      _observeSpace(
        SpaceObservationType.p2pBackfill,
        SpaceObservationOutcome.succeeded,
        amount: missingCount,
        duration: attempt.elapsed,
      );
    }
    return true;
  }

  /// Route one inbound group-entry payload from [peer]: a sync VECTOR is
  /// answered (membership-gated), anything else is the normal idempotent
  /// snapshot/delta ingest. The wire wiring points here instead of calling
  /// [ingestSnapshot] directly.
  Future<bool> ingestGroupEntry(NodeId peer, String json) async {
    Map? decoded;
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
      if (d is Map) decoded = d;
    } catch (_) {
      return false; // malformed — drop
    }
    final pending = await _tryPendingDeviceSnapshot(peer, json);
    if (pending != null) return pending;
    PendingSpaceInvite? acceptedInvite;
    SpaceJoinOutboxEntry? acceptedJoinRequest;
    final manifest = GroupManifest.fromJson(decoded?['m']);
    if (manifest != null &&
        manifest.isSpace &&
        await load(manifest.groupId) == null) {
      acceptedInvite = await _acceptedSpaceInviteFor(peer, manifest, decoded!);
      acceptedJoinRequest = await _acceptedSpaceJoinRequestFor(
        peer,
        manifest,
        decoded,
      );
      if (acceptedInvite == null && acceptedJoinRequest == null) {
        devLog(
          () =>
              'xVeil[spaces]: unsolicited materialization DENIED — consent '
              'required',
        );
        return false;
      }
    }
    final accepted = await ingestSnapshot(json);
    if (accepted && acceptedInvite != null) {
      await _consumeAcceptedSpaceInvite(acceptedInvite.invite.inviteId);
    }
    if (accepted && decoded != null) {
      await _acknowledgeSpaceReceipt(peer, decoded);
      await _relayOverlayDelta(peer, decoded);
    }
    return accepted;
  }

  Future<SpaceJoinOutboxEntry?> _acceptedSpaceJoinRequestFor(
    NodeId peer,
    SpaceManifest manifest,
    Map wire,
  ) async {
    if (manifest.visibility != SpaceVisibility.public) return null;
    SpaceJoinOutboxEntry? pending;
    for (final candidate in await outgoingSpaceJoinRequests()) {
      if (!candidate.declined &&
          candidate.request.spaceId == manifest.spaceId &&
          candidate.request.approver == peer &&
          candidate.request.requester == selfId) {
        pending = candidate;
        break;
      }
    }
    if (pending == null) return null;
    final control = (wire['c'] as List? ?? const [])
        .map(ControlEntry.fromJson)
        .whereType<ControlEntry>()
        .where((entry) => _validControlFor(manifest, entry))
        .toList();
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
      initialDescription: manifest.description ?? '',
    );
    final grantAccepted = folded.accepted.any(
      (entry) =>
          entry.op == ControlOp.addMember &&
          entry.author == peer &&
          entry.target == selfId &&
          (entry.role ?? GroupRole.member) == GroupRole.member &&
          entry.createdAtMs >= pending!.request.createdAtMs &&
          entry.createdAtMs <= pending.ticket.expiresAtMs,
    );
    if (!grantAccepted ||
        !folded.state.isMember(selfId) ||
        !folded.state.isMember(peer)) {
      return null;
    }
    return pending;
  }

  Future<PendingSpaceInvite?> _acceptedSpaceInviteFor(
    NodeId peer,
    SpaceManifest manifest,
    Map wire,
  ) async {
    PendingSpaceInvite? pending;
    for (final candidate in await pendingSpaceInvites()) {
      if (candidate.accepted &&
          candidate.invite.spaceId == manifest.spaceId &&
          candidate.invite.inviter == peer &&
          candidate.invite.invitee == selfId) {
        pending = candidate;
      }
    }
    if (pending == null) return null;
    final control = (wire['c'] as List? ?? const [])
        .map(ControlEntry.fromJson)
        .whereType<ControlEntry>()
        .where((entry) => _validControlFor(manifest, entry))
        .toList();
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    final grantAccepted = folded.accepted.any(
      (entry) =>
          entry.op == ControlOp.addMember &&
          entry.author == peer &&
          entry.target == selfId &&
          (entry.role ?? GroupRole.member) == pending!.invite.role,
    );
    if (!grantAccepted ||
        !folded.state.isMember(selfId) ||
        !folded.state.isMember(peer)) {
      return null;
    }
    return pending;
  }

  Future<void> _consumeAcceptedSpaceInvite(String inviteId) =>
      _serializeSpaceInvites(() async {
        final store = await _loadSpaceInvites();
        await _saveSpaceInvites(
          incoming: [
            for (final entry in store.incoming)
              if (entry.invite.inviteId != inviteId) entry,
          ],
          outgoing: store.outgoing,
        );
        changes.value++;
      });

  /// The NON-contact variant of [ingestGroupEntry]: a member's sync vector is
  /// answered (the handler's own membership gate is the same admission), a
  /// bundle goes through the stranger-guarded ingest.
  Future<bool> ingestGroupEntryFromStranger(NodeId peer, String json) async {
    Map? decoded;
    try {
      final d = jsonDecode(json);
      if (d is Map && d['sreq'] == 1) return handleGroupSyncRequest(peer, d);
      if (d is Map) decoded = d;
    } catch (_) {
      return false; // malformed — drop
    }
    SpaceJoinOutboxEntry? acceptedJoinRequest;
    final manifest = GroupManifest.fromJson(decoded?['m']);
    if (manifest != null &&
        manifest.isSpace &&
        await load(manifest.groupId) == null) {
      acceptedJoinRequest = await _acceptedSpaceJoinRequestFor(
        peer,
        manifest,
        decoded!,
      );
    }
    final accepted = acceptedJoinRequest == null
        ? await ingestSnapshotFromStranger(peer, json)
        : await ingestSnapshot(json);
    if (accepted && decoded != null) {
      await _acknowledgeSpaceReceipt(peer, decoded);
      await _relayOverlayDelta(peer, decoded);
    }
    return accepted;
  }

  Future<void> _relayOverlayDelta(NodeId source, Map wire) async {
    final overlayId = wire['ov'];
    if (overlayId is! String || overlayId.length != 64) return;
    final manifest = GroupManifest.fromJson(wire['m']);
    if (manifest == null ||
        wire['c'] is! List ||
        (wire['c'] as List).isNotEmpty) {
      return;
    }
    final messages = (wire['g'] as List? ?? const [])
        .map(GroupMessage.fromJson)
        .whereType<GroupMessage>()
        .toList();
    final reactions = (wire['r'] as List? ?? const [])
        .map(GroupReaction.fromJson)
        .whereType<GroupReaction>()
        .toList();
    final posts = (wire['p'] as List? ?? const [])
        .map(SpacePost.fromJson)
        .whereType<SpacePost>()
        .toList();
    final publicComments = (wire['pc'] as List? ?? const [])
        .map(SpacePublicComment.fromJson)
        .whereType<SpacePublicComment>()
        .toList();
    final publicReactions = (wire['pr'] as List? ?? const [])
        .map(SpacePublicReaction.fromJson)
        .whereType<SpacePublicReaction>()
        .toList();
    if (messages.isEmpty &&
        reactions.isEmpty &&
        posts.isEmpty &&
        publicComments.isEmpty &&
        publicReactions.isEmpty) {
      return;
    }
    if (_overlayDeltaId(
          manifest.groupId,
          messages,
          reactions,
          posts,
          publicComments,
          publicReactions,
        ) !=
        overlayId) {
      return;
    }
    // Relay the validated rows we actually persisted, never attacker-supplied
    // lookalikes that merely reuse a legitimate (author, seq) identity.
    final stored = await load(manifest.groupId);
    if (stored == null) return;
    GroupMessage? storedMessage(GroupMessage incoming) {
      for (final candidate in stored.messages) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    GroupReaction? storedReaction(GroupReaction incoming) {
      for (final candidate in stored.reactions) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    SpacePost? storedPost(SpacePost incoming) {
      for (final candidate in stored.posts) {
        if (candidate.author == incoming.author &&
            candidate.seq == incoming.seq &&
            jsonEncode(candidate.toJson()) == jsonEncode(incoming.toJson())) {
          return candidate;
        }
      }
      return null;
    }

    SpacePublicComment? storedPublicComment(SpacePublicComment incoming) {
      for (final candidate in stored.publicComments) {
        if (candidate.recordHash == incoming.recordHash) return candidate;
      }
      return null;
    }

    SpacePublicReaction? storedPublicReaction(SpacePublicReaction incoming) {
      for (final candidate in stored.publicReactions) {
        if (candidate.recordHash == incoming.recordHash) return candidate;
      }
      return null;
    }

    final validMessages = messages
        .map(storedMessage)
        .whereType<GroupMessage>()
        .toList();
    final validReactions = reactions
        .map(storedReaction)
        .whereType<GroupReaction>()
        .toList();
    final validPosts = posts.map(storedPost).whereType<SpacePost>().toList();
    final validPublicComments = publicComments
        .map(storedPublicComment)
        .whereType<SpacePublicComment>()
        .toList();
    final validPublicReactions = publicReactions
        .map(storedPublicReaction)
        .whereType<SpacePublicReaction>()
        .toList();
    if (validMessages.length != messages.length ||
        validReactions.length != reactions.length ||
        validPosts.length != posts.length ||
        validPublicComments.length != publicComments.length ||
        validPublicReactions.length != publicReactions.length ||
        !_rememberOverlayDelta(overlayId)) {
      return;
    }
    await broadcastDelta(
      manifest.groupId,
      messages: validMessages,
      reactions: validReactions,
      posts: validPosts,
      publicComments: validPublicComments,
      publicReactions: validPublicReactions,
      exclude: {source},
      overlayId: overlayId,
    );
  }

  /// Boot catch-up for EVERY group. Chat groups use the same deterministic
  /// XOR neighbours as live deltas; device groups retain all-device delivery.
  /// Cheap when in sync (one small JSON), and the reply path ships only what
  /// this device actually lacks.
  Future<void> nudgeGroupSyncAll() async {
    for (final gidHex in await _index()) {
      final NodeId gid;
      try {
        gid = NodeId.fromHex(gidHex);
      } catch (_) {
        continue;
      }
      final beforeUpgrade = await load(gid);
      final beforeState = beforeUpgrade == null
          ? null
          : foldControlLog(
              owner: beforeUpgrade.manifest.owner,
              entries: beforeUpgrade.control,
              verify: (entry) =>
                  _validControlFor(beforeUpgrade.manifest, entry),
              initialName: beforeUpgrade.manifest.name,
            ).state;
      if (_epochService != null &&
          beforeUpgrade != null &&
          beforeUpgrade.manifest.name != kDeviceGroupName &&
          beforeUpgrade.manifest.owner == _signer.selfId &&
          beforeState != null &&
          !_encryptionEstablished(
            beforeUpgrade.manifest,
            beforeUpgrade.control,
          )) {
        // One-time migration for legacy groups: the genesis owner establishes
        // the first signed epoch and fans its recipient envelopes on boot.
        await addControlOp(gid, ControlOp.rotateEpoch);
      }
      await compactStateLogs(gid);
      await nudgeGroupSync(gid);
    }
  }

  /// Starts one compact anti-entropy exchange with this chat's current XOR
  /// neighbours. Used at boot and immediately after changing the local `k`.
  Future<int> nudgeGroupSync(NodeId groupId) async {
    final send = _send;
    if (send == null) return 0;
    final bundle = await load(groupId);
    if (bundle == null) return 0;
    final req = _buildGroupSyncRequest(bundle);
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    int? neighborCount;
    Future<int> readNeighborCount() async =>
        neighborCount ??= await groupSyncNeighborCount(groupId);
    final others = <NodeId>[
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId &&
            (!bundle.manifest.isSovereignDevice ||
                member.nodeId != bundle.manifest.owner))
          member.nodeId,
    ];
    final basePeers = bundle.manifest.name == kDeviceGroupName
        ? others
        : nearestGroupNodesByXor(
            _signer.selfId,
            others,
            k: await readNeighborCount(),
          );
    final peersById = <String, NodeId>{
      for (final peer in basePeers) peer.hex: peer,
    };
    if (bundle.manifest.isSpace) {
      final protected = await _protectedChannelsOf(bundle, state);
      final k = await readNeighborCount();
      for (final clear in protected.values) {
        for (final peer in nearestGroupNodesByXor(
          _signer.selfId,
          clear.recipients,
          k: k,
        )) {
          peersById[peer.hex] = peer;
        }
      }
    }
    final peers = peersById.values.toList()
      ..sort((left, right) => left.hex.compareTo(right.hex));
    for (final peer in peers) {
      await send(peer, groupId, jsonEncode(req));
    }
    return peers.length;
  }

  /// The VALIDATED, time-ordered messages of [groupId]: signature ok AND the
  /// author is a non-muted member of the current state. (A finer per-message
  /// membership-at-its-policy-version check is a later refinement.)
  Future<List<GroupMessage>> messagesOf(
    NodeId groupId, {
    NodeId? channelId,
    String? spacePostId,
    bool includeSpacePostComments = false,
    bool applyLocalRetention = true,
  }) async {
    final b = await load(groupId);
    if (b == null) return const [];
    return _messagesOfBundle(
      b,
      channelId: channelId,
      spacePostId: spacePostId,
      includeSpacePostComments: includeSpacePostComments,
      applyLocalRetention: applyLocalRetention,
    );
  }

  /// Materialize messages from a bundle the caller already loaded. This is
  /// intentionally private: all external reads still validate through [load],
  /// while aggregate diagnostics avoid decoding the same durable bundle twice.
  Future<List<GroupMessage>> _messagesOfBundle(
    GroupBundle b, {
    NodeId? channelId,
    String? spacePostId,
    bool includeSpacePostComments = false,
    bool applyLocalRetention = true,
  }) async {
    final groupId = b.manifest.groupId;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final readAt = DateTime.now().millisecondsSinceEpoch;
    final reader = state.memberOf(_signer.selfId);
    if (b.manifest.isSpace && (reader == null || state.isDeleted)) {
      return const [];
    }
    final localCutoff = b.manifest.isSpace && applyLocalRetention
        ? await _localSpaceRetentionCutoff(groupId, readAt)
        : -1;
    final protected = b.manifest.isSpace
        ? await _protectedChannelsOf(b, state)
        : const <String, SpaceChannelControlCleartext>{};
    final retention = b.manifest.isSpace
        ? await _materializedRetentionHistory(
            b,
            state,
            currentChannels: protected,
          )
        : null;
    final protectedModeration = b.manifest.isSpace
        ? await _protectedModerationRecordsOf(b, state)
        : const <SpaceModerationRecord>[];
    final out = <GroupMessage>[];
    for (final m in _acceptedMessagesWithinLifecycle(b, state)) {
      var mediaExpired = false;
      final isComment = m.spacePostId != null;
      if (spacePostId == null
          ? isComment && !includeSpacePostComments
          : m.spacePostId != spacePostId) {
        continue;
      }
      final effectiveChannelId = b.manifest.isSpace && !isComment
          ? m.channelId ?? defaultSpaceChannelId(groupId)
          : null;
      if (b.manifest.isSpace) {
        if (isComment) {
          if (channelId != null ||
              m.channelId != null ||
              m.isChannelEncrypted) {
            continue;
          }
        } else {
          final effectiveChannel = effectiveChannelId!;
          final protectedChannel = protected[effectiveChannel.hex];
          final channel =
              state.channels[effectiveChannel.hex] ?? protectedChannel?.channel;
          if (channel == null ||
              (channelId != null && effectiveChannel != channelId)) {
            continue;
          }
          if ((protectedChannel != null && !m.isChannelEncrypted) ||
              (protectedChannel == null && m.isChannelEncrypted)) {
            continue;
          }
          final historyAllows = switch (channel.history) {
            // Equal wall-clock milliseconds are causally ambiguous across
            // authors. Exclude them: history access is fail-closed.
            SpaceChannelHistory.fromJoin => m.createdAtMs > reader!.joinedAtMs,
            SpaceChannelHistory.since =>
              m.createdAtMs >= channel.historySinceMs!,
            SpaceChannelHistory.full => true,
          };
          if (!historyAllows) continue;
        }
        final hiddenThrough = effectiveChannelId == null
            ? null
            : retention!.hiddenThroughMs[effectiveChannelId.hex];
        if ((hiddenThrough != null && m.createdAtMs <= hiddenThrough) ||
            spaceRetentionRemoves(
              revisions: retention!.revisions,
              createdAtMs: m.createdAtMs,
              atMs: readAt,
              channelId: effectiveChannelId,
            ) ||
            m.createdAtMs <= localCutoff) {
          continue;
        }
        mediaExpired = spaceRetentionRemovesMedia(
          revisions: retention.revisions,
          createdAtMs: m.createdAtMs,
          atMs: readAt,
          channelId: effectiveChannelId,
        );
      } else if (channelId != null) {
        continue;
      }
      if (!SpaceAcl(state).allows(
            m.author,
            SpacePermission.publishMessages,
            atMs: m.createdAtMs,
            channelId: effectiveChannelId,
          ) ||
          (b.manifest.isSpace &&
              (state.isModeratedContentRemoved(
                    kind: isComment
                        ? SpaceModerationReferenceKind.spacePostComment
                        : SpaceModerationReferenceKind.message,
                    author: m.author,
                    seq: m.seq,
                    atMs: readAt,
                    channelId: effectiveChannelId,
                  ) ||
                  spaceModerationRemovesContent(
                    protectedModeration,
                    kind: isComment
                        ? SpaceModerationReferenceKind.spacePostComment
                        : SpaceModerationReferenceKind.message,
                    author: m.author,
                    seq: m.seq,
                    atMs: readAt,
                    channelId: effectiveChannelId,
                  )))) {
        continue;
      }
      if (!m.isEncrypted) {
        out.add(
          mediaExpired && m.attachment != null
              ? m.withMediaHiddenByRetention()
              : m,
        );
        continue;
      }
      final materialized = await _materializeEncryptedMessage(b, m);
      if (materialized != null) {
        out.add(
          mediaExpired && materialized.attachment != null
              ? materialized.withMediaHiddenByRetention()
              : materialized,
        );
      }
    }
    out.sort((a, b) {
      final t = a.createdAtMs.compareTo(b.createdAtMs);
      if (t != 0) return t;
      final h = a.author.hex.compareTo(b.author.hex);
      if (h != 0) return h;
      return a.seq.compareTo(b.seq);
    });
    return out;
  }

  Future<List<SpacePostCommentView>> spacePostCommentsOf(
    NodeId spaceId,
    String postId, {
    bool applyLocalRetention = true,
  }) async {
    if (!_spacePostIdPattern.hasMatch(postId)) return const [];
    final posts = await postsOf(spaceId);
    if (!posts.any((post) => post.postId == postId)) return const [];
    final comments = await messagesOf(
      spaceId,
      spacePostId: postId,
      applyLocalRetention: applyLocalRetention,
    );
    return _withoutBlockedSpaceAuthors(
      _projectSpacePostComments(comments),
      (comment) => comment.author,
    );
  }

  /// Relationship blocks are identity-local and never enter a Space log.
  /// Storage errors fail closed for non-self authors so a previously blocked
  /// identity cannot flash back into comments or mention surfaces.
  Future<bool> isSpaceAuthorBlocked(NodeId author) async {
    if (author == _signer.selfId) return false;
    try {
      return (await _storage.getContact(author))?.status ==
          ContactStatus.blocked;
    } catch (_) {
      return true;
    }
  }

  Future<List<T>> _withoutBlockedSpaceAuthors<T>(
    Iterable<T> values,
    NodeId Function(T value) authorOf,
  ) async {
    final blocked = <String, Future<bool>>{};
    final visible = <T>[];
    for (final value in values) {
      final author = authorOf(value);
      final hidden = await blocked.putIfAbsent(
        author.hex,
        () => isSpaceAuthorBlocked(author),
      );
      if (!hidden) visible.add(value);
    }
    return List<T>.unmodifiable(visible);
  }

  /// Validated publications and all of their effective comments, projected
  /// with one message-log read. Aggregate consumers such as the mention inbox
  /// must not call [spacePostCommentsOf] once per post: that would repeatedly
  /// decrypt and validate the same Space log on larger histories.
  Future<
    ({
      List<SpacePostView> posts,
      Map<String, List<SpacePostCommentView>> commentsByPost,
    })
  >
  spacePostsAndCommentsOf(
    NodeId spaceId, {
    bool applyLocalRetention = true,
  }) async {
    final posts = await postsOf(spaceId);
    if (posts.isEmpty) {
      return (
        posts: posts,
        commentsByPost: const <String, List<SpacePostCommentView>>{},
      );
    }
    final visiblePostIds = {for (final post in posts) post.postId};
    final messages = await messagesOf(
      spaceId,
      includeSpacePostComments: true,
      applyLocalRetention: applyLocalRetention,
    );
    final grouped = <String, List<GroupMessage>>{};
    for (final message in messages) {
      final postId = message.spacePostId;
      if (postId == null || !visiblePostIds.contains(postId)) continue;
      (grouped[postId] ??= <GroupMessage>[]).add(message);
    }
    return (
      posts: posts,
      commentsByPost: Map<String, List<SpacePostCommentView>>.unmodifiable({
        for (final entry in grouped.entries)
          entry.key: _projectSpacePostComments(entry.value),
      }),
    );
  }

  List<SpacePostCommentView> _projectSpacePostComments(
    List<GroupMessage> comments,
  ) {
    final roots = [
      for (final comment in comments)
        if (comment.editOf == null && comment.deleteOf == null) comment,
    ];
    final byRef = {for (final comment in roots) comment.ref: comment};
    final revisions = <String, GroupMessage>{};
    for (final revision in comments.where(
      (comment) => comment.editOf != null || comment.deleteOf != null,
    )) {
      if (revision.editOf != null && revision.deleteOf != null) continue;
      final target = byRef[revision.editOf ?? revision.deleteOf];
      if (target == null ||
          revision.author != target.author ||
          revision.seq <= target.seq ||
          revision.attachment != null ||
          revision.replyTo != null ||
          (revision.editOf != null &&
              revision.body.trim().isEmpty &&
              target.attachment == null) ||
          (revision.deleteOf != null && revision.body.isNotEmpty)) {
        continue;
      }
      final current = revisions[target.ref];
      // A tombstone is irreversible even if a hostile signer appends a later
      // edit or timestamps rows out of order. Any valid delete therefore wins
      // over every edit for the same stable root.
      if (current?.deleteOf != null) continue;
      if (revision.deleteOf != null ||
          current == null ||
          revision.seq > current.seq) {
        revisions[target.ref] = revision;
      }
    }
    final refs = byRef.keys.toSet();
    return List.unmodifiable([
      for (final comment in roots)
        if ((comment.replyTo == null || refs.contains(comment.replyTo)) &&
            revisions[comment.ref]?.deleteOf == null)
          SpacePostCommentView(root: comment, revision: revisions[comment.ref]),
    ]);
  }

  /// Toggle our reaction [emoji] on [msgRef] (`<authorHex>:<seq>`):
  /// reacting with the emoji we already have removes it. Rejected (false) if we
  /// are not a non-muted member. The signed reaction is delta-broadcast.
  /// [broadcast]=false stores the signed reaction WITHOUT the delta fanout —
  /// the deterministic "lost reaction" for gap-fill tests (like
  /// [postMessage]'s flag).
  Future<bool> react(
    NodeId groupId,
    String msgRef,
    String emoji, {
    bool broadcast = true,
  }) => _serialized(
    groupId,
    () => _react(
      groupId,
      msgRef,
      emoji,
      targetKind: ReactionTargetKind.message,
      broadcast: broadcast,
    ),
  );

  /// Toggle a reaction on an effective Space publication root. Revisions keep
  /// the same [postId], while a tombstone makes the target unavailable.
  Future<bool> reactToSpacePost(
    NodeId spaceId,
    String postId,
    String emoji, {
    bool publiclyVisible = false,
    bool broadcast = true,
  }) => _serialized(
    spaceId,
    () => _react(
      spaceId,
      postId,
      emoji,
      targetKind: ReactionTargetKind.spacePost,
      publiclyVisible: publiclyVisible,
      broadcast: broadcast,
    ),
  );

  Future<bool> _react(
    NodeId groupId,
    String target,
    String emoji, {
    required ReactionTargetKind targetKind,
    bool publiclyVisible = false,
    bool broadcast = true,
  }) async {
    final b = await load(groupId);
    if (b == null) return false;
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    if (b.manifest.isSpace && state.isDeleted) return false;
    if (utf8.encode(emoji).length > 64) return false;
    GroupMessage? targetMessage;
    if (targetKind == ReactionTargetKind.message) {
      for (final message in await messagesOf(groupId)) {
        if (message.ref == target) {
          targetMessage = message;
          break;
        }
      }
      if (targetMessage == null) return false;
    }
    SpacePostView? targetPost;
    if (targetKind == ReactionTargetKind.spacePost) {
      if (!b.manifest.isSpace) return false;
      targetPost = (await postsOf(
        groupId,
      )).where((post) => post.postId == target).firstOrNull;
      if (targetPost == null) return false;
      if (publiclyVisible &&
          (b.manifest.visibility != SpaceVisibility.public ||
              targetPost.visibility != SpacePostVisibility.public)) {
        return false;
      }
    }
    if (!SpaceAcl(state).allows(
      _signer.selfId,
      SpacePermission.publishMessages,
      channelId: targetMessage?.channelId,
    )) {
      return false;
    }
    // My current reaction on this message (if any) → tapping it again clears it.
    final visibleReactions = <GroupReaction>[];
    for (final reaction in _acceptedReactionsWithinLifecycle(b, state)) {
      if (!SpaceAcl(state).allows(
        reaction.author,
        SpacePermission.publishMessages,
        atMs: reaction.createdAtMs,
      )) {
        continue;
      }
      final materialized = await _materializeEncryptedReaction(b, reaction);
      if (materialized != null) visibleReactions.add(materialized);
    }
    final onTarget =
        foldReactionsByKind(
          visibleReactions,
          _signer.verifyReaction,
          targetKind,
        )[target] ??
        const <String, List<NodeId>>{};
    String? mine;
    for (final e in onTarget.entries) {
      if (e.value.any((n) => n == _signer.selfId)) {
        mine = e.key;
        break;
      }
    }
    final next = (mine == emoji) ? '' : emoji;
    final mySeq = _nextSeq(
      b.reactions
          .where(
            (r) =>
                r.author == _signer.selfId &&
                _validReactionFor(b.manifest.groupId, r),
          )
          .map((r) => r.seq),
    );
    final descriptor = state.epochDescriptor;
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final key = descriptor == null ? null : b.localEpochKeys[state.epoch];
    if (encryptionEstablished &&
        (descriptor == null ||
            key == null ||
            !_validLocalEpochKey(b.manifest, b.control, state.epoch, key))) {
      return false;
    }
    final createdAt = _now();
    final lifecycleGeneration = b.manifest.isSpace
        ? state.lifecycleTransitionHash
        : null;
    late final GroupReaction unsigned;
    if (targetMessage?.isChannelEncrypted == true) {
      final channelId = targetMessage!.channelId!;
      final protected = state.protectedChannels[channelId.hex];
      if (!b.manifest.isSpace || protected == null) {
        return false;
      }
      final channel = await _materializeProtectedChannel(b, state, protected);
      if (channel == null || !channel.recipients.contains(_signer.selfId)) {
        return false;
      }
      final channelEpoch = protected.channelEpoch;
      final channelKey =
          b.localChannelEpochKeys[_channelKeyId(channelId, channelEpoch)];
      if (channelKey == null ||
          !_validLocalChannelEpochKey(
            b.manifest,
            b.control,
            channelId,
            channelEpoch,
            channelKey,
          )) {
        return false;
      }
      final clear = GroupReactionCleartext(
        target: target,
        emoji: next,
        targetKind: ReactionTargetKind.message,
        schemaVersion: 2,
      ).encode();
      try {
        final encrypted = await encryptSpaceChannelReactionPayload(
          spaceId: groupId,
          channelId: channelId,
          channelEpoch: channelEpoch,
          author: _signer.selfId,
          seq: mySeq,
          reactionVersion: lifecycleGeneration == null ? 7 : 8,
          lifecycleGeneration: lifecycleGeneration ?? '',
          createdAtMs: createdAt,
          clearText: clear,
          channelKey: channelKey,
        );
        unsigned = GroupReaction(
          groupId: groupId,
          author: _signer.selfId,
          seq: mySeq,
          target: '',
          emoji: '',
          version: lifecycleGeneration == null ? 7 : 8,
          channelId: channelId,
          channelEpoch: channelEpoch,
          encryptedPayload: encrypted,
          lifecycleGeneration: lifecycleGeneration,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else if (descriptor != null && key != null) {
      final clear = GroupReactionCleartext(
        target: target,
        emoji: next,
        targetKind: targetKind,
        schemaVersion: 2,
      ).encode();
      try {
        final encrypted = await encryptGroupReactionPayload(
          groupId: groupId,
          membershipEpoch: state.epoch,
          author: _signer.selfId,
          seq: mySeq,
          createdAtMs: createdAt,
          clearText: clear,
          epochKey: key,
          reactionVersion: lifecycleGeneration == null ? 4 : 6,
          lifecycleGeneration: lifecycleGeneration ?? '',
        );
        unsigned = GroupReaction(
          groupId: groupId,
          author: _signer.selfId,
          seq: mySeq,
          target: '',
          emoji: '',
          version: lifecycleGeneration == null ? 4 : 6,
          membershipEpoch: state.epoch,
          encryptedPayload: encrypted,
          lifecycleGeneration: lifecycleGeneration,
          createdAtMs: createdAt,
          signature: Uint8List(0),
        );
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } else {
      unsigned = GroupReaction(
        groupId: groupId,
        author: _signer.selfId,
        seq: mySeq,
        target: target,
        emoji: next,
        version: lifecycleGeneration == null ? 3 : 5,
        targetKind: targetKind,
        lifecycleGeneration: lifecycleGeneration,
        createdAtMs: createdAt,
        signature: Uint8List(0),
      );
    }
    final signed = _signer.signReaction(unsigned);
    SpacePublicReaction? publicReaction;
    if (publiclyVisible) {
      final lifecycle = lifecycleGeneration ?? _legacyPostGeneration(groupId);
      if (targetKind != ReactionTargetKind.spacePost || targetPost == null) {
        return false;
      }
      final chain = _publicReactionChain(b, target, _signer.selfId);
      if (chain == null) return false;
      final unsignedPublic = SpacePublicReaction(
        spaceId: groupId,
        postId: target,
        author: _signer.selfId,
        seq: signed.seq,
        prevHash: chain.isEmpty ? '' : chain.last.recordHash,
        emoji: next,
        lifecycleGeneration: lifecycle,
        createdAtMs: createdAt,
        signature: Uint8List(0),
        authorPubKey: Uint8List(0),
      );
      final detached = _signer.signDetached(unsignedPublic.canonicalBytes());
      publicReaction = unsignedPublic.withSignature(
        detached.signature,
        detached.publicKey,
      );
      if (!publicReaction.verify(_signer.verifyDetached)) return false;
    }
    await _save(
      b.copyWith(
        reactions: [...b.reactions, signed],
        publicReactions: [...b.publicReactions, ?publicReaction],
      ),
    );
    if (broadcast) {
      unawaited(
        broadcastDelta(
          groupId,
          reactions: [signed],
          publicReactions: [?publicReaction],
        ),
      );
    }
    return true;
  }

  /// The folded reactions of [groupId]: `messageRef -> emoji -> reactors`.
  Future<Map<String, MessageReactions>> reactionsOf(NodeId groupId) async {
    final b = await load(groupId);
    if (b == null) return const {};
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    if (b.manifest.isSpace && state.isDeleted) return const {};
    final protectedChannels = b.manifest.isSpace
        ? await _protectedChannelsOf(b, state)
        : const <String, SpaceChannelControlCleartext>{};
    final visibleMessages = {
      for (final message in await messagesOf(groupId)) message.ref: message,
    };
    final materialized = <GroupReaction>[];
    for (final reaction in b.reactions) {
      if (!_validReactionFor(groupId, reaction) ||
          (reaction.isChannelEncrypted &&
              !(protectedChannels[reaction.channelId!.hex]?.recipients.contains(
                    reaction.author,
                  ) ??
                  false)) ||
          !SpaceAcl(state).allows(
            reaction.author,
            SpacePermission.publishMessages,
            atMs: reaction.createdAtMs,
          )) {
        continue;
      }
      final visible = await _materializeEncryptedReaction(b, reaction);
      if (visible == null) continue;
      final target = visibleMessages[visible.target];
      if (target == null ||
          (reaction.isChannelEncrypted
              ? !target.isChannelEncrypted ||
                    target.channelId != reaction.channelId
              : target.isChannelEncrypted)) {
        continue;
      }
      materialized.add(visible);
    }
    return foldGroupReactions(materialized, _signer.verifyReaction);
  }

  /// The folded reactions of visible, non-deleted Space publication roots.
  Future<Map<String, MessageReactions>> spacePostReactionsOf(
    NodeId spaceId,
  ) async {
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return const {};
    return _spacePostReactionsOfBundle(bundle);
  }

  Future<Map<String, MessageReactions>> _spacePostReactionsOfBundle(
    GroupBundle bundle, {
    Set<String>? visiblePostIds,
  }) async {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
    ).state;
    if (!SpaceAcl(state).allows(_signer.selfId, SpacePermission.view)) {
      return const {};
    }
    final allowedPostIds =
        visiblePostIds ??
        {for (final post in await _postsOfBundle(bundle)) post.postId};
    final materialized = <GroupReaction>[];
    for (final reaction in _acceptedReactionsWithinLifecycle(bundle, state)) {
      if (!SpaceAcl(state).allows(
        reaction.author,
        SpacePermission.publishMessages,
        atMs: reaction.createdAtMs,
      )) {
        continue;
      }
      final visible = await _materializeEncryptedReaction(bundle, reaction);
      if (visible != null &&
          visible.targetKind == ReactionTargetKind.spacePost &&
          allowedPostIds.contains(visible.target)) {
        materialized.add(visible);
      }
    }
    return foldReactionsByKind(
      materialized,
      _signer.verifyReaction,
      ReactionTargetKind.spacePost,
    );
  }

  // ── Content path (doc/GROUPS-CONTENT-PATH.md) ─────────────────────────────

  /// Replay cache for inbound fetch requests (holder side), bounded FIFO.
  final Set<String> _seenContentNonces = <String>{};
  static const int _kMaxSeenNonces = 512;

  /// The contentIds referenced by validated channel messages or Space posts —
  /// the only content a membership grant may unlock (membership must not
  /// become a license to fetch arbitrary content this device holds).
  Future<Set<String>> referencedContentIds(
    NodeId groupId, {
    bool applyLocalRetention = false,
  }) async {
    final bundle = await load(groupId);
    final posts = bundle == null || !bundle.manifest.isSpace
        ? const <SpacePostView>[]
        : await _postsOfBundle(
            bundle,
            applyLocalRetention: applyLocalRetention,
          );
    final postIds = {for (final post in posts) post.postId};
    final msgs = await messagesOf(
      groupId,
      includeSpacePostComments: true,
      applyLocalRetention: applyLocalRetention,
    );
    final commentRows = <String, List<GroupMessage>>{};
    for (final message in msgs) {
      final postId = message.spacePostId;
      if (postId != null && postIds.contains(postId)) {
        (commentRows[postId] ??= <GroupMessage>[]).add(message);
      }
    }
    final comments = <SpacePostCommentView>[
      for (final rows in commentRows.values) ..._projectSpacePostComments(rows),
    ];
    return {
      for (final m in msgs)
        if (m.spacePostId == null && m.attachment?.cid != null)
          m.attachment!.cid!,
      for (final comment in comments)
        if (comment.attachment?.cid != null) comment.attachment!.cid!,
      for (final post in posts)
        for (final media in post.media) media.contentId!,
    };
  }

  /// Mint, sign and ship a fetch request for [cid] of [groupId] to [holder]
  /// (normally the message author). False when the wire sender isn't attached.
  Future<bool> requestGroupContent(
    NodeId groupId,
    String cid,
    NodeId holder, {
    NodeId? channelId,
    int? channelEpoch,
  }) async {
    if ((channelId == null) != (channelEpoch == null) ||
        (channelEpoch != null && channelEpoch <= 0)) {
      return false;
    }
    final send = sendContentRequest;
    if (send == null) return false;
    final rnd = Random.secure();
    final nonce = List<int>.generate(
      12,
      (_) => rnd.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final signed = _signer.signContentRequest(
      GroupContentRequest(
        groupId: groupId,
        contentId: cid,
        requester: _signer.selfId,
        nonce: nonce,
        tsMs: _now(),
        channelId: channelId,
        channelEpoch: channelEpoch,
        signature: Uint8List(0),
      ),
    );
    _purgeSpaceReceiptState();
    final key = _outboundContentRequestKey(groupId, cid, holder);
    while (_outboundContentRequests.length >= _kMaxOutboundContentRequests &&
        !_outboundContentRequests.containsKey(key)) {
      _outboundContentRequests.remove(_outboundContentRequests.keys.first);
    }
    _outboundContentRequests[key] = _OutboundContentRequest(
      request: signed,
      holder: holder,
      createdAtMs: _spaceReceiptNowMs(),
    );
    try {
      await send(holder, jsonEncode(signed.toJson()));
    } catch (_) {
      if (_outboundContentRequests[key]?.request.nonce == signed.nonce) {
        _outboundContentRequests.remove(key);
      }
      rethrow;
    }
    return true;
  }

  /// Holder side: authorize an inbound signed request against OUR folded view
  /// and grant the serve when it passes. Unauthorized requests return false
  /// with only a local log line — the requester gets NOTHING back (no
  /// membership oracle, per canon).
  Future<bool> handleContentRequest(String requestJson) async {
    GroupContentRequest? r;
    try {
      r = GroupContentRequest.fromJson(jsonDecode(requestJson));
    } catch (_) {
      /* malformed → drop */
    }
    if (r == null) return false;
    final req = r;
    final bundle = await load(req.groupId);
    if (bundle == null) {
      devLog(() => 'xVeil[groups]: content request for unknown group — drop');
      return false;
    }
    final st = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
    ).state;
    final scope = await _contentGrantScope(bundle, st, req);
    final acl = SpaceAcl(st);
    final requesterDecision = acl.authorize(
      req.requester,
      SpacePermission.distributeContent,
      channelId: req.channelId,
      categoryId: scope.categoryId,
    );
    final holderAuthorized = acl.allows(
      _signer.selfId,
      SpacePermission.distributeContent,
      channelId: req.channelId,
      categoryId: scope.categoryId,
    );
    final denial = authorizeGroupContentRequest(
      req,
      decision: requesterDecision,
      referenced: scope.referenced,
      nowMs: _now(),
      seenNonces: _seenContentNonces,
      verify: _signer.verifyContentRequest,
      scopeAuthorized: scope.authorized && holderAuthorized,
    );
    if (denial != null) {
      devLog(
        () => 'xVeil[groups]: content request DENIED (${denial.name}) — drop',
      );
      if (bundle.manifest.isSpace &&
          !st.isMember(req.requester) &&
          _wasRevokedSpaceMember(bundle, req.requester)) {
        _observeSpace(
          SpaceObservationType.revokedDeliveryPrevented,
          SpaceObservationOutcome.rejected,
          reason: SpaceObservationReason.notMember,
        );
      }
      return false;
    }
    if (_seenContentNonces.length >= _kMaxSeenNonces) {
      _seenContentNonces.remove(_seenContentNonces.first);
    }
    _seenContentNonces.add(req.nonce);
    if (grantContentServe != null) {
      _purgeSpaceReceiptState();
      final key = _pendingContentReceiptKey(req.requester, req.nonce);
      while (_pendingContentReceipts.length >= _kMaxPendingContentReceipts &&
          !_pendingContentReceipts.containsKey(key)) {
        _pendingContentReceipts
            .remove(_pendingContentReceipts.keys.first)
            ?.elapsed
            .stop();
      }
      _pendingContentReceipts[key]?.elapsed.stop();
      _pendingContentReceipts[key] = _PendingContentReceipt(
        request: req,
        createdAtMs: _spaceReceiptNowMs(),
      );
    }
    grantContentServe?.call(req.requester, req.contentId);
    return true;
  }

  /// Requester side: the messaging layer calls this only after [contentId] is
  /// fully hash-verified and durable, with the actual sources that supplied
  /// verified bytes. Record those source slots locally and return each source
  /// its own original request nonce. The receipt send is detached/live-only:
  /// content completion must not wait for diagnostics and no offline read
  /// trail may enter an outbox or mailbox.
  Future<void> handleVerifiedContentSources(
    String contentId,
    Set<NodeId> sources,
  ) async {
    if (sources.isEmpty || !await _storage.hasFile(contentId)) return;
    _purgeSpaceReceiptState();
    final sourceIds = {for (final source in sources) source.hex};
    final matches = [
      for (final entry in _outboundContentRequests.entries)
        if (entry.value.request.contentId == contentId &&
            sourceIds.contains(entry.value.holder.hex))
          entry,
    ];
    for (final entry in matches) {
      final pending = entry.value;
      final request = pending.request;
      final bundle = await load(request.groupId);
      if (bundle == null) {
        _outboundContentRequests.remove(entry.key);
        continue;
      }
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (control) => _validControlFor(bundle.manifest, control),
        initialName: bundle.manifest.name,
        initialDescription: bundle.manifest.description ?? '',
      ).state;
      final acl = SpaceAcl(state);
      final scope = await _contentFetchScope(
        bundle,
        state,
        contentId,
        preferredHolder: pending.holder,
      );
      final stillAuthorized =
          scope != null &&
          scope.candidates.contains(pending.holder) &&
          acl.allows(
            _signer.selfId,
            SpacePermission.distributeContent,
            channelId: scope.channelId,
            categoryId: scope.categoryId,
          ) &&
          acl.allows(
            pending.holder,
            SpacePermission.distributeContent,
            channelId: scope.channelId,
            categoryId: scope.categoryId,
          );
      _outboundContentRequests.remove(entry.key);
      if (!stillAuthorized) continue;

      if (bundle.manifest.isSpace) {
        _rememberContentHolderProof(request.groupId, contentId, pending.holder);
      }
      final send = sendContentReceipt;
      if (send == null) continue;
      final receipt = GroupContentReceipt(
        groupId: request.groupId,
        contentId: contentId,
        requester: _signer.selfId,
        requestNonce: request.nonce,
        tsMs: _now(),
      );
      unawaited(
        send(pending.holder, jsonEncode(receipt.toJson())).catchError((
          Object _,
        ) {
          // Best-effort and deliberately not durable.
        }),
      );
    }
  }

  /// Holder side: accept one completion only when it comes from the
  /// authenticated requester and exactly matches the still-live signed
  /// request retained in RAM. Current membership, scope and reference are
  /// re-evaluated so a removal/ACL rotation between request and completion
  /// cannot mint a stale holder proof. Invalid frames are silently dropped.
  Future<bool> handleContentReceipt(NodeId peer, String receiptJson) async {
    GroupContentReceipt? receipt;
    try {
      receipt = GroupContentReceipt.fromJson(jsonDecode(receiptJson));
    } catch (_) {
      // Malformed → silent drop below.
    }
    if (receipt == null || receipt.requester != peer) {
      _observeSpace(
        SpaceObservationType.p2pContentReceipt,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.invalidInput,
      );
      return false;
    }
    _purgeSpaceReceiptState();
    final key = _pendingContentReceiptKey(peer, receipt.requestNonce);
    final pending = _pendingContentReceipts[key];
    final request = pending?.request;
    if (pending == null ||
        request == null ||
        request.groupId != receipt.groupId ||
        request.contentId != receipt.contentId ||
        request.requester != peer ||
        (_now() - receipt.tsMs).abs() >
            kGroupContentRequestWindow.inMilliseconds) {
      _observeSpace(
        SpaceObservationType.p2pContentReceipt,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.invalidState,
      );
      return false;
    }
    _pendingContentReceipts.remove(key);
    pending.elapsed.stop();

    final bundle = await load(receipt.groupId);
    if (bundle == null) {
      _observeSpace(
        SpaceObservationType.p2pContentReceipt,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.notFound,
      );
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (control) => _validControlFor(bundle.manifest, control),
      initialName: bundle.manifest.name,
      initialDescription: bundle.manifest.description ?? '',
    ).state;
    final acl = SpaceAcl(state);
    final scope = await _contentGrantScope(bundle, state, request);
    if (!scope.authorized ||
        !scope.referenced.contains(receipt.contentId) ||
        !acl.allows(
          peer,
          SpacePermission.distributeContent,
          channelId: request.channelId,
          categoryId: scope.categoryId,
        ) ||
        !acl.allows(
          _signer.selfId,
          SpacePermission.distributeContent,
          channelId: request.channelId,
          categoryId: scope.categoryId,
        )) {
      _observeSpace(
        SpaceObservationType.p2pContentReceipt,
        SpaceObservationOutcome.rejected,
        reason: SpaceObservationReason.permissionDenied,
        duration: pending.elapsed.elapsed,
      );
      return false;
    }
    if (bundle.manifest.isSpace) {
      _rememberContentHolderProof(receipt.groupId, receipt.contentId, peer);
    }
    _observeSpace(
      SpaceObservationType.p2pContentReceipt,
      SpaceObservationOutcome.succeeded,
      duration: pending.elapsed.elapsed,
    );
    return true;
  }

  /// Resolve the exact reference namespace an inbound content request may
  /// use. Unscoped requests deliberately exclude channel-encrypted rows, even
  /// when this holder can decrypt them: otherwise any Space member who guessed
  /// a protected CID could reuse the legacy membership-wide grant.
  Future<({bool authorized, Set<String> referenced, NodeId? categoryId})>
  _contentGrantScope(
    GroupBundle bundle,
    GroupState state,
    GroupContentRequest request,
  ) async {
    final channelId = request.channelId;
    if (channelId == null) {
      final posts = bundle.manifest.isSpace
          ? await _postsOfBundle(bundle)
          : const <SpacePostView>[];
      final visiblePostIds = {for (final post in posts) post.postId};
      final messages = await messagesOf(
        request.groupId,
        includeSpacePostComments: true,
        applyLocalRetention: false,
      );
      return (
        authorized: true,
        referenced: {
          for (final message in messages)
            if (!message.isChannelEncrypted &&
                message.attachment?.cid != null &&
                (message.spacePostId == null ||
                    visiblePostIds.contains(message.spacePostId)))
              message.attachment!.cid!,
          for (final post in posts)
            for (final media in post.media) media.contentId!,
          ...await _vouched(request.groupId),
        },
        categoryId: null,
      );
    }

    if (!bundle.manifest.isSpace) {
      return (authorized: false, referenced: <String>{}, categoryId: null);
    }
    final opaque = state.protectedChannels[channelId.hex];
    if (opaque == null || opaque.channelEpoch != request.channelEpoch) {
      return (authorized: false, referenced: <String>{}, categoryId: null);
    }
    final clear = (await _protectedChannelsOf(bundle, state))[channelId.hex];
    if (clear == null || !clear.recipients.contains(request.requester)) {
      return (
        authorized: false,
        referenced: <String>{},
        categoryId: clear?.channel.categoryId,
      );
    }
    final messages = await messagesOf(
      request.groupId,
      channelId: channelId,
      applyLocalRetention: false,
    );
    return (
      authorized: true,
      referenced: {
        for (final message in messages)
          if (message.isChannelEncrypted && message.attachment?.cid != null)
            message.attachment!.cid!,
      },
      categoryId: clear.channel.categoryId,
    );
  }

  /// Whether NON-contact [peer] may sync group [gidHex]: we already hold that
  /// group AND the peer is a current member per OUR fold. The admission the
  /// wire layer asks before spending reassembly RAM on a stranger's chunks.
  Future<bool> allowStrangerGroupSync(NodeId peer, String gidHex) async {
    if (!(await _index()).contains(gidHex)) return false;
    final NodeId gid;
    try {
      gid = NodeId.fromHex(gidHex);
    } catch (_) {
      return false;
    }
    final st = await stateOf(gid);
    return st != null &&
        SpaceAcl(st).allows(peer, SpacePermission.distributeContent);
  }

  /// Ingest a snapshot from a NON-contact sender: merge ONLY into a group we
  /// already hold where [peer] is a current member — the scale-free log sync
  /// (members need no pairwise contact handshake). Never materializes a NEW
  /// group: a stranger's group-invite is spam until a consent surface exists,
  /// so that path stays contact-gated. Unauthorized bundles are dropped with
  /// nothing sent back (no membership oracle).
  Future<bool> ingestSnapshotFromStranger(
    NodeId peer,
    String bundleJson,
  ) async {
    String? gidHex;
    try {
      final d = jsonDecode(bundleJson);
      final m = d is Map ? d['m'] : null;
      final gid = m is Map ? m['gid'] : null;
      if (gid is String && gid.isNotEmpty) gidHex = gid;
    } catch (_) {
      /* malformed → drop below */
    }
    if (gidHex == null) return false;
    final pending = await _tryPendingDeviceSnapshot(peer, bundleJson);
    if (pending != null) return pending;
    if (!await allowStrangerGroupSync(peer, gidHex)) {
      devLog(() => 'xVeil[groups]: stranger snapshot DENIED — drop');
      return false;
    }
    return ingestSnapshot(bundleJson);
  }

  /// Returns null when [bundleJson] is unrelated to the pending ceremony,
  /// otherwise consumes it (true) or rejects it (false). Shared by contact and
  /// non-contact ingress: prior contact status must not change adoption rules.
  Future<bool?> _tryPendingDeviceSnapshot(
    NodeId peer,
    String bundleJson,
  ) async {
    final pending = await pendingDeviceAdoption();
    if (pending == null || peer != pending.source) return null;
    GroupManifest? manifest;
    try {
      final d = jsonDecode(bundleJson);
      manifest = GroupManifest.fromJson(d is Map ? d['m'] : null);
    } catch (_) {
      return false;
    }
    if (manifest == null || manifest.groupId != pending.groupId) return null;
    if (!_listEquals(_manifestHash(manifest), pending.manifestHash)) {
      return false;
    }
    if (!await ingestSnapshot(bundleJson)) return false;
    if (!await adoptDeviceGroup(pending.groupId)) return false;
    await cancelPendingDeviceAdoption();
    return true;
  }

  /// Fetch [cid] of [groupId], preferring [holder] (normally the message
  /// author) but authorizing EVERY other current member as a candidate seeder.
  /// Thus a member that downloaded and verified the blob can keep serving it
  /// after the author goes offline. We intentionally do not publish persistent
  /// holder/read advertisements: one explicit user fetch sends the same signed
  /// membership request to all candidates, non-holders deny silently, and the
  /// content-addressed pull stops at the first verified source.
  Future<bool> fetchGroupContent(
    NodeId groupId,
    String cid,
    NodeId holder,
  ) async {
    final pullAny = startContentPullFromAny;
    final pullOne = startContentPull;
    if (pullAny == null && pullOne == null) return false;
    final state = await stateOf(groupId);
    if (state == null ||
        !SpaceAcl(
          state,
        ).allows(_signer.selfId, SpacePermission.distributeContent)) {
      return false;
    }
    final bundle = await load(groupId);
    if (bundle == null) return false;
    final fetchScope = await _contentFetchScope(
      bundle,
      state,
      cid,
      preferredHolder: holder,
    );
    if (fetchScope == null) return false;
    final members = fetchScope.candidates;
    if (members.isEmpty) return false;
    final candidates = <NodeId>[
      if (members.contains(holder)) holder,
      for (final member in members)
        if (member != holder) member,
    ];

    // Best-effort fanout: one temporarily unreachable member must not prevent
    // a reachable downloaded holder from receiving its authorization.
    final requestTargets = [
      for (final candidate in candidates.skip(1)) candidate,
      candidates.first,
    ];
    await Future.wait<bool>([
      // Launch fallback members before the preferred author: the pull still
      // prefers the author, but its dead route cannot queue every grant behind
      // it inside a serialized transport.
      for (final candidate in requestTargets)
        requestGroupContent(
          groupId,
          cid,
          candidate,
          channelId: fetchScope.channelId,
          channelEpoch: fetchScope.channelEpoch,
        ).catchError((Object e) {
          devLog(
            () =>
                'xVeil[groups]: content request to '
                '${candidate.short} failed locally: $e',
          );
          return false;
        }),
    ]).timeout(
      contentRequestFanoutTimeout,
      onTimeout: () {
        devLog(
          () =>
              'xVeil[groups]: content request fanout deadline reached; '
              'starting scoped pull',
        );
        return const <bool>[];
      },
    );
    // Durable requests need a wire round-trip before grants exist. Pull retries
    // preserve correctness; this delay avoids burning the first open on DENIED.
    if (contentGrantDelay > Duration.zero) {
      await Future<void>.delayed(contentGrantDelay);
    }
    if (pullAny != null) {
      await pullAny(candidates, cid);
    } else {
      await pullOne!(candidates.first, cid);
    }
    return true;
  }

  /// Find whether [cid] is referenced in the ordinary Space/group namespace
  /// or only inside a protected channel visible to this device. Protected
  /// pulls fan out solely to that channel's current recipients; the channel id
  /// is never disclosed to unrelated Space members as a side effect of fetch.
  Future<
    ({
      NodeId? channelId,
      int? channelEpoch,
      NodeId? categoryId,
      List<NodeId> candidates,
    })?
  >
  _contentFetchScope(
    GroupBundle bundle,
    GroupState state,
    String cid, {
    required NodeId preferredHolder,
  }) async {
    final posts = bundle.manifest.isSpace
        ? await _postsOfBundle(bundle)
        : const <SpacePostView>[];
    final visiblePostIds = {for (final post in posts) post.postId};
    final messages = await _messagesOfBundle(
      bundle,
      includeSpacePostComments: true,
      applyLocalRetention: false,
    );
    final ordinaryReference =
        posts.any(
          (post) => post.media.any((media) => media.contentId == cid),
        ) ||
        messages.any(
          (message) =>
              !message.isChannelEncrypted &&
              message.attachment?.cid == cid &&
              (message.spacePostId == null ||
                  visiblePostIds.contains(message.spacePostId)),
        ) ||
        (await _vouched(bundle.manifest.groupId)).contains(cid);
    if (ordinaryReference) {
      final acl = SpaceAcl(state);
      final candidates = [
        for (final member in state.members.values)
          if (member.nodeId != _signer.selfId &&
              acl.allows(member.nodeId, SpacePermission.distributeContent))
            member.nodeId,
      ]..sort((left, right) => left.hex.compareTo(right.hex));
      return (
        channelId: null,
        channelEpoch: null,
        categoryId: null,
        candidates: _preferContentHolder(candidates, preferredHolder),
      );
    }

    final protectedReferences =
        messages
            .where(
              (message) =>
                  message.isChannelEncrypted && message.attachment?.cid == cid,
            )
            .toList()
          ..sort((left, right) {
            final leftPreferred = left.author == preferredHolder ? 0 : 1;
            final rightPreferred = right.author == preferredHolder ? 0 : 1;
            final preferred = leftPreferred.compareTo(rightPreferred);
            if (preferred != 0) return preferred;
            return left.channelId!.hex.compareTo(right.channelId!.hex);
          });
    if (protectedReferences.isEmpty) return null;
    final channelId = protectedReferences.first.channelId!;
    final opaque = state.protectedChannels[channelId.hex];
    final clear = (await _protectedChannelsOf(bundle, state))[channelId.hex];
    if (opaque == null ||
        clear == null ||
        !clear.recipients.contains(_signer.selfId)) {
      return null;
    }
    final acl = SpaceAcl(state);
    final candidates = [
      for (final recipient in clear.recipients)
        if (recipient != _signer.selfId &&
            state.isMember(recipient) &&
            acl.allows(
              recipient,
              SpacePermission.distributeContent,
              channelId: channelId,
              categoryId: clear.channel.categoryId,
            ))
          recipient,
    ]..sort((left, right) => left.hex.compareTo(right.hex));
    return (
      channelId: channelId,
      channelEpoch: opaque.channelEpoch,
      categoryId: clear.channel.categoryId,
      candidates: _preferContentHolder(candidates, preferredHolder),
    );
  }

  /// Resolve every locally visible content reference in one materialization
  /// pass for observability. Calling [_contentFetchScope] once per CID would
  /// repeatedly decrypt/fold the complete post and message history, making a
  /// diagnostics snapshot scale as `references × history`.
  ///
  /// Ordinary references use every current remote member. A CID visible only
  /// in a protected channel uses that channel's current recipients, matching
  /// the pull path. When the same protected CID appears in multiple channels,
  /// prefer a row authored by self and then the lexicographically first
  /// channel — the same deterministic choice [_contentFetchScope] makes with
  /// `preferredHolder == self`.
  Future<Map<String, List<NodeId>>> _contentReplicationCandidates(
    GroupBundle bundle,
    GroupState state,
  ) async {
    final posts = await _postsOfBundle(bundle);
    final visiblePostIds = {for (final post in posts) post.postId};
    final messages = await _messagesOfBundle(
      bundle,
      includeSpacePostComments: true,
      applyLocalRetention: false,
    );
    final ordinary = <String>{
      for (final post in posts)
        for (final media in post.media) media.contentId!,
      for (final message in messages)
        if (!message.isChannelEncrypted &&
            message.attachment?.cid != null &&
            (message.spacePostId == null ||
                visiblePostIds.contains(message.spacePostId)))
          message.attachment!.cid!,
    };
    final acl = SpaceAcl(state);
    final ordinaryCandidates = [
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId &&
            acl.allows(member.nodeId, SpacePermission.distributeContent))
          member.nodeId,
    ]..sort((left, right) => left.hex.compareTo(right.hex));
    final result = <String, List<NodeId>>{
      for (final contentId in ordinary) contentId: ordinaryCandidates,
    };

    final protected = <String, GroupMessage>{};
    for (final message in messages) {
      final contentId = message.attachment?.cid;
      if (!message.isChannelEncrypted ||
          contentId == null ||
          ordinary.contains(contentId)) {
        continue;
      }
      final previous = protected[contentId];
      if (previous == null) {
        protected[contentId] = message;
        continue;
      }
      final messagePreferred = message.author == _signer.selfId ? 0 : 1;
      final previousPreferred = previous.author == _signer.selfId ? 0 : 1;
      if (messagePreferred < previousPreferred ||
          (messagePreferred == previousPreferred &&
              message.channelId!.hex.compareTo(previous.channelId!.hex) < 0)) {
        protected[contentId] = message;
      }
    }
    if (protected.isEmpty) return result;

    final clearChannels = await _protectedChannelsOf(bundle, state);
    for (final entry in protected.entries) {
      final channelId = entry.value.channelId!;
      final opaque = state.protectedChannels[channelId.hex];
      final clear = clearChannels[channelId.hex];
      if (opaque == null ||
          clear == null ||
          !clear.recipients.contains(_signer.selfId)) {
        continue;
      }
      result[entry.key] = [
        for (final recipient in clear.recipients)
          if (recipient != _signer.selfId &&
              state.isMember(recipient) &&
              acl.allows(
                recipient,
                SpacePermission.distributeContent,
                channelId: channelId,
                categoryId: clear.channel.categoryId,
              ))
            recipient,
      ]..sort((left, right) => left.hex.compareTo(right.hex));
    }
    return result;
  }

  List<NodeId> _preferContentHolder(
    List<NodeId> candidates,
    NodeId preferredHolder,
  ) => [
    if (candidates.contains(preferredHolder)) preferredHolder,
    for (final candidate in candidates)
      if (candidate != preferredHolder) candidate,
  ];

  /// Ingest an externally-received control entry (from a peer-sync brick, or a
  /// hook). Appends if it isn't already present; the fold decides validity on
  /// read, so a bogus entry simply never applies.
  Future<void> ingestControl(NodeId groupId, ControlEntry e) =>
      _serialized(groupId, () => _ingestControl(groupId, e));

  Future<void> _ingestControl(NodeId groupId, ControlEntry e) async {
    final b = await load(groupId);
    if (b == null) return;
    if (!_validControlFor(b.manifest, e)) return;
    final incomingHash = controlEntryHash(e);
    if (b.control.any(
      (x) =>
          _validControlFor(b.manifest, x) &&
          controlEntryHash(x) == incomingHash,
    )) {
      return;
    }
    // Keep a distinct same-seq row as equivocation evidence. The pure fold
    // rejects both branches and their suffix; discarding the second arrival
    // would make authority depend on which peer happened to answer first.
    await _save(b.copyWith(control: [...b.control, e]));
  }

  List<GroupEpochRecipientEnvelope> _epochEnvelopesFor(
    GroupBundle bundle,
    NodeId recipient, {
    Iterable<ControlEntry>? controls,
  }) {
    final descriptors =
        (controls ?? _acceptedControl(bundle.manifest, bundle.control))
            .map((entry) => entry.epochDescriptor)
            .whereType<GroupEpochDescriptor>()
            .toList();
    return [
      for (final envelope in bundle.epochEnvelopes)
        if (envelope.recipient == recipient &&
            descriptors.any(
              (descriptor) => verifyGroupEpochEnvelope(
                descriptor: descriptor,
                envelope: envelope,
              ),
            ))
          envelope,
    ];
  }

  List<GroupEpochRecipientEnvelope> _channelEpochEnvelopesFor(
    GroupBundle bundle,
    NodeId recipient, {
    Iterable<ControlEntry>? controls,
  }) {
    final accepted = _acceptedControl(bundle.manifest, bundle.control);
    final current = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state.protectedChannels;
    final selectedDescriptors = (controls ?? accepted)
        .map((entry) => entry.channelControl?.keyDescriptor)
        .whereType<GroupEpochDescriptor>()
        .where(
          (descriptor) => bundle.channelEpochEnvelopes.any(
            (envelope) =>
                envelope.recipient == recipient &&
                verifyGroupEpochEnvelope(
                  descriptor: descriptor,
                  envelope: envelope,
                ),
          ),
        )
        .toList();
    final allowedChannelIds = <String>{};
    for (final scope in current.values) {
      final canOpenCurrent = bundle.channelEpochEnvelopes.any(
        (envelope) =>
            envelope.recipient == recipient &&
            envelope.groupId == scope.channelId &&
            envelope.epoch == scope.channelEpoch &&
            verifyGroupEpochEnvelope(
              descriptor: scope.keyDescriptor,
              envelope: envelope,
            ),
      );
      if (canOpenCurrent) allowedChannelIds.add(scope.channelId.hex);
    }
    return [
      for (final envelope in bundle.channelEpochEnvelopes)
        if (allowedChannelIds.contains(envelope.groupId.hex) &&
            selectedDescriptors.any(
              (descriptor) => verifyGroupEpochEnvelope(
                descriptor: descriptor,
                envelope: envelope,
              ),
            ))
          envelope,
    ];
  }

  bool _peerCanDecryptChannelEpoch(
    GroupBundle bundle,
    NodeId peer,
    NodeId channelId,
    int epoch,
  ) {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    final current = state.protectedChannels[channelId.hex];
    if (current == null) return false;
    final envelopes = _channelEpochEnvelopesFor(bundle, peer);
    return envelopes.any(
          (envelope) =>
              envelope.groupId == channelId &&
              envelope.epoch == current.channelEpoch,
        ) &&
        envelopes.any(
          (envelope) =>
              envelope.groupId == channelId && envelope.epoch == epoch,
        );
  }

  bool _peerCanDecryptEpoch(GroupBundle bundle, NodeId peer, int epoch) {
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
      initialName: bundle.manifest.name,
    ).state;
    if (state.epochDescriptor?.epoch == epoch && state.isMember(peer)) {
      return true;
    }
    return _epochEnvelopesFor(
      bundle,
      peer,
    ).any((envelope) => envelope.epoch == epoch);
  }

  /// Serialize a full snapshot tailored to one recipient. Epoch envelopes are
  /// never broadcast as a member list: the peer receives only its own sealed
  /// record and only ciphertext epochs it can open. [recipient] may be omitted
  /// by legacy unit/debug callers; such snapshots contain no epoch material.
  String snapshotJson(GroupBundle b, {NodeId? recipient, String? receipt}) {
    final encryptionEstablished = _encryptionEstablished(b.manifest, b.control);
    final lifecycleState = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (entry) => _validControlFor(b.manifest, entry),
      initialName: b.manifest.name,
      initialDescription: b.manifest.description ?? '',
    ).state;
    final distributesContent = recipient == null
        ? !lifecycleState.isDeleted
        : SpaceAcl(
            lifecycleState,
          ).allows(recipient, SpacePermission.distributeContent);
    final epochEnvelopes = recipient == null || !distributesContent
        ? const <GroupEpochRecipientEnvelope>[]
        : _epochEnvelopesFor(b, recipient);
    final channelEpochEnvelopes = recipient == null || !distributesContent
        ? const <GroupEpochRecipientEnvelope>[]
        : _channelEpochEnvelopesFor(b, recipient);
    // Snapshot assembly is synchronous, so only the clear retention timeline
    // is applied here; restricted-channel policies are enforced by the async
    // sync path and by the physical sweep that removes the rows themselves.
    final retentionRevisions = _clearRetentionRevisions(b);
    final retireAtMs = _now();
    // Include cuts for the prefix excluded above so the recipient can
    // re-anchor the retained suffix even before this node has swept.
    final serveCuts = _serveRetentionCuts(
      b,
      retentionRevisions,
      const {},
      retireAtMs,
    );
    return jsonEncode({
      'm': b.manifest.toJson(),
      'c': b.control
          .where(
            (e) => e.isStructurallyValid && _validControlFor(b.manifest, e),
          )
          .map((e) => e.toJson())
          .toList(),
      'g': _retainedMessageRows(b.manifest, b.messages)
          .where(
            (message) =>
                distributesContent &&
                _validMessageFor(b.manifest.groupId, message) &&
                !_retentionRetiresMessage(
                  manifest: b.manifest,
                  revisions: retentionRevisions,
                  hiddenThroughMs: const {},
                  message: message,
                  atMs: retireAtMs,
                ) &&
                _messageWithinLifecycleBoundary(
                  b.manifest,
                  lifecycleState,
                  message,
                ) &&
                (message.isChannelEncrypted
                    ? recipient != null &&
                          _peerCanDecryptChannelEpoch(
                            b,
                            recipient,
                            message.channelId!,
                            message.channelEpoch!,
                          )
                    : !encryptionEstablished
                    ? true
                    : message.isEncrypted &&
                          recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            message.membershipEpoch!,
                          )),
          )
          .map((message) => message.toJson())
          .toList(),
      if (b.posts.isNotEmpty)
        'p': b.posts
            .where(
              (post) =>
                  distributesContent &&
                  _validPostFor(b.manifest.groupId, post) &&
                  !_retentionRetiresPost(
                    manifest: b.manifest,
                    state: lifecycleState,
                    revisions: retentionRevisions,
                    post: post,
                    atMs: retireAtMs,
                  ) &&
                  _postWithinLifecycleBoundary(lifecycleState, post) &&
                  (!post.isEncrypted ||
                      (recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            post.membershipEpoch!,
                          ))),
            )
            .map((post) => post.toJson())
            .toList(),
      'r': _acceptedReactionsWithinLifecycle(b, lifecycleState)
          .where(
            (reaction) =>
                distributesContent &&
                !_retentionRetiresReaction(
                  manifest: b.manifest,
                  revisions: retentionRevisions,
                  hiddenThroughMs: const {},
                  reaction: reaction,
                  atMs: retireAtMs,
                ) &&
                (reaction.isChannelEncrypted
                    ? recipient != null &&
                          _peerCanDecryptChannelEpoch(
                            b,
                            recipient,
                            reaction.channelId!,
                            reaction.channelEpoch!,
                          )
                    : !encryptionEstablished
                    ? true
                    : reaction.isMembershipEncrypted &&
                          recipient != null &&
                          _peerCanDecryptEpoch(
                            b,
                            recipient,
                            reaction.membershipEpoch!,
                          )),
          )
          .map((r) => r.toJson())
          .toList(),
      if (b.manifest.isSpace && distributesContent)
        'pc': b.publicComments
            .where(
              (comment) =>
                  _validPublicCommentFor(b.manifest.groupId, comment) &&
                  comment.lifecycleGeneration ==
                      (lifecycleState.lifecycleTransitionHash ??
                          _legacyPostGeneration(b.manifest.groupId)),
            )
            .map((comment) => comment.toJson())
            .toList(),
      if (b.manifest.isSpace && distributesContent)
        'pr': b.publicReactions
            .where(
              (reaction) =>
                  _validPublicReactionFor(b.manifest.groupId, reaction) &&
                  reaction.lifecycleGeneration ==
                      (lifecycleState.lifecycleTransitionHash ??
                          _legacyPostGeneration(b.manifest.groupId)),
            )
            .map((reaction) => reaction.toJson())
            .toList(),
      if (epochEnvelopes.isNotEmpty)
        'ke': epochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (channelEpochEnvelopes.isNotEmpty)
        'cke': channelEpochEnvelopes.map((entry) => entry.toJson()).toList(),
      if (distributesContent && serveCuts.isNotEmpty)
        'rcut': [for (final cut in serveCuts.values) cut.toJson()],
      if (b.sovereignBundle != null) 's': base64Encode(b.sovereignBundle!),
      'rcpt': ?receipt,
    });
  }

  /// Ingest a received snapshot: materialize the group if new (manifest +
  /// index), then merge control + message entries. Exact signed rows dedup by
  /// hash; distinct same-scope `(author, seq)` rows remain as fork evidence.
  /// Idempotent — re-delivery of the same snapshot is a no-op.
  Future<bool> ingestSnapshot(String bundleJson) async {
    try {
      final value = jsonDecode(bundleJson);
      final manifest = value is Map ? value['m'] : null;
      final gid = manifest is Map ? manifest['gid'] : null;
      if (gid is! String) return false;
      return _serialized(
        NodeId.fromHex(gid),
        () => _ingestSnapshot(bundleJson),
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> _ingestSnapshot(String bundleJson) async {
    Map<String, dynamic> d;
    try {
      d = jsonDecode(bundleJson) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    final manifest = GroupManifest.fromJson(d['m']);
    if (manifest == null || !_validManifest(manifest)) return false;
    final Uint8List? incomingSovereignBundle;
    try {
      incomingSovereignBundle = d['s'] is String
          ? Uint8List.fromList(base64Decode(d['s'] as String))
          : null;
    } catch (_) {
      return false;
    }
    final inControl = (d['c'] as List? ?? const [])
        .map(ControlEntry.fromJson)
        .whereType<ControlEntry>()
        .toList();
    final inMsgs = (d['g'] as List? ?? const [])
        .map(GroupMessage.fromJson)
        .whereType<GroupMessage>()
        .toList();
    final inPosts = (d['p'] as List? ?? const [])
        .map(SpacePost.fromJson)
        .whereType<SpacePost>()
        .toList();
    final inReactions = (d['r'] as List? ?? const [])
        .map(GroupReaction.fromJson)
        .whereType<GroupReaction>()
        .toList();
    final inPublicComments = (d['pc'] as List? ?? const [])
        .map(SpacePublicComment.fromJson)
        .whereType<SpacePublicComment>()
        .toList();
    final inPublicReactions = (d['pr'] as List? ?? const [])
        .map(SpacePublicReaction.fromJson)
        .whereType<SpacePublicReaction>()
        .toList();
    final inEpochEnvelopes = (d['ke'] as List? ?? const [])
        .map(GroupEpochRecipientEnvelope.fromJson)
        .whereType<GroupEpochRecipientEnvelope>()
        .toList();
    final inChannelEpochEnvelopes = (d['cke'] as List? ?? const [])
        .map(GroupEpochRecipientEnvelope.fromJson)
        .whereType<GroupEpochRecipientEnvelope>()
        .toList();
    final inRetentionCuts = (d['rcut'] as List? ?? const [])
        .map(SpaceRetentionCut.fromJson)
        .whereType<SpaceRetentionCut>()
        .toList();

    final deletionTombstone = await deletedSpaceTombstone(manifest.groupId);
    if (deletionTombstone != null) {
      final incomingFold = foldControlLog(
        owner: manifest.owner,
        entries: inControl,
        verify: (entry) => _validControlFor(manifest, entry),
        initialName: manifest.name,
        initialDescription: manifest.description ?? '',
      );
      final containsPurgedDelete = incomingFold.accepted.any(
        (entry) =>
            entry.op == ControlOp.deleteSpace &&
            controlEntryHash(entry) == deletionTombstone.deleteTransitionHash,
      );
      if (!containsPurgedDelete) return false;
      // Re-delivery of the expired deletion is an idempotent no-op. Only a
      // complete log with a valid owner restore authored inside the signed
      // recovery window may materialize the Space again.
      if (incomingFold.state.isDeleted) return true;
      if (incomingFold.state.lifecycleTransition == null) return false;
    }

    final existing = await load(manifest.groupId);
    if ((existing == null &&
            !_validSovereignBundle(manifest, incomingSovereignBundle)) ||
        (existing != null &&
            incomingSovereignBundle != null &&
            !_validSovereignBundle(manifest, incomingSovereignBundle))) {
      return false;
    }
    final man = existing == null
        ? manifest
        : _mergeManifest(existing.manifest, manifest);
    if (man == null) return false;
    final hadFeedAccess =
        existing != null &&
        existing.manifest.isSpace &&
        SpaceAcl(
          foldControlLog(
            owner: existing.manifest.owner,
            entries: existing.control,
            verify: (entry) => _validControlFor(existing.manifest, entry),
            initialName: existing.manifest.name,
            initialDescription: existing.manifest.description ?? '',
          ).state,
        ).allows(_signer.selfId, SpacePermission.view);
    final acceptedPostIdsBefore = !man.isSpace || existing == null
        ? <String>{}
        : {for (final post in await _postsOfBundle(existing)) post.postId};
    final control = [...(existing?.control ?? const <ControlEntry>[])];
    final messages = [...(existing?.messages ?? const <GroupMessage>[])];
    final acceptedMessageHashesBefore = existing == null
        ? <String>{}
        : {
            for (final message in _acceptedMessagesWithinLifecycle(
              existing,
              foldControlLog(
                owner: existing.manifest.owner,
                entries: existing.control,
                verify: (entry) => _validControlFor(existing.manifest, entry),
                initialName: existing.manifest.name,
              ).state,
            ))
              groupMessageHash(message),
          };
    final posts = [...(existing?.posts ?? const <SpacePost>[])];
    final reactions = [...(existing?.reactions ?? const <GroupReaction>[])];
    final publicComments = [
      ...(existing?.publicComments ?? const <SpacePublicComment>[]),
    ];
    final publicReactions = [
      ...(existing?.publicReactions ?? const <SpacePublicReaction>[]),
    ];
    for (final e in inControl) {
      if (!_validControlFor(man, e)) continue;
      final incomingHash = controlEntryHash(e);
      if (!control.any(
        (x) =>
            _validControlFor(man, x) && x.author == e.author && x.seq == e.seq,
      )) {
        control.add(e);
      } else if (!control.any(
        (x) => _validControlFor(man, x) && controlEntryHash(x) == incomingHash,
      )) {
        // Preserve distinct same-seq evidence; foldControlLog quarantines the
        // author deterministically from the fork point onward.
        control.add(e);
      }
    }
    final mergedState = foldControlLog(
      owner: man.owner,
      entries: control,
      verify: (e) => _validControlFor(man, e),
      initialName: man.name,
    ).state;
    final hasFeedAccess =
        man.isSpace &&
        SpaceAcl(mergedState).allows(_signer.selfId, SpacePermission.view);
    final material = await _mergeEpochMaterial(
      manifest: man,
      control: control,
      existingEnvelopes:
          existing?.epochEnvelopes ?? const <GroupEpochRecipientEnvelope>[],
      existingKeys: existing?.localEpochKeys ?? const <int, Uint8List>{},
      incomingEnvelopes: inEpochEnvelopes,
    );
    final channelMaterial = await _mergeChannelEpochMaterial(
      manifest: man,
      control: control,
      existingEnvelopes:
          existing?.channelEpochEnvelopes ??
          const <GroupEpochRecipientEnvelope>[],
      existingKeys:
          existing?.localChannelEpochKeys ?? const <String, Uint8List>{},
      incomingEnvelopes: inChannelEpochEnvelopes,
    );
    final materialBundle = GroupBundle(
      manifest: man,
      control: control,
      messages: messages,
      posts: posts,
      reactions: reactions,
      publicComments: publicComments,
      publicReactions: publicReactions,
      epochEnvelopes: material.envelopes,
      localEpochKeys: material.keys,
      channelEpochEnvelopes: channelMaterial.envelopes,
      localChannelEpochKeys: channelMaterial.keys,
      sovereignBundle: existing?.sovereignBundle ?? incomingSovereignBundle,
    );
    final protectedChannels = man.isSpace
        ? await _protectedChannelsOf(materialBundle, mergedState)
        : const <String, SpaceChannelControlCleartext>{};
    final encryptionEstablished = _encryptionEstablished(man, control);
    // Retention is enforced symmetrically at ingest: a stale or malicious
    // holder cannot resurrect rows the signed policy has already retired.
    final ingestRetention = man.isSpace
        ? await _materializedRetentionHistory(materialBundle, mergedState)
        : null;
    final ingestAtMs = _now();
    final acceptedCommentRoots = <String>{...acceptedPostIdsBefore};
    if (man.isSpace) {
      for (final post in inPosts) {
        if (!_validPostFor(man.groupId, post) ||
            !_postWithinLifecycleBoundary(mergedState, post)) {
          continue;
        }
        final authorized = post.isCausal
            ? _causalPostHistoricallyAuthorized(man, control, post)
            : SpaceAcl(mergedState).allows(
                post.author,
                SpacePermission.publishPosts,
                atMs: post.createdAtMs,
              );
        if (authorized) acceptedCommentRoots.add(post.postId);
      }
    }
    final fresh = <GroupMessage>[];
    for (final m in inMsgs) {
      if (!_validMessageFor(manifest.groupId, m)) {
        continue;
      }
      if (!_messageWithinLifecycleBoundary(man, mergedState, m)) continue;
      if (ingestRetention != null &&
          _retentionRetiresMessage(
            manifest: man,
            revisions: ingestRetention.revisions,
            hiddenThroughMs: ingestRetention.hiddenThroughMs,
            message: m,
            atMs: ingestAtMs,
          )) {
        continue;
      }
      if (man.isSpace) {
        if (m.spacePostId != null) {
          if (m.channelId != null ||
              m.isChannelEncrypted ||
              !acceptedCommentRoots.contains(m.spacePostId)) {
            continue;
          }
        } else {
          final effectiveChannel =
              m.channelId ?? defaultSpaceChannelId(man.groupId);
          final protected = protectedChannels[effectiveChannel.hex];
          if (!mergedState.channels.containsKey(effectiveChannel.hex) &&
              protected == null) {
            continue;
          }
          if (protected != null) {
            final opaque = mergedState.protectedChannels[effectiveChannel.hex];
            if (!m.isChannelEncrypted ||
                opaque == null ||
                m.channelEpoch != opaque.channelEpoch ||
                !protected.recipients.contains(m.author)) {
              continue;
            }
          } else if (m.isChannelEncrypted) {
            continue;
          }
        }
      } else if (m.spacePostId != null) {
        continue;
      }
      if (m.isEncrypted) {
        if (m.isChannelEncrypted) {
          final channelId = m.channelId!;
          final epoch = m.channelEpoch!;
          final key = channelMaterial.keys[_channelKeyId(channelId, epoch)];
          if (key == null ||
              !_validLocalChannelEpochKey(
                man,
                control,
                channelId,
                epoch,
                key,
              ) ||
              !mergedState.isMember(m.author)) {
            continue;
          }
          final visible = await _materializeEncryptedMessage(materialBundle, m);
          if (visible == null ||
              (visible.attachment != null &&
                  (visible.attachment!.inlinePreviewB64 != null ||
                      !visible.attachment!.isReferenceStructurallyValid))) {
            // Protected media must remain a strict CID reference encrypted by
            // the channel envelope. Inline/legacy payloads cannot bypass the
            // separately signed channel-scoped content grant.
            continue;
          }
        } else {
          final epoch = m.membershipEpoch!;
          final key = material.keys[epoch];
          if (key == null ||
              !_validLocalEpochKey(man, control, epoch, key) ||
              !mergedState.isMember(m.author)) {
            continue;
          }
          if (m.spacePostId != null) {
            final visible = await _materializeEncryptedMessage(
              materialBundle,
              m,
            );
            if (visible == null ||
                (visible.attachment != null &&
                    (visible.attachment!.inlinePreviewB64 != null ||
                        !visible.attachment!.isReferenceStructurallyValid))) {
              continue;
            }
          }
        }
      } else if (encryptionEstablished || !mergedState.isMember(m.author)) {
        // Once a signed epoch descriptor exists, a clear v1 row is a
        // downgrade attempt. Historical local v1 rows remain readable but are
        // never newly imported into an encrypted group.
        continue;
      }
      final incomingHash = groupMessageHash(m);
      if (!messages.any(
        (stored) =>
            _validMessageFor(manifest.groupId, stored) &&
            groupMessageHash(stored) == incomingHash,
      )) {
        messages.add(m);
      }
    }
    // Merge remote retention cuts AFTER the message merge: the anchor check in
    // _acceptableRemoteRetentionCut must run against the final, validated
    // `messages` — a legitimate post-sweep snapshot delivers the retained
    // anchor in this same payload, and checking pre-merge would reject it (and
    // hide the suffix) while checking against raw unvalidated incoming rows
    // would let a forged anchor re-open the censorship vector.
    final mergedRetentionCuts = <String, SpaceRetentionCut>{
      ...?existing?.retentionCuts,
    };
    if (ingestRetention != null) {
      for (final cut in inRetentionCuts) {
        if (!_acceptableRemoteRetentionCut(
          manifest: man,
          revisions: ingestRetention.revisions,
          localMessages: messages,
          cut: cut,
          atMs: ingestAtMs,
        )) {
          continue;
        }
        final key = retentionCutKey(cut.scope, cut.author);
        final prior = mergedRetentionCuts[key];
        if (prior == null || cut.throughSeq > prior.throughSeq) {
          mergedRetentionCuts[key] = cut;
        }
      }
    }
    // Notify only rows that became part of an accepted scoped chain. A suffix
    // received before its predecessor stays silent; when gap-fill later closes
    // the chain, the predecessor and newly-unblocked suffix become visible in
    // one deterministic batch. Fork evidence never produces a notification.
    fresh.addAll(
      _acceptedMessagesWithinLifecycle(
        materialBundle.copyWith(
          messages: messages,
          retentionCuts: mergedRetentionCuts,
        ),
        mergedState,
      ).where(
        (message) =>
            message.author != _signer.selfId &&
            !acceptedMessageHashesBefore.contains(groupMessageHash(message)),
      ),
    );
    for (final post in inPosts) {
      if (!man.isSpace || !_validPostFor(man.groupId, post)) continue;
      if (!_postWithinLifecycleBoundary(mergedState, post)) continue;
      if (ingestRetention != null &&
          _retentionRetiresPost(
            manifest: man,
            state: mergedState,
            revisions: ingestRetention.revisions,
            post: post,
            atMs: ingestAtMs,
          )) {
        continue;
      }
      final historicallyAuthorized =
          post.isCausal &&
          _causalPostHistoricallyAuthorized(man, control, post);
      final legacyAuthorized =
          !post.isCausal &&
          SpaceAcl(mergedState).allows(
            post.author,
            SpacePermission.publishPosts,
            atMs: post.createdAtMs,
          );
      if (!historicallyAuthorized && !legacyAuthorized) continue;
      if (post.visibility == SpacePostVisibility.public) {
        if (man.visibility != SpaceVisibility.public) {
          continue;
        }
      } else {
        final epoch = post.membershipEpoch!;
        final key = material.keys[epoch];
        if (!post.isEncrypted ||
            key == null ||
            !_validLocalEpochKey(man, control, epoch, key)) {
          continue;
        }
        if (await _materializeEncryptedPost(
              GroupBundle(
                manifest: man,
                control: control,
                messages: messages,
                posts: posts,
                reactions: reactions,
                publicComments: publicComments,
                publicReactions: publicReactions,
                epochEnvelopes: material.envelopes,
                localEpochKeys: material.keys,
                channelEpochEnvelopes: channelMaterial.envelopes,
                localChannelEpochKeys: channelMaterial.keys,
              ),
              post,
            ) ==
            null) {
          continue;
        }
      }
      final existingIndex = posts.indexWhere(
        (stored) =>
            _validPostFor(man.groupId, stored) &&
            _spacePostHash(stored) == _spacePostHash(post),
      );
      if (existingIndex < 0) {
        posts.add(post);
      }
    }
    final targetBundle = GroupBundle(
      manifest: man,
      control: control,
      messages: messages,
      posts: posts,
      reactions: reactions,
      publicComments: publicComments,
      publicReactions: publicReactions,
      epochEnvelopes: material.envelopes,
      localEpochKeys: material.keys,
      channelEpochEnvelopes: channelMaterial.envelopes,
      localChannelEpochKeys: channelMaterial.keys,
      retentionCuts: mergedRetentionCuts,
    );
    final visiblePostIds = man.isSpace
        ? {for (final post in await _postsOfBundle(targetBundle)) post.postId}
        : const <String>{};
    final acceptedMessages = _acceptedMessagesWithinLifecycle(
      targetBundle,
      mergedState,
    );
    final acceptedOpenMessageRefs = {
      for (final message in acceptedMessages)
        if (!message.isChannelEncrypted) message.ref,
    };
    final acceptedProtectedMessages = <String, GroupMessage>{};
    for (final message in acceptedMessages) {
      if (!message.isChannelEncrypted ||
          protectedChannels[message.channelId!.hex] == null) {
        continue;
      }
      final visible = await _materializeEncryptedMessage(targetBundle, message);
      if (visible != null) acceptedProtectedMessages[message.ref] = visible;
    }
    for (final r in inReactions) {
      if (!_validReactionFor(manifest.groupId, r) ||
          !_reactionWithinLifecycleBoundary(mergedState, r) ||
          !SpaceAcl(mergedState).allows(
            r.author,
            SpacePermission.publishMessages,
            atMs: r.createdAtMs,
          )) {
        continue;
      }
      if (ingestRetention != null &&
          _retentionRetiresReaction(
            manifest: man,
            revisions: ingestRetention.revisions,
            hiddenThroughMs: ingestRetention.hiddenThroughMs,
            reaction: r,
            atMs: ingestAtMs,
          )) {
        continue;
      }
      GroupReaction? visibleReaction;
      if (r.isChannelEncrypted) {
        final channelId = r.channelId!;
        final protected = protectedChannels[channelId.hex];
        final key =
            channelMaterial.keys[_channelKeyId(channelId, r.channelEpoch!)];
        if (protected == null ||
            !protected.recipients.contains(r.author) ||
            key == null ||
            !_validLocalChannelEpochKey(
              man,
              control,
              channelId,
              r.channelEpoch!,
              key,
            )) {
          continue;
        }
        visibleReaction = await _materializeEncryptedReaction(targetBundle, r);
      } else if (r.isMembershipEncrypted) {
        final epoch = r.membershipEpoch!;
        final key = material.keys[epoch];
        if (key == null || !_validLocalEpochKey(man, control, epoch, key)) {
          continue;
        }
        visibleReaction = await _materializeEncryptedReaction(targetBundle, r);
      } else if (encryptionEstablished) {
        continue;
      } else {
        visibleReaction = r;
      }
      if (visibleReaction == null) continue;
      final targetExists = switch (visibleReaction.targetKind) {
        ReactionTargetKind.message =>
          r.isChannelEncrypted
              ? acceptedProtectedMessages[visibleReaction.target]?.channelId ==
                    r.channelId
              : acceptedOpenMessageRefs.contains(visibleReaction.target),
        ReactionTargetKind.spacePost =>
          man.isSpace && visiblePostIds.contains(visibleReaction.target),
      };
      if (!targetExists) {
        // A Space-epoch reaction must not become an oracle for protected or
        // deleted content. Unknown/out-of-order targets stay retryable through
        // the per-author reaction sync vector.
        continue;
      }
      if (!reactions.any(
        (stored) =>
            _validReactionFor(manifest.groupId, stored) &&
            stored.author == r.author &&
            stored.seq == r.seq,
      )) {
        reactions.add(r);
      }
    }
    if (man.isSpace && man.visibility == SpaceVisibility.public) {
      final publicLifecycle =
          mergedState.lifecycleTransitionHash ??
          _legacyPostGeneration(man.groupId);
      final acceptedMessageHashes = {
        for (final message in acceptedMessages) groupMessageHash(message),
      };
      for (final comment in inPublicComments) {
        if (!_validPublicCommentFor(man.groupId, comment) ||
            comment.lifecycleGeneration != publicLifecycle ||
            !visiblePostIds.contains(comment.postId)) {
          continue;
        }
        GroupMessage? memberRow;
        for (final candidate in messages) {
          if (candidate.author == comment.author &&
              candidate.seq == comment.seq &&
              candidate.spacePostId == comment.postId &&
              acceptedMessageHashes.contains(groupMessageHash(candidate))) {
            memberRow = candidate;
            break;
          }
        }
        if (memberRow == null) continue;
        final visible = await _materializeEncryptedMessage(
          targetBundle,
          memberRow,
        );
        if (visible == null ||
            (visible.lifecycleGeneration ??
                    _legacyPostGeneration(man.groupId)) !=
                comment.lifecycleGeneration) {
          continue;
        }
        final matches = switch (comment.operation) {
          SpacePublicCommentOperation.create =>
            visible.editOf == null &&
                visible.deleteOf == null &&
                visible.body == comment.body &&
                visible.replyTo == comment.replyTo &&
                jsonEncode(visible.attachment?.toJson()) ==
                    jsonEncode(comment.media?.toJson()),
          SpacePublicCommentOperation.edit =>
            visible.editOf == comment.ref &&
                visible.deleteOf == null &&
                visible.body == comment.body &&
                visible.attachment == null &&
                visible.replyTo == null,
          SpacePublicCommentOperation.delete =>
            visible.editOf == null &&
                visible.deleteOf == comment.ref &&
                visible.body.isEmpty &&
                visible.attachment == null &&
                visible.replyTo == null,
        };
        if (matches &&
            !publicComments.any(
              (stored) => stored.recordHash == comment.recordHash,
            )) {
          publicComments.add(comment);
        }
      }
      for (final reaction in inPublicReactions) {
        if (!_validPublicReactionFor(man.groupId, reaction) ||
            reaction.lifecycleGeneration != publicLifecycle ||
            !visiblePostIds.contains(reaction.postId)) {
          continue;
        }
        GroupReaction? memberRow;
        for (final candidate in reactions) {
          if (candidate.author == reaction.author &&
              candidate.seq == reaction.seq) {
            memberRow = candidate;
            break;
          }
        }
        if (memberRow == null) continue;
        final visible = await _materializeEncryptedReaction(
          targetBundle,
          memberRow,
        );
        if (visible == null ||
            visible.targetKind != ReactionTargetKind.spacePost ||
            visible.target != reaction.postId ||
            visible.emoji != reaction.emoji ||
            (visible.lifecycleGeneration ??
                    _legacyPostGeneration(man.groupId)) !=
                reaction.lifecycleGeneration) {
          continue;
        }
        if (!publicReactions.any(
          (stored) => stored.recordHash == reaction.recordHash,
        )) {
          publicReactions.add(reaction);
        }
      }
    }
    final saved = GroupBundle(
      manifest: man,
      control: control,
      messages: messages,
      posts: posts,
      reactions: reactions,
      publicComments: publicComments,
      publicReactions: publicReactions,
      epochEnvelopes: material.envelopes,
      localEpochKeys: material.keys,
      channelEpochEnvelopes: channelMaterial.envelopes,
      localChannelEpochKeys: channelMaterial.keys,
      sovereignBundle: existing?.sovereignBundle ?? incomingSovereignBundle,
      retentionCuts: mergedRetentionCuts,
    );
    final feedAccessChanged = hadFeedAccess != hasFeedAccess;
    await _save(saved, notify: !feedAccessChanged);
    if (feedAccessChanged) _invalidateFeedAccess();
    final freshPosts = !man.isSpace
        ? const <SpacePostView>[]
        : (await _postsOfBundle(saved))
              .where(
                (post) =>
                    post.author != _signer.selfId &&
                    !acceptedPostIdsBefore.contains(post.postId),
              )
              .toList();
    if (deletionTombstone != null) {
      await _clearDeletedSpaceTombstone(man.groupId);
    }
    final adoptedDeviceGroup =
        man.name == kDeviceGroupName &&
        await deviceGroupIdHex() == man.groupId.hex;
    if (adoptedDeviceGroup) {
      _publishDeviceMembersCache(man, mergedState);
    }
    if (existing == null) {
      final idx = await _index();
      if (!idx.contains(man.groupId.hex)) {
        idx.add(man.groupId.hex);
        await _setIndex(idx);
      }
    }
    if (man.name != kDeviceGroupName &&
        _epochService != null &&
        _encryptionEstablished(man, control) &&
        mergedState.epochDescriptor == null &&
        mergedState.memberOf(_signer.selfId)?.role == GroupRole.owner) {
      // A leave or a concurrent stale departure descriptor advances
      // membership without a usable key. Only the effective owner repairs it,
      // avoiding an admin race; writes remain fail-closed until this succeeds.
      unawaited(addControlOp(man.groupId, ControlOp.rotateEpoch));
    }
    if (man.isSpace &&
        mergedState.roleOf(_signer.selfId) == GroupRole.owner &&
        mergedState.protectedChannels.isNotEmpty) {
      // A remote membership/role mutation may invalidate the encrypted ACL.
      // Only the effective owner repairs it to avoid concurrent admins creating
      // competing epoch+1 revisions; until then materialization is fail-closed.
      unawaited(_repairProtectedChannelEpochs(man.groupId));
    }
    // Device-group traffic is sync machinery, not chat: it must never buzz
    // the notification layer or count as chat-unread. It routes to a SEPARATE
    // stream the multi-device bridge consumes (device-sync events).
    if (man.name == kDeviceGroupName) {
      // A marker snapshot is inert until the local handshake explicitly
      // adopts this exact gid. Otherwise any contact could plant a valid-
      // looking infrastructure group and drive sync apply side effects.
      if (adoptedDeviceGroup) {
        for (final m in fresh) {
          final materialized = await _materializeEncryptedMessage(saved, m);
          if (materialized != null) _deviceIncomingCtl.add(materialized);
        }
      }
    } else {
      for (final m in fresh) {
        final materialized = await _materializeEncryptedMessage(saved, m);
        if (materialized != null) {
          if (materialized.spacePostId == null) {
            _incomingCtl.add((groupId: man.groupId, message: materialized));
          } else if (materialized.editOf == null &&
              materialized.deleteOf == null) {
            _incomingCommentCtl.add((
              spaceId: man.groupId,
              message: materialized,
            ));
          }
        }
      }
      for (final post in freshPosts) {
        _incomingPostCtl.add((spaceId: man.groupId, post: post));
      }
    }
    return true;
  }

  /// Fresh (post-dedup, verified, not-self) messages of MY device group — the
  /// multi-device bridge folds these into DeviceSyncEvents and applies them.
  final StreamController<GroupMessage> _deviceIncomingCtl =
      StreamController.broadcast();
  Stream<GroupMessage> get deviceIncoming => _deviceIncomingCtl.stream;

  /// Genuinely-NEW inbound messages (post-dedup, signature-verified, not
  /// self-authored) — the notification/unread layer's feed, symmetric to
  /// MessagingService.incoming.
  final StreamController<({NodeId groupId, GroupMessage message})>
  _incomingCtl = StreamController.broadcast();
  Stream<({NodeId groupId, GroupMessage message})> get incoming =>
      _incomingCtl.stream;

  /// Newly accepted SpacePost comments are deliberately separate from the
  /// channel/group incoming stream so chat unread and notifications cannot
  /// misclassify a publication discussion as a chat message.
  final StreamController<({NodeId spaceId, GroupMessage message})>
  _incomingCommentCtl = StreamController.broadcast();
  Stream<({NodeId spaceId, GroupMessage message})> get incomingComments =>
      _incomingCommentCtl.stream;

  /// Newly accepted publication roots after validation, ACL checks,
  /// decryption and chain folding. Edits keep the root id and therefore do not
  /// generate another alert; fork evidence and tombstoned rows never enter the
  /// stream.
  final StreamController<({NodeId spaceId, SpacePostView post})>
  _incomingPostCtl = StreamController.broadcast();
  Stream<({NodeId spaceId, SpacePostView post})> get incomingPosts =>
      _incomingPostCtl.stream;

  /// Newly observed roots from an already-active public-only subscription.
  /// Initial history is silent; only a later verified snapshot emits here.
  final StreamController<({NodeId spaceId, SpacePostView post})>
  _incomingPublicPostCtl = StreamController.broadcast();
  Stream<({NodeId spaceId, SpacePostView post})> get incomingPublicPosts =>
      _incomingPublicPostCtl.stream;

  /// Newly observed author-signed public comment roots from an already-active
  /// public-only subscription. Imported history and immutable edits are
  /// silent; only a newly visible root is eligible for mention notification.
  final StreamController<({NodeId spaceId, SpacePublicCommentView comment})>
  _incomingPublicCommentCtl = StreamController.broadcast();
  Stream<({NodeId spaceId, SpacePublicCommentView comment})>
  get incomingPublicComments => _incomingPublicCommentCtl.stream;

  /// Attached by the multi-device bridge: a LOCAL group-seen advance (never
  /// fired from [applyMirroredGroupSeen]) — my other devices clear the badge.
  void Function(String gidHex, int tsMs)? onGroupSeen;

  /// Mark [groupId] read "as of now" — the unread watermark the open group
  /// screen advances. A local display preference, not group state.
  Future<void> markGroupSeen(NodeId groupId) async {
    final ts = _now();
    await _storage.putSetting('group.seen:${groupId.hex}', '$ts');
    onGroupSeen?.call(groupId.hex, ts);
  }

  /// Apply a group-seen watermark mirrored from ANOTHER of my devices —
  /// monotonic, straight to storage (no [onGroupSeen] echo). Returns whether
  /// the watermark advanced.
  Future<bool> applyMirroredGroupSeen(String gidHex, int tsMs) async {
    final cur =
        int.tryParse(await _storage.getSetting('group.seen:$gidHex') ?? '') ??
        0;
    if (cur >= tsMs) return false;
    await _storage.putSetting('group.seen:$gidHex', '$tsMs');
    changes.value++; // group list re-renders its badge
    return true;
  }

  /// How many VALIDATED messages of [groupId] are newer than the seen
  /// watermark and not self-authored.
  Future<int> unreadOf(NodeId groupId) async {
    final wm =
        int.tryParse(
          await _storage.getSetting('group.seen:${groupId.hex}') ?? '',
        ) ??
        0;
    final msgs = await messagesOf(groupId);
    return msgs.where((m) => m.createdAtMs > wm && m.author != selfId).length;
  }

  String _groupNotificationPolicyKey(NodeId groupId) =>
      'group.notification-policy.v1:${groupId.hex}';

  /// Local notification policy for [groupId]. It remains in the encrypted
  /// identity store and is distinct from the CONTROL-LOG member mute, which is
  /// about posting rights. The old boolean key decodes as "nothing, forever".
  Future<void> setGroupNotificationPolicy(
    NodeId groupId,
    NotificationMuteMode mode,
    DateTime? until,
  ) async {
    final clear = mode == NotificationMuteMode.all || until == null;
    await _storage.putSetting(
      _groupNotificationPolicyKey(groupId),
      clear
          ? ''
          : jsonEncode({
              'mode': mode.name,
              'until': until.millisecondsSinceEpoch,
            }),
    );
    // Clear the legacy flag so it cannot shadow an explicit new policy.
    await _storage.putSetting('group.muted:${groupId.hex}', '');
    changes.value++;
  }

  Future<NotificationMutePolicy> groupNotificationPolicy(NodeId groupId) async {
    final raw = await _storage.getSetting(_groupNotificationPolicyKey(groupId));
    if (raw != null && raw.isNotEmpty) {
      try {
        final value = jsonDecode(raw);
        if (value is Map && value['until'] is int) {
          final mode = NotificationMuteMode.values.firstWhere(
            (candidate) => candidate.name == value['mode'],
            orElse: () => NotificationMuteMode.none,
          );
          return NotificationMutePolicy(
            mode: mode,
            until: DateTime.fromMillisecondsSinceEpoch(value['until'] as int),
          );
        }
      } catch (_) {
        // Corrupt local preference fails open to normal notifications.
      }
      return const NotificationMutePolicy.all();
    }
    if ((await _storage.getSetting('group.muted:${groupId.hex}')) == '1') {
      return NotificationMutePolicy(
        mode: NotificationMuteMode.none,
        until: kMuteForever,
      );
    }
    return const NotificationMutePolicy.all();
  }

  /// Compatibility wrapper retained for older UI/tests.
  Future<void> setGroupMuted(NodeId groupId, bool muted) async {
    await setGroupNotificationPolicy(
      groupId,
      muted ? NotificationMuteMode.none : NotificationMuteMode.all,
      muted ? kMuteForever : null,
    );
  }

  Future<bool> isGroupMuted(NodeId groupId) async =>
      (await groupNotificationPolicy(groupId)).effectiveAt(DateTime.now()) !=
      NotificationMuteMode.all;

  // ── Device group (multi-device epic, doc/MULTIDEVICE-DESIGN.md) ──────────

  /// The reserved manifest name marking a DEVICE group (my devices' private
  /// sync group). Groups with this name are hidden from every user-facing
  /// list; the leading space cannot be produced through the create/rename
  /// dialogs (both trim their input).
  static const String kDeviceGroupName = ' xveil.devices';
  static const String kSovereignBundleSetting = 'devices.sovereign.bundle.v1';
  static const String kPendingDeviceAdoptionSetting =
      'devices.pending_adoption.v1';

  String? _deviceGidCache;

  /// My device group's id (hex), or null before the first link/adopt.
  Future<String?> deviceGroupIdHex() async {
    _deviceGidCache ??= await _storage.getSetting('devices.gid');
    return (_deviceGidCache?.isEmpty ?? true) ? null : _deviceGidCache;
  }

  /// Debug/stand repair for the historical broken state (2026-07-13) where
  /// the `devices.gid` pointer survived while its group bundle was lost on
  /// every device: with the pointer stuck, [linkDevice] loads the missing
  /// bundle and fails before it can mint a fresh sovereign group. Clearing
  /// is refused while the pointed-at bundle actually exists, so a working
  /// device group can never be detached by this path.
  Future<bool> clearStaleDeviceGroupPointer() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return true;
    try {
      if (await load(NodeId.fromHex(hex)) != null) return false;
    } catch (_) {
      return false;
    }
    await _storage.putSetting('devices.gid', '');
    _deviceGidCache = null;
    _invalidateDeviceMembersCache();
    return true;
  }

  /// The encrypted sovereign credential (XVSB/XVRC) is persisted in the
  /// CHUNKED file store: the hybrid blob (~2.3 KiB raw, ~3.1 KiB base64)
  /// exceeds a single hidden-volume settings record, so the settings path
  /// failed with PayloadTooLarge on EVERY store — found live 2026-07-25 on
  /// the first real link ceremony (the closed-loop tests run on a fake
  /// store that does not enforce the record cap). The legacy settings key
  /// is still read as a fallback so a store that did persist a credential
  /// there keeps opening it.
  Future<({Uint8List? bundle, bool corrupt})> _readSovereignCredential() async {
    Uint8List? file;
    try {
      file = await _storage.loadFile(kSovereignBundleSetting);
    } catch (_) {
      return (bundle: null, corrupt: true);
    }
    if (file != null) {
      if (file.isEmpty || file.length > 16 * 1024) {
        return (bundle: null, corrupt: true);
      }
      return (bundle: Uint8List.fromList(file), corrupt: false);
    }
    final raw = await _storage.getSetting(kSovereignBundleSetting);
    if (raw == null || raw.isEmpty) return (bundle: null, corrupt: false);
    try {
      final value = Uint8List.fromList(base64Decode(raw));
      if (value.isEmpty || value.length > 16 * 1024) {
        return (bundle: null, corrupt: true);
      }
      return (bundle: value, corrupt: false);
    } catch (_) {
      return (bundle: null, corrupt: true);
    }
  }

  Future<void> _writeSovereignCredential(Uint8List bundle) =>
      _storage.storeFile(
        kSovereignBundleSetting,
        Uint8List.fromList(bundle),
        name: 'sovereign-credential',
      );

  Future<void> _clearSovereignCredential() async {
    try {
      await _storage.deleteStoredFile(kSovereignBundleSetting);
    } catch (_) {}
    try {
      await _storage.putSetting(kSovereignBundleSetting, '');
    } catch (_) {}
  }

  Future<Uint8List?> localSovereignBundle() async =>
      (await _readSovereignCredential()).bundle;

  /// Decrypt the persisted bundle in native RAM for one signing burst. The
  /// first phrase-backed operation creates and stores only an encrypted blob.
  Future<NativeSovereignGroupSigner> openLocalSovereign(
    String phrase, {
    bool createIfMissing = true,
  }) async {
    final stored = await _readSovereignCredential();
    if (stored.corrupt) {
      // Fail closed: an unreadable existing credential is never silently
      // replaced (that would be a silent owner rotation).
      throw StateError('Local sovereign bundle is corrupt');
    }
    var bundle = stored.bundle;
    if (bundle == null && createIfMissing) {
      bundle = veil.createHybrid512SovereignBundle(phrase);
      await _writeSovereignCredential(bundle);
    }
    if (bundle == null) throw StateError('No local sovereign bundle');
    final magic = bundle.length >= 4
        ? ascii.decode(bundle.sublist(0, 4), allowInvalid: true)
        : '';
    return magic == 'XVRC'
        ? NativeSovereignGroupSigner.openRecoveryCertificate(bundle, phrase)
        : NativeSovereignGroupSigner.openBundle(bundle, phrase);
  }

  /// How the persisted sovereign material is unlocked. Missing/corrupt stays
  /// null; callers must not guess that a legacy identity has a phrase.
  Future<String?> sovereignCredentialKind() async {
    final bundle = await localSovereignBundle();
    if (bundle == null || bundle.length < 4) return null;
    final magic = ascii.decode(bundle.sublist(0, 4), allowInvalid: true);
    return switch (magic) {
      'XVSB' => 'phrase',
      'XVRC' => 'certificate',
      _ => null,
    };
  }

  /// Export a fresh XVRC + independent 256-bit code from the current XVSB or
  /// XVRC credential. Decrypted key bytes never enter Dart.
  Future<({Uint8List certificate, String code, NodeId nodeId})?>
  exportRecoveryCertificate(String currentSecret) async {
    var credential = await localSovereignBundle();
    if (credential == null) {
      // A phrase-backed identity may pre-issue its certificate BEFORE its first
      // device link. Provision the normal XVSB once, exactly as link would.
      final provisioned = await openLocalSovereign(currentSecret);
      provisioned.close();
      credential = await localSovereignBundle();
    }
    if (credential == null) return null;
    final code = veil.generateSovereignRecoveryCode();
    final certificate = veil.exportSovereignRecoveryCertificate(
      credential,
      currentSecret,
      code,
    );
    final signer = NativeSovereignGroupSigner.openRecoveryCertificate(
      certificate,
      code,
    );
    try {
      return (certificate: certificate, code: code, nodeId: signer.nodeId);
    } finally {
      signer.close();
    }
  }

  /// All-devices-lost recovery: install one XVRC only into a fresh local
  /// device-registry state, then mint a fresh gid owned by the SAME full hybrid
  /// public key/node id. Never overwrites a different credential or group.
  Future<NodeId?> recoverDeviceGroupFromCertificate(
    Uint8List certificate,
    String recoveryCode,
  ) async {
    if (await deviceGroupIdHex() != null) return null;
    final existing = await localSovereignBundle();
    if (existing != null && !_listEquals(existing, certificate)) return null;
    final signer = NativeSovereignGroupSigner.openRecoveryCertificate(
      certificate,
      recoveryCode,
    );
    var installed = false;
    try {
      if (signer.algorithm != 'ed25519+falcon512') return null;
      if (existing == null) {
        await _writeSovereignCredential(certificate);
        installed = true;
      }
      final gid = await _mintSovereignDeviceGroup(signer, const []);
      if (gid == null && installed) {
        await _clearSovereignCredential();
      }
      return gid;
    } catch (_) {
      if (installed) {
        await _clearSovereignCredential();
      }
      rethrow;
    } finally {
      signer.close();
    }
  }

  Uint8List _manifestHash(GroupManifest manifest) =>
      _sha256(utf8.encode(jsonEncode(manifest.toJson())));

  Future<DeviceLinkToken?> pendingDeviceAdoption() async {
    final raw = await _storage.getSetting(kPendingDeviceAdoptionSetting);
    if (raw == null || raw.isEmpty) return null;
    try {
      final token = DeviceLinkToken.fromJson(jsonDecode(raw));
      if (token == null || token.isExpired(_now())) return null;
      return token;
    } catch (_) {
      return null;
    }
  }

  /// Explicit target-side consent. Until this token is stored, a stranger can
  /// never materialize a new marker group. The token pins source, gid and the
  /// exact signed manifest; the subsequent snapshot still passes all normal
  /// signature, bundle-hash and self-membership checks.
  Future<bool> prepareDeviceAdoption(DeviceLinkToken token) async {
    if (token.source == _signer.selfId || token.isExpired(_now())) return false;
    await _storage.putSetting(
      kPendingDeviceAdoptionSetting,
      jsonEncode(token.toJson()),
    );
    return true;
  }

  Future<void> cancelPendingDeviceAdoption() =>
      _storage.putSetting(kPendingDeviceAdoptionSetting, '');

  /// Build the short QR token after the source has sovereign-signed the target
  /// into the local registry but before it broadcasts the encrypted snapshot.
  Future<DeviceLinkToken?> createDeviceLinkToken(
    BootstrapInvite sourceInvite,
  ) async {
    if (sourceInvite.nodeId != _signer.selfId) return null;
    final gidHex = await deviceGroupIdHex();
    if (gidHex == null) return null;
    final bundle = await load(NodeId.fromHex(gidHex));
    if (bundle == null || !bundle.manifest.isSovereignDevice) return null;
    return DeviceLinkToken(
      groupId: bundle.manifest.groupId,
      source: _signer.selfId,
      manifestHash: _manifestHash(bundle.manifest),
      sourceInvite: sourceInvite,
      expiresAtMs: _now() + const Duration(minutes: 30).inMilliseconds,
    );
  }

  Future<int> broadcastDeviceGroup() async {
    final gidHex = await deviceGroupIdHex();
    if (gidHex == null) return 0;
    return broadcast(NodeId.fromHex(gidHex));
  }

  bool _sovereignMatches(
    GroupManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == sovereign.algorithm &&
      manifest.owner == sovereign.nodeId &&
      _listEquals(manifest.genesisPubKey, sovereign.publicKey);

  bool _canUpgradeSovereign(
    GroupManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == 'ed25519' &&
      sovereign.algorithm == 'ed25519+falcon512' &&
      sovereign.publicKey.length == 929 &&
      _listEquals(manifest.genesisPubKey, sovereign.publicKey.sublist(0, 32));

  Future<NodeId?> _mintSovereignDeviceGroup(
    SovereignGroupSigner sovereign,
    Iterable<NodeId> devices, {
    GroupBundle? migrateFrom,
    bool broadcastSnapshot = true,
  }) async {
    final encryptedSovereign = await localSovereignBundle();
    if (sovereign.algorithm != 'ed25519' && encryptedSovereign == null) {
      devLog(() => 'xVeil[devices]: mint refused: no persisted sovereign blob');
      return null;
    }
    final gid = _randomGroupId();
    final unsignedManifest = GroupManifest(
      groupId: gid,
      owner: sovereign.nodeId,
      genesisPubKey: Uint8List.fromList(sovereign.publicKey),
      name: kDeviceGroupName,
      createdAtMs: _now(),
      version: GroupManifest.sovereignDeviceVersion,
      kind: GroupManifest.sovereignDeviceKind,
      signatureAlgorithm: sovereign.algorithm,
      sovereignBundleHash: encryptedSovereign == null
          ? null
          : _sha256(encryptedSovereign),
    );
    final manifest = unsignedManifest.withSignature(
      sovereign.sign(unsignedManifest.canonicalBytes()),
    );
    if (!_validManifest(manifest)) {
      devLog(
        () =>
            'xVeil[devices]: mint refused: manifest failed validation '
            '(alg=${manifest.signatureAlgorithm} sig=${manifest.signature.length} '
            'pk=${manifest.genesisPubKey.length})',
      );
      return null;
    }

    final unique = <String, NodeId>{
      _signer.selfId.hex: _signer.selfId,
      for (final d in devices) d.hex: d,
    }..remove(sovereign.nodeId.hex);
    final ordered = unique.values.toList()
      ..sort((a, b) => a.hex.compareTo(b.hex));
    final control = <ControlEntry>[];
    final baseTs = _now();
    for (var seq = 0; seq < ordered.length; seq++) {
      final unsigned = ControlEntry(
        version: 2,
        groupId: gid,
        author: sovereign.nodeId,
        seq: seq,
        prevHash: control.isEmpty ? '' : controlEntryHash(control.last),
        op: ControlOp.addMember,
        target: ordered[seq],
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: baseTs + seq,
        signature: Uint8List(0),
      );
      control.add(
        unsigned.withSignature(
          sovereign.sign(unsigned.canonicalBytes()),
          Uint8List.fromList(sovereign.publicKey),
        ),
      );
    }
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (e) => _validControlFor(manifest, e),
      initialName: manifest.name,
    );
    if (folded.rejected.isNotEmpty || !folded.state.isMember(_signer.selfId)) {
      devLog(
        () =>
            'xVeil[devices]: mint refused: control fold rejected='
            '${folded.rejected.length} selfMember='
            '${folded.state.isMember(_signer.selfId)}',
      );
      return null;
    }

    final migratedMessages = <GroupMessage>[];
    if (migrateFrom != null) {
      final oldState = foldControlLog(
        owner: migrateFrom.manifest.owner,
        entries: migrateFrom.control,
        verify: (e) => _validControlFor(migrateFrom.manifest, e),
        initialName: migrateFrom.manifest.name,
      ).state;
      final compact =
          _compactDeviceMessages(migrateFrom.manifest.groupId, [
            for (final m in migrateFrom.messages)
              if (oldState.isMember(m.author)) m,
          ])..sort((a, b) {
            final ts = a.createdAtMs.compareTo(b.createdAtMs);
            return ts != 0 ? ts : _messageIdentityCompare(a, b);
          });
      for (var seq = 0; seq < compact.length; seq++) {
        final old = compact[seq];
        final unsigned = GroupMessage(
          groupId: gid,
          author: _signer.selfId,
          seq: seq,
          prevHash: '',
          body: old.body,
          policyVersion: 0,
          createdAtMs: old.createdAtMs,
          signature: Uint8List(0),
          attachment: old.attachment,
          customEmoji: old.customEmoji,
        );
        migratedMessages.add(_signer.signMessage(unsigned));
      }
    }

    await _save(
      GroupBundle(
        manifest: manifest,
        control: control,
        messages: migratedMessages,
        sovereignBundle: encryptedSovereign,
      ),
    );
    final idx = await _index();
    if (!idx.contains(gid.hex)) {
      idx.add(gid.hex);
      await _setIndex(idx);
    }
    await _storage.putSetting('devices.gid', gid.hex);
    _deviceGidCache = gid.hex;
    _publishDeviceMembersCache(manifest, folded.state);
    if (broadcastSnapshot) await broadcast(gid);
    return gid;
  }

  /// Debug-only stage report for a failing sovereign link: replays the mint
  /// checks without persisting anything, so a stand operator can see WHICH
  /// gate refuses (blob, manifest signature, control fold) instead of a
  /// silent false. Never called from production UI.
  Future<Map<String, Object?>> debugSovereignLinkDiagnostics(
    SovereignGroupSigner sovereign,
    NodeId device,
  ) async {
    final encryptedSovereign = await localSovereignBundle();
    final gid = _randomGroupId();
    final unsignedManifest = GroupManifest(
      groupId: gid,
      owner: sovereign.nodeId,
      genesisPubKey: Uint8List.fromList(sovereign.publicKey),
      name: kDeviceGroupName,
      createdAtMs: _now(),
      version: GroupManifest.sovereignDeviceVersion,
      kind: GroupManifest.sovereignDeviceKind,
      signatureAlgorithm: sovereign.algorithm,
      sovereignBundleHash: encryptedSovereign == null
          ? null
          : _sha256(encryptedSovereign),
    );
    final manifest = unsignedManifest.withSignature(
      sovereign.sign(unsignedManifest.canonicalBytes()),
    );
    final directVerify = _signer.verifySovereign(
      algorithm: manifest.signatureAlgorithm!,
      nodeId: manifest.owner,
      publicKey: manifest.genesisPubKey,
      message: manifest.canonicalBytes(),
      signature: manifest.signature,
    );
    final unique = <String, NodeId>{
      _signer.selfId.hex: _signer.selfId,
      device.hex: device,
    }..remove(sovereign.nodeId.hex);
    final ordered = unique.values.toList()
      ..sort((a, b) => a.hex.compareTo(b.hex));
    final control = <ControlEntry>[];
    final baseTs = _now();
    for (var seq = 0; seq < ordered.length; seq++) {
      final unsigned = ControlEntry(
        version: 2,
        groupId: gid,
        author: sovereign.nodeId,
        seq: seq,
        prevHash: control.isEmpty ? '' : controlEntryHash(control.last),
        op: ControlOp.addMember,
        target: ordered[seq],
        role: GroupRole.member,
        policyVersion: 0,
        createdAtMs: baseTs + seq,
        signature: Uint8List(0),
      );
      control.add(
        unsigned.withSignature(
          sovereign.sign(unsigned.canonicalBytes()),
          Uint8List.fromList(sovereign.publicKey),
        ),
      );
    }
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (e) => _validControlFor(manifest, e),
      initialName: manifest.name,
    );
    return {
      'algorithm': sovereign.algorithm,
      'blobBytes': encryptedSovereign?.length,
      'manifestValid': _validManifest(manifest),
      'manifestVerifyDirect': directVerify,
      'manifestSigBytes': manifest.signature.length,
      'genesisPkBytes': manifest.genesisPubKey.length,
      'controlEntries': control.length,
      'controlStructValid': [for (final e in control) e.isStructurallyValid],
      'controlValidFor': [
        for (final e in control) _validControlFor(manifest, e),
      ],
      'foldRejected': folded.rejected.length,
      'selfMember': folded.state.isMember(_signer.selfId),
    };
  }

  Future<NodeId?> ensureDeviceGroup(SovereignGroupSigner sovereign) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return _mintSovereignDeviceGroup(sovereign, const []);
    final old = await load(NodeId.fromHex(hex));
    if (old == null) return null;
    if (old.manifest.isSovereignDevice) {
      if (_sovereignMatches(old.manifest, sovereign)) {
        return old.manifest.groupId;
      }
      if (!_canUpgradeSovereign(old.manifest, sovereign)) return null;
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return _mintSovereignDeviceGroup(
        sovereign,
        state.members.values.map((m) => m.nodeId),
        migrateFrom: old,
      );
    }
    final state = foldControlLog(
      owner: old.manifest.owner,
      entries: old.control,
      verify: (e) => _validControlFor(old.manifest, e),
      initialName: old.manifest.name,
    ).state;
    return _mintSovereignDeviceGroup(
      sovereign,
      state.members.values.map((m) => m.nodeId),
      migrateFrom: old,
    );
  }

  /// ADOPT [groupId] as my device group — called by the NEW device during the
  /// link handshake (the QR channel carries the id out-of-band). Deliberately
  /// explicit: a device group is NEVER auto-adopted from an inbound snapshot,
  /// or any contact could plant a marker-named group and start receiving this
  /// device's sync events.
  Future<bool> adoptDeviceGroup(NodeId groupId) async {
    final bundle = await load(groupId);
    if (bundle == null ||
        !bundle.manifest.isSovereignDevice ||
        !_validManifest(bundle.manifest)) {
      return false;
    }
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    ).state;
    if (!state.isMember(_signer.selfId)) return false;
    await _storage.putSetting('devices.gid', groupId.hex);
    if (bundle.sovereignBundle != null) {
      await _writeSovereignCredential(bundle.sovereignBundle!);
    }
    _deviceGidCache = groupId.hex;
    _publishDeviceMembersCache(bundle.manifest, state);
    changes.value++;
    // Ingest deliberately kept the snapshot inert before adoption. Replay its
    // validated state now that gid + sovereign genesis + membership are bound.
    for (final message in await messagesOf(groupId)) {
      if (message.author != _signer.selfId) {
        _deviceIncomingCtl.add(message);
      }
    }
    return true;
  }

  Future<bool> _appendSovereignMembership(
    GroupBundle bundle,
    SovereignGroupSigner sovereign,
    ControlOp op,
    NodeId device, {
    bool broadcastSnapshot = true,
  }) async {
    if (!_sovereignMatches(bundle.manifest, sovereign)) return false;
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    ).state;
    if (op == ControlOp.addMember && state.isMember(device)) return true;
    if (op == ControlOp.removeMember && !state.isMember(device)) return true;
    if (device == bundle.manifest.owner) return false;
    final link = _nextControlLink(
      bundle.manifest,
      bundle.control,
      sovereign.nodeId,
    );
    if (link.blocked) return false;
    final unsigned = ControlEntry(
      version: 2,
      groupId: bundle.manifest.groupId,
      author: sovereign.nodeId,
      seq: link.seq,
      prevHash: link.prevHash,
      op: op,
      target: device,
      role: op == ControlOp.addMember ? GroupRole.member : null,
      policyVersion: state.policyVersion,
      createdAtMs: _now(),
      signature: Uint8List(0),
    );
    final signed = unsigned.withSignature(
      sovereign.sign(unsigned.canonicalBytes()),
      Uint8List.fromList(sovereign.publicKey),
    );
    final candidate = [...bundle.control, signed];
    final folded = foldControlLog(
      owner: bundle.manifest.owner,
      entries: candidate,
      verify: (e) => _validControlFor(bundle.manifest, e),
      initialName: bundle.manifest.name,
    );
    if (folded.rejected.any(
      (e) => e.author == signed.author && e.seq == signed.seq,
    )) {
      return false;
    }
    await _save(bundle.copyWith(control: candidate));
    _publishDeviceMembersCache(bundle.manifest, folded.state);
    if (op == ControlOp.addMember && broadcastSnapshot) {
      await broadcast(bundle.manifest.groupId);
    } else if (op == ControlOp.removeMember) {
      await broadcastDelta(bundle.manifest.groupId, control: [signed]);
    }
    return true;
  }

  Future<bool> linkDevice(
    NodeId device, {
    required SovereignGroupSigner sovereign,
    bool broadcastSnapshot = true,
  }) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) {
      return await _mintSovereignDeviceGroup(sovereign, [
            device,
          ], broadcastSnapshot: broadcastSnapshot) !=
          null;
    }
    final bundle = await load(NodeId.fromHex(hex));
    if (bundle == null) return false;
    if (!bundle.manifest.isSovereignDevice) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (e) => _validControlFor(bundle.manifest, e),
        initialName: bundle.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            [...state.members.values.map((m) => m.nodeId), device],
            migrateFrom: bundle,
            broadcastSnapshot: broadcastSnapshot,
          ) !=
          null;
    }
    if (!_sovereignMatches(bundle.manifest, sovereign) &&
        _canUpgradeSovereign(bundle.manifest, sovereign)) {
      final state = foldControlLog(
        owner: bundle.manifest.owner,
        entries: bundle.control,
        verify: (e) => _validControlFor(bundle.manifest, e),
        initialName: bundle.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            [...state.members.values.map((m) => m.nodeId), device],
            migrateFrom: bundle,
            broadcastSnapshot: broadcastSnapshot,
          ) !=
          null;
    }
    return _appendSovereignMembership(
      bundle,
      sovereign,
      ControlOp.addMember,
      device,
      broadcastSnapshot: broadcastSnapshot,
    );
  }

  /// Revoke [device]: removeMember — the fold rotates the epoch, so the
  /// removed device loses the future (already-synced history honestly stays).
  Future<bool> revokeDevice(
    NodeId device, {
    required SovereignGroupSigner sovereign,
  }) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return false;
    final old = await load(NodeId.fromHex(hex));
    if (old == null) return false;
    if (!old.manifest.isSovereignDevice) {
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            state.members.values
                .map((m) => m.nodeId)
                .where((id) => id != device),
            migrateFrom: old,
          ) !=
          null;
    }
    if (!_sovereignMatches(old.manifest, sovereign) &&
        _canUpgradeSovereign(old.manifest, sovereign)) {
      final state = foldControlLog(
        owner: old.manifest.owner,
        entries: old.control,
        verify: (e) => _validControlFor(old.manifest, e),
        initialName: old.manifest.name,
      ).state;
      return await _mintSovereignDeviceGroup(
            sovereign,
            state.members.values
                .map((m) => m.nodeId)
                .where((id) => id != device),
            migrateFrom: old,
          ) !=
          null;
    }
    _invalidateDeviceMembersCache();
    return _appendSovereignMembership(
      old,
      sovereign,
      ControlOp.removeMember,
      device,
    );
  }

  /// Catch-up for the device group (brick 4e): ship my FULL device-group
  /// snapshot to every other device. Deltas posted while every entry node was
  /// down can be lost for good (the join-time full broadcast is the only
  /// recovery today — found live in the 2026-07-11 seed outage), so each
  /// device nudges once per boot; [ingestSnapshot] merges by (author, seq),
  /// so a redundant nudge costs bandwidth, never correctness. Returns how
  /// many devices it was shipped to (0 = no device group / solo install).
  Future<int> nudgeDeviceSync() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return 0;
    return broadcast(NodeId.fromHex(hex));
  }

  /// Whether [peer] is a CURRENT member of my device group — i.e. another of
  /// my own devices. The mirror taps consult this per stored message, so the
  /// folded member set is cached briefly; link/adopt/revoke invalidate it.
  Future<bool> isMyDevice(NodeId peer) async {
    while (true) {
      // A membership mutation may land while load() is awaiting storage. Its
      // generation invalidation must win over that stale read; otherwise the
      // old member set gets re-published for another 30 seconds after revoke.
      final generation = _deviceMembersCacheGeneration;
      final hex = await deviceGroupIdHex();
      if (generation != _deviceMembersCacheGeneration) continue;
      if (hex == null) return false;
      final now = _now();
      final cached = _deviceMembersCache;
      if (cached != null && now - _deviceMembersCacheAtMs <= 30000) {
        return cached.contains(peer.hex);
      }
      final bundle = await load(NodeId.fromHex(hex));
      final state = bundle == null
          ? null
          : foldControlLog(
              owner: bundle.manifest.owner,
              entries: bundle.control,
              verify: (e) => _validControlFor(bundle.manifest, e),
              initialName: bundle.manifest.name,
            ).state;
      final loaded = {
        for (final member in state?.members.values ?? const <GroupMember>[])
          if (member.nodeId != bundle?.manifest.owner) member.nodeId.hex,
      };
      if (generation != _deviceMembersCacheGeneration) continue;
      _deviceMembersCache = loaded;
      _deviceMembersCacheAtMs = now;
      return loaded.contains(peer.hex);
    }
  }

  Set<String>? _deviceMembersCache;
  int _deviceMembersCacheAtMs = 0;
  int _deviceMembersCacheGeneration = 0;

  void _invalidateDeviceMembersCache() {
    _deviceMembersCache = null;
    _deviceMembersCacheGeneration++;
  }

  void _publishDeviceMembersCache(GroupManifest manifest, GroupState state) {
    _deviceMembersCacheGeneration++;
    _deviceMembersCache = {
      for (final member in state.members.values)
        if (member.nodeId != manifest.owner) member.nodeId.hex,
    };
    _deviceMembersCacheAtMs = _now();
  }

  /// Serializes [postDeviceEvent] appends: sync emits are fire-and-forget
  /// (message taps, settings toggles, journal rows), so two can race the
  /// group log's read-modify-write and the later save silently drops the
  /// earlier append. Caught live in the brick-4 device verify (pin landed,
  /// the same-call archive edit vanished from BOTH devices' folds).
  Future<void> _devicePostChain = Future.value();

  /// Append a sync event to my device group's log (no-op false when no
  /// device group exists yet). Concurrent calls are applied in order.
  ///
  /// [attachment] (brick 4b, lazy attachments): a mirrored FILE message posts
  /// its contentId as a real attachment ref, which puts the cid into
  /// [referencedContentIds] — that is what authorizes my other devices'
  /// membership pull of the bytes. The event body stays the JSON codec.
  Future<bool> postDeviceEvent(DeviceSyncEvent e, {MediaObject? attachment}) {
    final done = _devicePostChain.then((_) async {
      final hex = await deviceGroupIdHex();
      if (hex == null) return false;
      return postMessage(
        NodeId.fromHex(hex),
        e.toBody(),
        attachment: attachment,
      );
    });
    _devicePostChain = done.then((_) {}, onError: (_) {});
    return done;
  }

  /// The folded device-sync state: newest event per (kind, key), from the
  /// VALIDATED device-group log. Empty before adoption.
  Future<Map<(DeviceSyncKind, String), DeviceSyncEvent>>
  deviceSyncState() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const {};
    final msgs = await messagesOf(NodeId.fromHex(hex));
    return foldDeviceSync([
      for (final m in msgs) ?DeviceSyncEvent.fromBody(m.body),
    ]);
  }

  /// Every validated device-sync row with its signed message author retained.
  /// Most LWW kinds need only [deviceSyncState]; cloud replica claims must also
  /// prove `claimed device == author`, so discarding the author would turn the
  /// group into a replica-count spoofing oracle.
  Future<List<DeviceSyncRecord>> deviceSyncRecords() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const [];
    final messages = await messagesOf(NodeId.fromHex(hex));
    return [
      for (final message in messages)
        if (DeviceSyncEvent.fromBody(message.body) case final event?)
          (event: event, author: message.author),
    ];
  }

  /// Current non-sovereign members of the device group (including self).
  Future<List<NodeId>> deviceMembers() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const [];
    final bundle = await load(NodeId.fromHex(hex));
    if (bundle == null) return const [];
    final state = foldControlLog(
      owner: bundle.manifest.owner,
      entries: bundle.control,
      verify: (entry) => _validControlFor(bundle.manifest, entry),
    ).state;
    return [
      for (final member in state.members.values)
        if (member.nodeId != bundle.manifest.owner) member.nodeId,
    ];
  }

  /// One-line preview of a validated message for list tiles / notifications.
  static String previewOf(GroupMessage m) {
    if (m.body.isNotEmpty) return m.body;
    switch (m.attachment?.kind) {
      case 'image':
        return '🖼';
      case 'sticker':
        return '😊';
      case 'voice':
        return '🎤';
      case 'vnote':
        return '📹';
    }
    return '…';
  }

  /// Fan the current FULL snapshot of [groupId] out to every OTHER member
  /// (direct delivery, v1). Used to sync a member joining (they need the whole
  /// history). No-op without an injected sender. Returns how many peers it was
  /// shipped to.
  Future<int> broadcast(NodeId groupId) async {
    final send = _send;
    final b = await load(groupId);
    if (b == null) return 0;
    final attempt = Stopwatch()..start();
    if (send == null) {
      if (b.manifest.isSpace) {
        _observeSpace(
          SpaceObservationType.p2pSnapshotDelivery,
          SpaceObservationOutcome.noOp,
          reason: SpaceObservationReason.transportUnavailable,
          duration: attempt.elapsed,
        );
      }
      return 0;
    }
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    var n = 0;
    try {
      for (final m in state.members.values) {
        if (m.nodeId == _signer.selfId ||
            (b.manifest.isSovereignDevice && m.nodeId == b.manifest.owner)) {
          continue;
        }
        final receipt = _beginSpaceReceipt(b, m.nodeId);
        try {
          await send(
            m.nodeId,
            groupId,
            snapshotJson(b, recipient: m.nodeId, receipt: receipt),
          );
        } catch (_) {
          _cancelSpaceReceipt(receipt);
          rethrow;
        }
        n++;
      }
    } catch (_) {
      if (b.manifest.isSpace) {
        _observeSpace(
          SpaceObservationType.p2pSnapshotDelivery,
          SpaceObservationOutcome.failed,
          reason: SpaceObservationReason.transportFailed,
          amount: n,
          duration: attempt.elapsed,
        );
      }
      rethrow;
    }
    if (b.manifest.isSpace) {
      _observeSpace(
        SpaceObservationType.p2pSnapshotDelivery,
        n == 0
            ? SpaceObservationOutcome.noOp
            : SpaceObservationOutcome.succeeded,
        amount: n,
        duration: attempt.elapsed,
      );
    }
    return n;
  }

  /// Fan a DELTA (only the just-added entries). Chat messages and reactions go
  /// to the [kGroupSyncNeighbors] XOR-closest members and are relayed across
  /// that sparse overlay. Control changes and device-group events still reach
  /// every member: roster/key changes carry per-recipient epoch material and
  /// cannot safely depend on a relay that does not own everybody's envelope.
  /// A new member still gets a full [broadcast] on join.
  Future<int> broadcastDelta(
    NodeId groupId, {
    List<ControlEntry> control = const [],
    List<GroupMessage> messages = const [],
    List<GroupReaction> reactions = const [],
    List<SpacePost> posts = const [],
    List<SpacePublicComment> publicComments = const [],
    List<SpacePublicReaction> publicReactions = const [],
    Set<NodeId> exclude = const {},
    String? overlayId,
  }) async {
    final send = _send;
    final b = await load(groupId);
    if (b == null) return 0;
    final attempt = Stopwatch()..start();
    if (send == null) {
      if (b.manifest.isSpace) {
        _observeSpace(
          SpaceObservationType.p2pDeltaDelivery,
          SpaceObservationOutcome.noOp,
          reason: SpaceObservationReason.transportUnavailable,
          duration: attempt.elapsed,
        );
      }
      return 0;
    }
    final state = foldControlLog(
      owner: b.manifest.owner,
      entries: b.control,
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    final channelMessages = messages
        .where((message) => message.isChannelEncrypted)
        .toList();
    final candidates = <NodeId>[
      for (final member in state.members.values)
        if (member.nodeId != _signer.selfId &&
            (!b.manifest.isSovereignDevice ||
                member.nodeId != b.manifest.owner) &&
            (channelMessages.isEmpty ||
                channelMessages.any(
                  (message) => _peerCanDecryptChannelEpoch(
                    b,
                    member.nodeId,
                    message.channelId!,
                    message.channelEpoch!,
                  ),
                )))
          member.nodeId,
    ];
    final sparse = control.isEmpty && b.manifest.name != kDeviceGroupName;
    final neighborCount = sparse
        ? await groupSyncNeighborCount(groupId)
        : kGroupSyncNeighbors;
    final peers = sparse
        ? nearestGroupNodesByXor(_signer.selfId, candidates, k: neighborCount)
        : candidates;
    final deltaId = sparse
        ? (overlayId ??
              _overlayDeltaId(
                groupId,
                messages,
                reactions,
                posts,
                publicComments,
                publicReactions,
              ))
        : null;
    if (deltaId != null) _rememberOverlayDelta(deltaId);
    var n = 0;
    try {
      for (final peer in peers) {
        if (exclude.contains(peer)) continue;
        final epochEnvelopes = _epochEnvelopesFor(b, peer, controls: control);
        final channelEpochEnvelopes = _channelEpochEnvelopesFor(
          b,
          peer,
          controls: control,
        );
        final encryptionEstablished = _encryptionEstablished(
          b.manifest,
          b.control,
        );
        final peerMessages = [
          for (final message in messages)
            if (_messageWithinLifecycleBoundary(b.manifest, state, message) &&
                (message.isChannelEncrypted
                    ? _peerCanDecryptChannelEpoch(
                        b,
                        peer,
                        message.channelId!,
                        message.channelEpoch!,
                      )
                    : !encryptionEstablished ||
                          (message.isEncrypted &&
                              _peerCanDecryptEpoch(
                                b,
                                peer,
                                message.membershipEpoch!,
                              ))))
              message,
        ];
        final peerReactions = [
          for (final reaction in reactions)
            if (_reactionWithinLifecycleBoundary(state, reaction) &&
                (reaction.isChannelEncrypted
                    ? _peerCanDecryptChannelEpoch(
                        b,
                        peer,
                        reaction.channelId!,
                        reaction.channelEpoch!,
                      )
                    : !encryptionEstablished ||
                          (reaction.isMembershipEncrypted &&
                              _peerCanDecryptEpoch(
                                b,
                                peer,
                                reaction.membershipEpoch!,
                              ))))
              reaction,
        ];
        final peerPosts = [
          for (final post in posts)
            if (_postWithinLifecycleBoundary(state, post) &&
                (!post.isEncrypted ||
                    _peerCanDecryptEpoch(b, peer, post.membershipEpoch!)))
              post,
        ];
        final receipt = _beginSpaceReceipt(b, peer);
        try {
          await send(
            peer,
            groupId,
            jsonEncode({
              'm': b.manifest.toJson(),
              'c': control.map((entry) => entry.toJson()).toList(),
              'g': peerMessages.map((message) => message.toJson()).toList(),
              'r': peerReactions.map((reaction) => reaction.toJson()).toList(),
              if (peerPosts.isNotEmpty)
                'p': peerPosts.map((post) => post.toJson()).toList(),
              if (publicComments.isNotEmpty)
                'pc': publicComments
                    .where(
                      (comment) =>
                          _validPublicCommentFor(groupId, comment) &&
                          comment.lifecycleGeneration ==
                              (state.lifecycleTransitionHash ??
                                  _legacyPostGeneration(groupId)),
                    )
                    .map((comment) => comment.toJson())
                    .toList(),
              if (publicReactions.isNotEmpty)
                'pr': publicReactions
                    .where(
                      (reaction) =>
                          _validPublicReactionFor(groupId, reaction) &&
                          reaction.lifecycleGeneration ==
                              (state.lifecycleTransitionHash ??
                                  _legacyPostGeneration(groupId)),
                    )
                    .map((reaction) => reaction.toJson())
                    .toList(),
              if (epochEnvelopes.isNotEmpty)
                'ke': epochEnvelopes.map((entry) => entry.toJson()).toList(),
              if (channelEpochEnvelopes.isNotEmpty)
                'cke': channelEpochEnvelopes
                    .map((entry) => entry.toJson())
                    .toList(),
              'ov': ?deltaId,
              'rcpt': ?receipt,
            }),
          );
        } catch (_) {
          _cancelSpaceReceipt(receipt);
          rethrow;
        }
        n++;
      }
    } catch (_) {
      if (b.manifest.isSpace) {
        _observeSpace(
          SpaceObservationType.p2pDeltaDelivery,
          SpaceObservationOutcome.failed,
          reason: SpaceObservationReason.transportFailed,
          amount: n,
          duration: attempt.elapsed,
        );
      }
      rethrow;
    }
    if (b.manifest.isSpace) {
      _observeSpace(
        SpaceObservationType.p2pDeltaDelivery,
        n == 0
            ? SpaceObservationOutcome.noOp
            : SpaceObservationOutcome.succeeded,
        amount: n,
        duration: attempt.elapsed,
      );
    }
    return n;
  }

  String _overlayDeltaId(
    NodeId groupId,
    Iterable<GroupMessage> messages,
    Iterable<GroupReaction> reactions, [
    Iterable<SpacePost> posts = const [],
    Iterable<SpacePublicComment> publicComments = const [],
    Iterable<SpacePublicReaction> publicReactions = const [],
  ]) {
    final identities = <String>[
      for (final message in messages) 'm:${message.author.hex}:${message.seq}',
      for (final reaction in reactions)
        'r:${reaction.author.hex}:${reaction.seq}',
      for (final post in posts) 'p:${post.author.hex}:${post.seq}',
      for (final comment in publicComments) 'pc:${comment.recordHash}',
      for (final reaction in publicReactions) 'pr:${reaction.recordHash}',
    ]..sort();
    return crypto.sha256
        .convert(utf8.encode('${groupId.hex}|${identities.join('|')}'))
        .toString();
  }

  bool _rememberOverlayDelta(String id) {
    if (!_seenOverlayDeltas.add(id)) return false;
    if (_seenOverlayDeltas.length > _kSeenOverlayDeltaLimit) {
      _seenOverlayDeltas.remove(_seenOverlayDeltas.first);
    }
    return true;
  }

  /// Releases the pure-Dart event surfaces owned by this identity instance.
  /// Hosts must call this before replacing/closing the active identity so a
  /// stale group feed cannot survive an identity switch.
  Future<void> dispose() async {
    _disposed = true;
    _spaceDeletionMaintenanceTimer?.cancel();
    _spaceDeletionMaintenanceTimer = null;
    _scheduledSpacePostTimer?.cancel();
    _scheduledSpacePostTimer = null;
    _spaceDiscoveryPublishTimer?.cancel();
    _spaceDiscoveryPublishTimer = null;
    _spaceDiscoveryNudgeTimer?.cancel();
    _spaceDiscoveryNudgeTimer = null;
    if (_spaceDiscoveryChangesBound) {
      changes.removeListener(_nudgePublicSpaceDiscovery);
      _spaceDiscoveryChangesBound = false;
    }
    _publishedPublicSpaceDescriptors.clear();
    _verifiedPublicSpaceFeeds.clear();
    _publicSubscriptionSnapshots.clear();
    for (final pending in _pendingPublicFeedObjects.values) {
      if (!pending.completer.isCompleted) pending.completer.complete(null);
    }
    _pendingPublicFeedObjects.clear();
    _publicFeedServeQuotas.clear();
    _publicMediaServeQuotas.clear();
    _seenPublicMediaRequests.clear();
    for (final pending in _pendingSpaceReceipts.values) {
      pending.elapsed.stop();
    }
    for (final pending in _pendingContentReceipts.values) {
      pending.elapsed.stop();
    }
    _pendingSpaceReceipts.clear();
    _stalledSpaceReceipts.clear();
    _spaceHolderProofs.clear();
    _pendingContentReceipts.clear();
    _outboundContentRequests.clear();
    _contentHolderProofs.clear();
    changes.dispose();
    feedAccessChanges.dispose();
    await _groupCallIncomingCtl.close();
    await _deviceIncomingCtl.close();
    await _incomingCtl.close();
    await _incomingCommentCtl.close();
    await _incomingPostCtl.close();
    await _incomingPublicPostCtl.close();
    await _incomingPublicCommentCtl.close();
  }
}

class SpaceFeedItem {
  const SpaceFeedItem({
    required this.spaceId,
    required this.spaceName,
    required this.post,
    required this.reactions,
    required this.canDeletePost,
    required this.canModeratePost,
    required this.canManagePosts,
    this.publicOnly = false,
  });

  final NodeId spaceId;
  final String spaceName;
  final SpacePostView post;
  final MessageReactions reactions;
  final bool canDeletePost;
  final bool canModeratePost;
  final bool canManagePosts;
  final bool publicOnly;
}

/// One row of the user-facing group list (the shape [GroupService.listGroups]
/// returns) — named so the chats screen and providers can share it.
typedef GroupListEntry = ({
  NodeId groupId,
  String name,
  String description,
  SpaceVisibility? visibility,
  SpaceLifecycleState lifecycleState,
  bool discoverable,
  int unread,
  int postUnread,
  bool muted,
  NotificationMuteMode notificationMode,
  DateTime? notificationUntil,
  String preview,
  int lastTs,
});
