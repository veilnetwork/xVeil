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
import '../domain/cloud.dart'
    show CloudItem, answerableCloudContentIds, unresolvedCloudNoteRevisions;
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
import '../domain/space_action_log.dart';
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
part 'group_service_channel_keys.dart';
part 'group_service_channel_queries.dart';
part 'group_service_compaction.dart';
part 'group_service_protected_channels.dart';
part 'group_service_reactions.dart';
part 'group_service_public_feed_transport.dart';
part 'group_service_public_subscriptions.dart';
part 'group_service_space_feed.dart';
part 'group_service_abuse_reports.dart';
part 'group_service_recommendations.dart';
part 'group_service_moderation_appeals.dart';
part 'group_service_invites.dart';
part 'group_service_joins.dart';

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
    this.messageReceipts = const {},
    this.postReceipts = const {},
    this.channelEpochReceipts = const {},
    this.controlReceipts = const {},
  });
  final SpaceManifest manifest;
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

  /// `groupMessageReceiptKey(m)` -> the local moment that exact row was first
  /// accepted here. Local fold state like [retentionCuts]: never signed, never
  /// put in a snapshot, and deliberately NOT a field of [GroupMessage] — a
  /// receiver-chosen number that travelled on the wire would just be the same
  /// unauthenticated stamp under a second name.
  ///
  /// Written only for rows whose signed `ts` this device could not believe
  /// when they arrived (see [groupMessageOrderAt]), so it is empty for every
  /// group that has never been handed one, and the read path skips it whole.
  final Map<String, int> messageReceipts;

  /// `spacePostReceiptKey(root)` -> the local moment that exact publication
  /// was first accepted here. The same local fold state as [messageReceipts]
  /// and for the same reason, on the other signed object: `'published'` is
  /// inside [SpacePost.canonicalBytes], so the stamp a Feed ranks, pages and
  /// counts unread on cannot be rewritten, only bounded beside.
  ///
  /// Written only for publication roots whose stamp this device could not
  /// believe on arrival (see [spacePostOrderAt]), so it is empty for every
  /// honest Space and [_postsOfBundle] then skips the whole pass.
  final Map<String, int> postReceipts;

  /// `_channelKeyId(channelId, epoch)` -> the local moment this device first
  /// observed that epoch serving as the channel's current key. The same local
  /// fold state as [messageReceipts], written and read only by
  /// [GroupService.rotateStaleChannelKeys].
  ///
  /// Age-based key rotation cannot ask the control entry that introduced the
  /// epoch when it was introduced, because that `createdAtMs` is a number the
  /// entry's author chose and this one is worse than a ranking input: a stamp
  /// in the FUTURE makes `now - started` negative, so the key never grows old
  /// and never rotates — the only place in this series where a lie makes a
  /// protection quietly stop instead of making something visibly fail. A stamp
  /// in the far PAST is the mirror: the key is born stale and every maintenance
  /// pass rekeys the whole channel again.
  ///
  /// So the age is measured from a number nobody else can write. Unlike
  /// [messageReceipts] this map has an entry for EVERY protected-channel epoch
  /// this device has swept, not only a suspicious one: there is no honest
  /// reading of the claimed stamp to fall back to, in either direction, so it
  /// is not consulted at all.
  final Map<String, int> channelEpochReceipts;

  /// `'<author hex>:<seq>'` -> the local moment this device first held that
  /// control row. The same local fold state as [messageReceipts]: never
  /// signed, never in a snapshot, and deliberately NOT a field of
  /// [ControlEntry] — a stamp a peer could set would be the same
  /// unauthenticated claim under a second name.
  ///
  /// A control row's `createdAtMs` is a number its author chose, and
  /// `compareHeads` merges rows from DIFFERENT authors by it. That is the
  /// control log's ordering rule and it stays: an arrival moment differs on
  /// every device, so it can be a floor ("no earlier than") but never a
  /// ranking key — ranking by it would give two devices two different logs.
  ///
  /// The floor exists so a decision this device makes about WHEN something
  /// happened cannot be moved by the author of the thing. Read only by such
  /// local decisions and by nothing inside [foldControlLog], which is what
  /// keeps the fold a pure function of signed bytes and therefore keeps two
  /// devices with two different sets of these moments on one state.
  ///
  /// Keyed by `(author, seq)` rather than by row hash so recording costs no
  /// hashing on a path that runs on every save. Two distinct rows for one
  /// `(author, seq)` is equivocation, which the fold already rejects whole,
  /// so the shared key can never decide anything.
  ///
  /// Rows already present the first time this device records for a Space are
  /// stored as `0` — no floor. A device that joined last week knows nothing
  /// about when a two-year-old row arrived, and inventing "now" for all of
  /// history would make the very first revocation withdraw a moderator's
  /// entire past. Same honesty as [channelEpochReceipts]: a device with no
  /// arrival moment of its own does not get to pretend it has one.
  final Map<String, int> controlReceipts;

  /// The earliest moment this device is willing to believe [entry] existed:
  /// its own claim, floored by when we first held it.
  ///
  /// Lying forward is not bounded here — that is [compareHeads]' problem and
  /// it is answered by the revocation itself, since a row dated into next year
  /// is trivially after any boundary an owner would pick.
  int effectiveControlTimeMs(ControlEntry entry) {
    final seen = controlReceipts[controlReceiptKey(entry)] ?? 0;
    return entry.createdAtMs > seen ? entry.createdAtMs : seen;
  }

  GroupBundle copyWith({
    SpaceManifest? manifest,
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
    Map<String, int>? messageReceipts,
    Map<String, int>? postReceipts,
    Map<String, int>? channelEpochReceipts,
    Map<String, int>? controlReceipts,
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
    messageReceipts: messageReceipts ?? this.messageReceipts,
    postReceipts: postReceipts ?? this.postReceipts,
    channelEpochReceipts: channelEpochReceipts ?? this.channelEpochReceipts,
    controlReceipts: controlReceipts ?? this.controlReceipts,
  );
}

/// Key of [GroupBundle.controlReceipts] for one control row.
String controlReceiptKey(ControlEntry entry) =>
    '${entry.author.hex}:${entry.seq}';

/// Identity of one signed row inside [GroupBundle.messageReceipts].
///
/// `(author, seq)` alone would be enough for an honest log, but two rows may
/// legitimately share it as fork evidence; including the claimed stamp keeps a
/// bound recorded for one of them from silently moving the other, and makes the
/// entry self-describing enough to be ignored if the row it names is gone.
String groupMessageReceiptKey(GroupMessage message) =>
    '${message.author.hex}:${message.seq}:${message.createdAtMs}';

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
    final manifest = SpaceManifest.fromJson(wire['m']);
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

  static const String _scheduledSpacePostIndexSetting =
      'space.scheduled-posts.index.v1';
  static const int _maxScheduledSpacePosts = 128;
  Future<void> _spacePostDraftMutationTail = Future<void>.value();
  Future<void> _scheduledSpacePostMutationTail = Future<void>.value();

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

  late final _SpaceJoins _spaceJoins = _SpaceJoins(this);

  /// Create or reuse a capability-bound join link for one active public Space.
  /// Only an actor who can currently add a member may issue it. The link itself
  /// grants no data and is useless after the local ticket is revoked/expired.
  Future<String?> createSpaceJoinCode(NodeId spaceId) =>
      _spaceJoins.createSpaceJoinCode(spaceId);

  Future<bool> revokeSpaceJoinCode(NodeId spaceId) =>
      _spaceJoins.revokeSpaceJoinCode(spaceId);

  Future<String?> currentSpaceJoinCode(NodeId spaceId) =>
      _spaceJoins.currentSpaceJoinCode(spaceId);

  /// Send a requester-authenticated intent using a published join code.
  Future<bool> requestToJoinSpace(String code) =>
      _spaceJoins.requestToJoinSpace(code);

  Future<List<SpaceJoinOutboxEntry>> outgoingSpaceJoinRequests() =>
      _spaceJoins.outgoingSpaceJoinRequests();

  Future<bool> dismissSpaceJoinRequest(String requestId) =>
      _spaceJoins.dismissSpaceJoinRequest(requestId);

  /// Validate and durably persist one capability-bound join request.
  Future<bool> receiveSpaceJoinRequest(NodeId peer, String requestJson) =>
      _spaceJoins.receiveSpaceJoinRequest(peer, requestJson);

  Future<List<SpaceJoinInboxEntry>> pendingSpaceJoinRequests(NodeId spaceId) =>
      _spaceJoins.pendingSpaceJoinRequests(spaceId);

  Future<bool> decideSpaceJoinRequest(
    String requestId, {
    required bool accept,
  }) => _spaceJoins.decideSpaceJoinRequest(requestId, accept: accept);

  Future<bool> receiveSpaceJoinDecision(NodeId peer, String decisionJson) =>
      _spaceJoins.receiveSpaceJoinDecision(peer, decisionJson);

  late final _SpaceInvites _spaceInvites = _SpaceInvites(this);

  String _newSpaceInviteId() {
    final random = Random.secure();
    return List<int>.generate(
      32,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<bool> inviteToSpace(
    NodeId spaceId,
    NodeId invitee, {
    GroupRole role = GroupRole.member,
  }) => _spaceInvites.inviteToSpace(spaceId, invitee, role: role);

  Future<bool> receiveSpaceInvite(NodeId peer, String inviteJson) =>
      _spaceInvites.receiveSpaceInvite(peer, inviteJson);

  Future<List<PendingSpaceInvite>> pendingSpaceInvites() =>
      _spaceInvites.pendingSpaceInvites();

  Future<bool> decideSpaceInvite(String inviteId, {required bool accept}) =>
      _spaceInvites.decideSpaceInvite(inviteId, accept: accept);

  Future<bool> receiveSpaceInviteDecision(NodeId peer, String decisionJson) =>
      _spaceInvites.receiveSpaceInviteDecision(peer, decisionJson);

  /// Fold one stamp a STRANGER chose into a "last updated" number this device
  /// is about to sign and publish as its own.
  ///
  /// Every input here — a member's post row, public comment or public reaction,
  /// and the control entries folded in [buildSpacePublicDiscoveryPublication] —
  /// carries a `created` its author picked, and no signature over it says the
  /// clock behind it was honest. That number used to be taken raw, and it ends
  /// up in `issuedAt`, which the wire format requires to be within
  /// [kSpacePublicClockSkew] of now, and in `expiresAt`, which must be greater
  /// than it. So ONE member stamping ONE row into 2027 did not merely rank
  /// itself wrong — it made the OWNER's `buildSpacePublicDiscoveryPublication`
  /// return null and took the whole Space off public discovery, for everyone,
  /// until the year arrived. A member denying service to the owner.
  ///
  /// EXCLUDED, not clamped to now, and the difference matters twice. The owner
  /// descriptor is deliberately stable across periodic DHT refreshes so
  /// independent holders can attest the same hash; a value clamped to a live
  /// clock would move on every rebuild, and one hostile row would keep the
  /// descriptor hash churning forever — the same denial in a quieter form.
  /// And "the newest thing here a clock could have produced" is simply the
  /// honest answer to what this field asks, where "now, because someone lied"
  /// is not.
  ///
  /// Excluding costs the author nothing it could want: the row is still
  /// published in full, still hashed into its page, still counted by `revision`
  /// and `publicPostCount`, and still ordered by [spacePostOrderAt] at every
  /// reader. Only its claim to be the Space's freshest metadata is dropped, so
  /// there is nothing here for a member to opt out OF.
  ///
  /// One-sided and on the existing tolerance, like the rest of this series: a
  /// stamp in the past is honoured as written, and the bound is
  /// [spacePostOrderAt]'s own — the same rule, the same five minutes, no fifth
  /// constant.
  int _foldPublicUpdatedAt(int latest, int claimedMs, int nowMs) =>
      claimedMs > latest && spacePostOrderAt(claimedMs, nowMs) == claimedMs
      ? claimedMs
      : latest;

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

    final nowMs = _now();
    var updatedAtMs = bundle.manifest.createdAtMs;
    final retainedPublicRows = [
      for (final post in _retainedPostRows(
        bundle.manifest.groupId,
        bundle.posts,
      ))
        if (post.visibility == SpacePostVisibility.public) post,
    ];
    for (final post in retainedPublicRows) {
      updatedAtMs = _foldPublicUpdatedAt(updatedAtMs, post.createdAtMs, nowMs);
    }
    for (final comment in publicComments) {
      updatedAtMs = _foldPublicUpdatedAt(
        updatedAtMs,
        comment.createdAtMs,
        nowMs,
      );
    }
    for (final reaction in publicReactions) {
      updatedAtMs = _foldPublicUpdatedAt(
        updatedAtMs,
        reaction.createdAtMs,
        nowMs,
      );
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
    // A member writes its OWN control entries — `leave` needs no permission at
    // all, `acceptRules` none either — so `created` here is a stranger's number
    // exactly like a post's. See [_foldPublicUpdatedAt]: a row a clock could
    // not have produced does not get to be this Space's "last updated".
    final updatedAt = folded.accepted.fold<int>(
      bundle.manifest.createdAtMs,
      (latest, entry) =>
          _foldPublicUpdatedAt(latest, entry.createdAtMs, wallNow),
    );
    // What is left of this gate is the GENESIS stamp above, which the fold
    // seeds and cannot drop: the wire format ties the descriptor's `created`
    // to it (`createdAtMs != genesisManifest.createdAtMs` is refused, as is
    // `updatedAtMs < createdAtMs`), so a Space whose creator dated it into the
    // future has no valid public descriptor at all and refusing is the only
    // honest answer. Nobody else's number can reach this line any more.
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

  late final _PublicFeedTransport _publicFeedTransport = _PublicFeedTransport(
    this,
  );

  /// Holder-side live-only object service. Invalid, uncommitted or over-quota
  /// requests are silent so the path exposes neither membership nor cache
  /// state beyond the descriptor the requester already resolved from DHT.
  Future<void> handlePublicFeedObjectRequest(NodeId peer, String requestJson) =>
      _publicFeedTransport.handlePublicFeedObjectRequest(peer, requestJson);

  /// Holder-side public media gate. This never treats the requester as a
  /// member: the only authority is an exact, still-live verified public
  /// descriptor/feed package that names [SpacePublicMediaGrantRequest.contentId].
  /// Invalid, replayed, unreferenced and unavailable requests are all silent.
  Future<void> handlePublicMediaGrantRequest(NodeId peer, String requestJson) =>
      _publicFeedTransport.handlePublicMediaGrantRequest(peer, requestJson);

  /// Requester-side bounded reassembly. Unsolicited chunks and chunks from a
  /// different authenticated holder never allocate a slot.
  void handlePublicFeedObjectChunk(NodeId peer, String chunkJson) =>
      _publicFeedTransport.handlePublicFeedObjectChunk(peer, chunkJson);

  /// Request one verified public media object without materializing a fake
  /// membership. The caller must already have fetched and verified this exact
  /// descriptor/feed pair. Every selected holder independently repeats that
  /// reference check before opening its stream gate.
  Future<bool> requestPublicSpaceMedia(
    SpacePublicDescriptor descriptor,
    Iterable<SpacePublicHolderAnnouncement> holders,
    String contentId,
  ) => _publicFeedTransport.requestPublicSpaceMedia(
    descriptor,
    holders,
    contentId,
  );

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
      final manifestBytes = await _publicFeedTransport._requestPublicFeedObject(
        holder: holder.holder,
        descriptor: descriptor,
        objectHash: descriptor.publicFeedManifestHash,
        timeout: objectTimeout,
      );
      final manifest = manifestBytes == null
          ? null
          : SpacePublicFeedManifest.fromJson(
              _publicFeedTransport._decodePublicFeedObjectJson(manifestBytes),
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
            _publicFeedTransport._requestPublicFeedObject(
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
            _publicFeedTransport._requestPublicFeedObject(
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

  late final _Recommendations _recommendations = _Recommendations(this);

  /// Create a signed, public recommendation campaign. The capability is
  /// issued by an admin, while any current member with distribute permission
  /// may later carry the resulting card to explicitly selected contacts.
  Future<SpaceRecommendationCampaign?> createSpaceRecommendationCampaign(
    NodeId spaceId,
    String text,
  ) => _recommendations.createSpaceRecommendationCampaign(spaceId, text);

  Future<SpaceRecommendationPolicy?> setSpaceRecommendationPolicy(
    NodeId spaceId, {
    required int expectedRevision,
    required bool enabled,
  }) => _recommendations.setSpaceRecommendationPolicy(
    spaceId,
    expectedRevision: expectedRevision,
    enabled: enabled,
  );

  Future<List<SpaceRecommendationCampaign>> spaceRecommendationCampaigns(
    NodeId spaceId, {
    bool includeRevoked = false,
  }) => _recommendations.spaceRecommendationCampaigns(
    spaceId,
    includeRevoked: includeRevoked,
  );

  Future<bool> revokeSpaceRecommendationCampaign(
    NodeId spaceId,
    String campaignId,
  ) => _recommendations.revokeSpaceRecommendationCampaign(spaceId, campaignId);

  Future<List<SpaceRecommendationShareAudit>> spaceRecommendationShareAudit({
    NodeId? spaceId,
  }) => _recommendations.spaceRecommendationShareAudit(spaceId: spaceId);

  Future<SpaceRecommendationShareResult> shareSpaceRecommendation(
    NodeId spaceId,
    String campaignId,
    NodeId recipient,
  ) =>
      _recommendations.shareSpaceRecommendation(spaceId, campaignId, recipient);

  Future<SpaceRecommendationRevokeResult> revokeSentSpaceRecommendation(
    String auditId,
  ) => _recommendations.revokeSentSpaceRecommendation(auditId);

  Future<bool> acceptsSpaceRecommendationCard(
    NodeId sender,
    SpaceRecommendationCard card,
  ) => _recommendations.acceptsSpaceRecommendationCard(sender, card);

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

  late final _ModerationAppeals _moderationAppeals = _ModerationAppeals(this);

  Future<Map<String, String>> moderationAppealSpaceNames() =>
      _moderationAppeals.moderationAppealSpaceNames();

  /// Returns self-targeted actions even when the Space itself is hidden after
  /// a ban. Already appealed actions live in [outgoingSpaceModerationAppeals].
  Future<List<SpaceModerationAppealCandidate>>
  appealableSpaceModerationActions() =>
      _moderationAppeals.appealableSpaceModerationActions();

  Future<List<SpaceModerationAppealOutboxEntry>>
  outgoingSpaceModerationAppeals() =>
      _moderationAppeals.outgoingSpaceModerationAppeals();

  Future<List<SpaceModerationAppealInboxEntry>> incomingSpaceModerationAppeals({
    NodeId? spaceId,
    bool pendingOnly = false,
  }) => _moderationAppeals.incomingSpaceModerationAppeals(
    spaceId: spaceId,
    pendingOnly: pendingOnly,
  );

  Future<bool> appealSpaceModeration(
    NodeId spaceId,
    String actionId, {
    required String text,
  }) => _moderationAppeals.appealSpaceModeration(spaceId, actionId, text: text);

  Future<bool> receiveSpaceModerationAppeal(NodeId peer, String appealJson) =>
      _moderationAppeals.receiveSpaceModerationAppeal(peer, appealJson);

  Future<bool> decideSpaceModerationAppeal(
    String appealId, {
    required SpaceModerationAppealOutcome outcome,
    required String reason,
  }) => _moderationAppeals.decideSpaceModerationAppeal(
    appealId,
    outcome: outcome,
    reason: reason,
  );

  Future<bool> receiveSpaceModerationAppealDecision(
    NodeId peer,
    String decisionJson,
  ) => _moderationAppeals.receiveSpaceModerationAppealDecision(
    peer,
    decisionJson,
  );

  late final _AbuseReports _abuseReports = _AbuseReports(this);

  Future<List<SpaceAbuseReportInboxEntry>> incomingSpaceAbuseReports({
    NodeId? spaceId,
    bool pendingOnly = false,
  }) => _abuseReports.incomingSpaceAbuseReports(
    spaceId: spaceId,
    pendingOnly: pendingOnly,
  );

  Future<List<SpaceAbuseReportOutboxEntry>> outgoingSpaceAbuseReports() =>
      _abuseReports.outgoingSpaceAbuseReports();

  Future<bool> reportSpaceContent(
    NodeId spaceId,
    String postId, {
    String? commentRef,
    required SpaceAbuseCategory category,
    String details = '',
  }) => _abuseReports.reportSpaceContent(
    spaceId,
    postId,
    commentRef: commentRef,
    category: category,
    details: details,
  );

  Future<bool> receiveSpaceAbuseReport(NodeId peer, String reportJson) =>
      _abuseReports.receiveSpaceAbuseReport(peer, reportJson);

  Future<bool> decideSpaceAbuseReport(
    String reportId, {
    required SpaceAbuseReportOutcome outcome,
    required String reason,
  }) => _abuseReports.decideSpaceAbuseReport(
    reportId,
    outcome: outcome,
    reason: reason,
  );

  Future<bool> receiveSpaceAbuseReportDecision(
    NodeId peer,
    String decisionJson,
  ) => _abuseReports.receiveSpaceAbuseReportDecision(peer, decisionJson);

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

  /// The wall clock as a plain reading, WITHOUT advancing the monotonic
  /// mutation counter [_now] maintains.
  ///
  /// For predicates that only ask what time it is. Taking [_now] for those
  /// would shift every stamp written afterwards by one per read, which makes
  /// the order of this device's own writes depend on how many questions were
  /// asked along the way.
  int _clockNowMs() =>
      debugWallClockMs?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// Test seam: retention expiry spans days, so deterministic tests drive the
  /// wall clock instead of waiting it out. Never set in production code.
  int Function()? debugWallClockMs;

  bool _validManifest(SpaceManifest manifest) {
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
    SpaceManifest manifest,
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
  SpaceManifest? _mergeManifest(
    SpaceManifest existing,
    SpaceManifest incoming,
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

  bool _validControlFor(SpaceManifest manifest, ControlEntry e) {
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
          ? kGroupCallProtocolVersion
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
            if (signal.protocolVersion != kGroupCallProtocolVersion) {
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
            signal.protocolVersion != kGroupCallProtocolVersion) {
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
    List<ControlEntry> control,
    SpaceControlFrontier frontier,
  ) {
    if (!frontier.isStructurallyValid) return null;
    return _foldAtControlHeads(manifest, control, frontier.heads);
  }

  GroupFoldResult? _foldAtControlCheckpoint(
    SpaceManifest manifest,
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
    SpaceManifest manifest,
    List<ControlEntry> control,
    NodeId author,
  ) {
    // Accepted rows PLUS the ones a signed boundary withdrew. A withdrawn row
    // is a real row at a real position that this author's later rows bind by
    // hash: continuing from the last SURVIVING row instead would re-use a seq
    // and fork the chain, and the fold would then refuse everything the author
    // ever writes again — which would make returning their authority a promise
    // this log could not keep.
    final folded = foldControlLog(
      owner: manifest.owner,
      entries: control,
      verify: (entry) => _validControlFor(manifest, entry),
      initialName: manifest.name,
    );
    final authored =
        [
            ...folded.accepted,
            ...folded.withdrawn,
          ].where((entry) => entry.author == author).toList()
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
    List<ControlEntry> control,
  ) => _acceptedControl(
    manifest,
    control,
  ).any((entry) => entry.epochDescriptor != null);

  bool _validLocalEpochKey(
    SpaceManifest manifest,
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
    final nowMs = _clockNowMs();

    for (var index = 0; index < accepted.length; index++) {
      final entry = accepted[index];
      if (entry.op != ControlOp.setRetention) continue;
      // Before the monotone clamp, so an unbelievable stamp cannot raise the
      // floor under the honest revisions that follow it — including the one
      // that would put the policy back.
      if (!spaceRetentionRevisionBelievable(entry.createdAtMs, nowMs)) continue;
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
    final nowMs = _clockNowMs();
    for (final entry in _acceptedControl(bundle.manifest, bundle.control)) {
      if (entry.op != ControlOp.setRetention) continue;
      // Same bound, same reason, on the synchronous subset.
      if (!spaceRetentionRevisionBelievable(entry.createdAtMs, nowMs)) continue;
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
    required SpaceManifest manifest,
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
    required SpaceManifest manifest,
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
    required SpaceManifest manifest,
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
    required SpaceManifest manifest,
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
    required SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    required SpaceManifest manifest,
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

  /// Compact only logs whose old entries are superseded state, and rotate a
  /// bounded budget of groups per pass. Both live in
  /// `group_service_compaction.dart`; the lock and the API stay here.
  Future<GroupLogCompaction?> compactStateLogs(NodeId groupId) =>
      _serialized(groupId, () => _compaction.compactLocked(groupId));

  Future<int> sweepStateLogCompaction({int limit = 8}) =>
      _compaction.sweep(limit: limit);

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
        () =>
            'xVeil[group]: index repaired — removed ${ghosts.length} '
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
  void _loadRefused(NodeId groupId, String why) =>
      devLog(() => 'xVeil[group]: load ${groupId.short} refused — $why');

  Future<GroupBundle?> load(NodeId groupId) async {
    final raw = await _loadBundleRaw(groupId);
    if (raw == null) {
      _loadRefused(groupId, 'no bundle in the file store nor the legacy key');
      return null;
    }
    try {
      final d = jsonDecode(raw) as Map<String, dynamic>;
      final manifest = SpaceManifest.fromJson(d['m']);
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
      // An entry exists only for a row this device accepted and stored, so the
      // map is bounded by the rows a peer stamped into the future — empty in
      // every honest log. Entries whose row is later swept by retention are
      // left behind on purpose: they match nothing and cost bytes, and no test
      // this project can write at a proportionate cost would cover pruning
      // them, so the branch that would do it is not here to rot.
      final messageReceipts = <String, int>{};
      final rawReceipts = d['mrx'];
      if (rawReceipts is Map) {
        for (final entry in rawReceipts.entries) {
          final at = entry.value;
          if (at is int && at >= 0) messageReceipts['${entry.key}'] = at;
        }
      }
      // Same shape, same reasoning, on the publication side.
      final postReceipts = <String, int>{};
      final rawPostReceipts = d['prx'];
      if (rawPostReceipts is Map) {
        for (final entry in rawPostReceipts.entries) {
          final at = entry.value;
          if (at is int && at >= 0) postReceipts['${entry.key}'] = at;
        }
      }
      // And on the protected-channel key side. This one is bounded by the
      // number of channel epochs this device has swept rather than by hostile
      // rows, because the age of a key has no honest claimed source at all.
      final channelEpochReceipts = <String, int>{};
      final rawChannelReceipts = d['cex'];
      if (rawChannelReceipts is Map) {
        for (final entry in rawChannelReceipts.entries) {
          final at = entry.value;
          if (at is int && at >= 0) channelEpochReceipts['${entry.key}'] = at;
        }
      }
      // And on the control-row side. Bounded by the log itself: [_save]
      // rebuilds it from `b.control` every write, so a row swept by a
      // checkpoint takes its arrival moment with it.
      final controlReceipts = <String, int>{};
      final rawControlReceipts = d['crx'];
      if (rawControlReceipts is Map) {
        for (final entry in rawControlReceipts.entries) {
          final at = entry.value;
          if (at is int && at >= 0) controlReceipts['${entry.key}'] = at;
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
        messageReceipts: messageReceipts,
        postReceipts: postReceipts,
        channelEpochReceipts: channelEpochReceipts,
        controlReceipts: controlReceipts,
      );
    } catch (error) {
      // A throw here is indistinguishable from "no such group" to every
      // caller, so it must not be silent: a transient store read is the one
      // failure that looks like a deleted group and heals by itself.
      _loadRefused(groupId, 'threw while decoding: $error');
      return null;
    }
  }

  /// Arrival moments for [b]'s control rows: every moment already recorded is
  /// kept exactly as it was, every row this device has not seen before is
  /// stamped now, and a row that has left the log takes its moment with it.
  ///
  /// Recorded here rather than at each append/ingest site so that no path into
  /// the log can quietly bypass it — this is the one funnel every one of them
  /// goes through.
  ///
  /// The FIRST recording pass for a Space stamps zero, not now. Everything
  /// this device holds at that instant arrived as one historical batch it was
  /// not present for: a device that stamped it "now" would answer "nothing
  /// here predates today" to every question about the past, which is a lie of
  /// its own and a far larger one than the claims the floor exists to bound.
  Map<String, int> _notedControlReceipts(GroupBundle b) {
    final previous = b.controlReceipts;
    final baseline = previous.isEmpty;
    // [_clockNowMs], not [_now]: this runs on every save and only asks what
    // time it is. Advancing the mutation counter here would shift every
    // control and message stamp this device writes afterwards by one per save.
    final nowMs = _clockNowMs();
    final noted = <String, int>{};
    for (final entry in b.control) {
      final key = controlReceiptKey(entry);
      noted[key] = previous[key] ?? (baseline ? 0 : nowMs);
    }
    return noted;
  }

  Future<void> _save(GroupBundle b, {bool notify = true}) async {
    final controlReceipts = _notedControlReceipts(b);
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
      // Local-only, like 'rcut': the arrival moments of rows whose signed
      // stamp this device could not believe. Absent from every snapshot
      // builder, which assemble their own maps from `toJson` rows.
      if (b.messageReceipts.isNotEmpty) 'mrx': b.messageReceipts,
      if (b.postReceipts.isNotEmpty) 'prx': b.postReceipts,
      if (b.channelEpochReceipts.isNotEmpty) 'cex': b.channelEpochReceipts,
      if (controlReceipts.isNotEmpty) 'crx': controlReceipts,
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

  Future<void> _writeBundleBytes(String key, GroupBundle b, String json) async {
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
      devLog(
        () => 'xVeil[content-gc]: group index incomplete (see the line above)',
      );
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
        devLog(
          () => 'xVeil[content-gc]: a group projection is not fully readable',
        );
        return (contentIds: contentIds, complete: false);
      }
    }
    final publicIndex = await _loadPublicSubscriptionIndex();
    if (!publicIndex.complete) {
      devLog(
        () => 'xVeil[content-gc]: public-subscription index could not be read',
      );
      return (contentIds: contentIds, complete: false);
    }
    for (final hex in publicIndex.ids) {
      final NodeId spaceId;
      try {
        spaceId = NodeId.fromHex(hex);
      } catch (_) {
        devLog(
          () =>
              'xVeil[content-gc]: public-subscription index holds a malformed id',
        );
        return (contentIds: contentIds, complete: false);
      }
      final snapshot = await _loadPublicSubscriptionSnapshot(spaceId);
      if (snapshot == null) {
        // A referenced root that cannot be authenticated is uncertainty. Do
        // not use a malformed index/snapshot pair as deletion authority.
        devLog(
          () =>
              'xVeil[content-gc]: a public-subscription snapshot did not authenticate',
        );
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
        // Both sides derived: a publisher in 2027 must not be able to float
        // this Space to the top of Chats, and must not be able to beat the
        // group log's last message into the preview either.
        final postIsLatest =
            lastPost != null &&
            (last == null || lastPost.orderedAtMs >= last.orderedAtMs);
        final notificationPolicy = await groupNotificationPolicy(gid);
        final notificationMode = notificationPolicy.effectiveAt(DateTime.now());
        out.add((
          groupId: gid,
          name: state.name,
          description: state.description,
          visibility: b.manifest.visibility,
          lifecycleState: state.lifecycleState,
          discoverable: b.manifest.discoverable ?? false,
          // Same derived stamp as [unreadOf] and for the same reason: `wm` is
          // a local clock reading, so a future-stamped row would sit above
          // every watermark this device can write and pin the badge on.
          unread: msgs
              .where((m) => m.orderedAtMs > wm && m.author != _signer.selfId)
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
              ? lastPost.orderedAtMs
              : last?.orderedAtMs ?? b.manifest.createdAtMs,
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
  }) => _channelQueries.channelsOf(spaceId, includeArchived: includeArchived);

  /// Root secret one room's media seal is derived from, or null when this
  /// device does not hold (or cannot validate) the epoch key that scopes the
  /// room — in which case it must not open a media channel either.
  ///
  /// Bound to the call id so two rooms in the same epoch never share cells, and
  /// hashed here so the epoch key itself never leaves the group service. EVERY
  /// member can derive this, and that is the intended property: authenticity at
  /// the participant level is already carried by the per-sender signature on
  /// the call signal, and this seal adds confidentiality from the relays that
  /// carry the datagrams, which are not members.
  Future<Uint8List?> groupCallMediaSecret({
    required NodeId groupId,
    NodeId? channelId,
    required int membershipEpoch,
    int? channelEpoch,
    required String callId,
  }) async {
    final bundle = await load(groupId);
    if (bundle == null || bundle.manifest.isSovereignDevice) return null;
    Uint8List? key;
    if (channelId != null && channelEpoch != null) {
      key =
          bundle.localChannelEpochKeys[_channelKeyId(channelId, channelEpoch)];
      if (key == null ||
          !_validLocalChannelEpochKey(
            bundle.manifest,
            bundle.control,
            channelId,
            channelEpoch,
            key,
          )) {
        return null;
      }
    } else {
      key = bundle.localEpochKeys[membershipEpoch];
      if (key == null ||
          !_validLocalEpochKey(
            bundle.manifest,
            bundle.control,
            membershipEpoch,
            key,
          )) {
        return null;
      }
    }
    return Uint8List.fromList(
      crypto.sha256.convert([
        ...utf8.encode('xveil/group-call-media/room/v1'),
        0,
        ...key,
        0,
        ...utf8.encode(callId),
      ]).bytes,
    );
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
  ) => _channelQueries.canEnterVoiceChannel(groupId, channelId, member);

  Future<NodeId?> createChannel(
    NodeId spaceId, {
    required String name,
    required SpaceChannelKind kind,
    String description = '',
    NodeId? categoryId,
    // Null means "put it after its siblings", which is what a caller who did
    // not think about ordering meant. It used to default to 0, and only the
    // Space management screen ever passed anything else — so every channel
    // made through the API, the daemon or the debug hook landed on the same
    // position as the auto-created default, and `orderSpaceChannelsForDisplay`
    // fell through to its tiebreak on channel-id hex. That is a random order
    // presented as a deliberate one, and it is what "two channels named
    // general, both at position 0" actually was.
    //
    // `nextSpaceChannelPosition` was written for exactly this and was called
    // from one place. A helper that is correct and bypassed at the call site
    // is the shape this project keeps getting caught by.
    int? position,
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
      position:
          position ??
          nextSpaceChannelPosition(
            state.channels.values,
            categoryId: categoryId,
          ),
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
      final applied = await _channels.write(
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
          return _channels.write(
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

  /// Key rotation lives in its own file; the lock stays here because it is the
  /// owner's, and the public methods stay here because they are the API.
  late final _ChannelKeyRotation _channelKeys = _ChannelKeyRotation(this);
  late final _ChannelQueries _channelQueries = _ChannelQueries(this);

  late final _LogCompaction _compaction = _LogCompaction(this);
  late final _Reactions _reactions = _Reactions(this);

  late final _ProtectedChannels _channels = _ProtectedChannels(this);

  /// Replace a protected channel's key while leaving its ACL exactly as it is.
  ///
  /// The case this exists for is a suspected compromise — a lost phone, a
  /// shared screen — where the answer is a new key rather than a changed
  /// membership. Same permission as any other ACL edit: whoever may say who
  /// reads the channel may say when its key stops being the old one.
  Future<bool> rotateChannelKey(NodeId spaceId, NodeId channelId) =>
      _serialized(spaceId, () => _channelKeys.rotateLocked(spaceId, channelId));

  /// Rotate the keys of protected channels whose current key has served past
  /// [protectedChannelKeyMaxAgeMs] or carried more than
  /// [protectedChannelKeyMaxMessages] messages. Returns how many rotated.
  ///
  /// The volume bound is read from state that is already signed and already
  /// here — the messages that name the epoch. The age bound is NOT: it is
  /// measured from the moment this device first observed the epoch in service
  /// ([GroupBundle.channelEpochReceipts]), because the alternative is the
  /// `createdAtMs` of the control entry that introduced it, and a key whose
  /// owner may date its own birth is a key that need never grow old. See
  /// [_ChannelKeyRotation.isStale].
  ///
  /// Best-effort and idempotent. Only a device that may manage the channel can
  /// do it — for everyone else this is a no-op, and the rotation happens the
  /// next time someone who can looks. Callers can treat it as maintenance:
  /// rotating late is a weaker guarantee, not a broken one.
  Future<int> rotateStaleChannelKeys(NodeId spaceId) =>
      _serialized(spaceId, () => _channelKeys.rotateStaleLocked(spaceId));

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
    return _channels.write(
      bundle,
      state,
      current.channel,
      requestedRecipients: members,
      create: false,
    );
  });

  Future<List<NodeId>?> channelMembersOf(NodeId spaceId, NodeId channelId) =>
      _channelQueries.channelMembersOf(spaceId, channelId);

  Future<bool> setChannelArchived(
    NodeId spaceId,
    NodeId channelId,
    bool archived,
  ) => _channelQueries.setChannelArchived(spaceId, channelId, archived);

  Future<bool> setDefaultChannel(NodeId spaceId, NodeId channelId) =>
      _channelQueries.setDefaultChannel(spaceId, channelId);

  /// The next per-author seq for [author] in a list of entries carrying seq.
  int _nextSeq(Iterable<int> seqs) {
    var max = -1;
    for (final s in seqs) {
      if (s > max) max = s;
    }
    return max + 1;
  }

  /// The last row of [target]'s chain this device is willing to treat as
  /// having existed by [effectiveFromMs], or -1 when none did.
  ///
  /// Read with [GroupBundle.effectiveControlTimeMs], not with the rows' own
  /// stamps, and that is the whole reason this feature holds. A moderator who
  /// sees a demotion coming would otherwise date the next ban a week back and
  /// land below any cutoff the owner picked; floored by when this device first
  /// held the row, a row that turned up after the date the owner named counts
  /// as after it whatever year it claims.
  ///
  /// Answered once, here, on the owner's device. What is signed is the seq,
  /// so every other device enforces the boundary from signed bytes alone and
  /// two devices with two different sets of arrival moments still fold the log
  /// to one state.
  int spaceAuthorityCutoffSeq(
    GroupBundle bundle,
    NodeId target,
    int effectiveFromMs,
  ) {
    var cutoff = -1;
    for (final entry in bundle.control) {
      if (entry.author != target || entry.seq <= cutoff) continue;
      if (bundle.effectiveControlTimeMs(entry) > effectiveFromMs) continue;
      cutoff = entry.seq;
    }
    return cutoff;
  }

  /// Withdraw [target]'s control authority over everything they wrote after
  /// [effectiveFromMs], or return it from this point on when [restore].
  ///
  /// Owner-only (see `SpaceAcl.roleAllowsControl`). Returning authority is
  /// forward-only by design: rows already withdrawn stay withdrawn, because
  /// giving someone their role back is not a statement that what they did
  /// without one was fine. If a withdrawn ban was in fact deserved, the
  /// restored moderator can issue it again in one row.
  Future<bool> setSpaceAuthorityBoundary(
    NodeId spaceId,
    NodeId target, {
    required int effectiveFromMs,
    bool restore = false,
  }) => _serialized(spaceId, () async {
    if (target == _signer.selfId) return false;
    final bundle = await load(spaceId);
    if (bundle == null || !bundle.manifest.isSpace) return false;
    final boundary = SpaceAuthorityBoundary(
      effectiveFromMs: effectiveFromMs,
      // A restoration names the target's chain HEAD as this device knows it,
      // so everything already written — including a row dated into next year
      // that has not been folded yet — stays on the withdrawn side of it.
      fromSeq: restore
          ? _nextSeq(
                  bundle.control
                      .where((entry) => entry.author == target)
                      .map((entry) => entry.seq),
                ) -
                1
          : spaceAuthorityCutoffSeq(bundle, target, effectiveFromMs),
      restore: restore,
    );
    if (!boundary.isStructurallyValid) return false;
    return _addControlOp(
      spaceId,
      ControlOp.revokeAuthority,
      target: target,
      authorityBoundary: boundary,
    );
  });

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
    SpaceAuthorityBoundary? authorityBoundary,
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
            op == ControlOp.restoreSpace ||
            op == ControlOp.revokeAuthority) &&
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
        // A withdrawal reaches back over membership and role rows, so it can
        // put someone back in the Space or take someone out of it.
        op == ControlOp.revokeAuthority ||
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
              version: authorityBoundary != null
                  ? 22
                  : lifecycleTransition != null
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
              authorityBoundary: authorityBoundary,
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
          final revision = await _channels.prepare(
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

      // A withdrawal that changed who is in the Space needs the same treatment
      // and needs it in both directions: whoever a withdrawn ban puts back has
      // no current key, and whoever a withdrawn `addMember` takes out must not
      // receive the next one.
      final withdrawalMovedMembership =
          op == ControlOp.revokeAuthority &&
          (folded.state.members.length != state.members.length ||
              folded.state.members.keys.any(
                (hex) => !state.members.containsKey(hex),
              ));
      // An add itself must remain readable by legacy peers, then an immediately
      // following signed rotate establishes a key for the post-add membership.
      // New members receive no older envelopes: forward secrecy is the default.
      if ((op == ControlOp.addMember || withdrawalMovedMembership) &&
          epochService != null) {
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

  /// The Space's administrative history as this member is allowed to read it.
  ///
  /// The whole decision lives in [spaceActionLog]; this only pairs the accepted
  /// rows with the folded state they must be judged against.
  Future<List<SpaceActionLogItem>> spaceRecentActions(NodeId spaceId) async {
    final bundle = await load(spaceId);
    final state = await stateOf(spaceId);
    if (bundle == null || state == null) return const [];
    return spaceActionLog(
      control: bundle.control,
      state: state,
      viewer: _signer.selfId,
    );
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
  String _messageChainScope(SpaceManifest manifest, GroupMessage message) {
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
        // Aimed at the target's own authority, never at their membership: a
        // withdrawal that removes a row which removed someone is already
        // reflected here by that row's absence from `accepted`.
        case ControlOp.revokeAuthority:
          break;
      }
    }
    return grant;
  }

  ({bool revoked, SpacePostBoundary? boundary}) _postRevocationForGrant(
    SpaceManifest manifest,
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
        case ControlOp.revokeAuthority:
          break;
      }
    }
    return (revoked: false, boundary: null);
  }

  GroupFoldResult? _historicalFoldForPost(
    SpaceManifest manifest,
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
    SpaceManifest manifest,
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
    // Deliberately NOT `state.retentionHistory`: the fold is a pure domain
    // function with no clock, so its copy of the timeline still carries a
    // revision dated into the future — and the monotone clamp then lifts every
    // honest revision behind it to the same year, which is exactly the
    // standstill this bound exists to prevent. A post is Space-scoped
    // (`channelId: null`), so the clear V9 subset is the whole answer here.
    final retention = _clearRetentionRevisions(bundle);
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
            spaceRetentionRemovesMedia(
              revisions: retention,
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
                spaceRetentionRemoves(
                  revisions: retention,
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
    // Rank on the DERIVED stamp, not the signed one. `published` is the
    // author's own word and the signature over it proves only who said it, so
    // one publisher stamping itself years ahead would otherwise hold the top
    // of this Space, its row in Chats, and the watermark `markSpaceFeedSeen`
    // writes. Rewriting it is not available here (it is inside
    // `canonicalBytes`), so a root whose stamp could not be believed on
    // arrival is ordered by the moment it arrived instead.
    //
    // Applied from a value frozen at ingest, not from a live clock, so the
    // post lands once and stays there — the Feed pages on this exact order,
    // and a row that moved between two pages would be lost or repeated. The
    // map is empty unless this Space has actually been handed such a row, and
    // then this whole pass is skipped.
    if (bundle.postReceipts.isNotEmpty) {
      for (var i = 0; i < visiblePosts.length; i++) {
        final receivedAtMs =
            bundle.postReceipts[spacePostReceiptKey(visiblePosts[i].root)];
        if (receivedAtMs == null) continue;
        visiblePosts[i] = visiblePosts[i].withOrderedAt(
          spacePostOrderAt(visiblePosts[i].root.publishedAtMs, receivedAtMs),
        );
      }
    }
    visiblePosts.sort((left, right) {
      final time = left.orderedAtMs.compareTo(right.orderedAtMs);
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

  late final _PublicSubscriptions _publicSubscriptions = _PublicSubscriptions(
    this,
  );

  Future<SpacePublicSubscriptionView?> publicSpaceSubscription(
    NodeId spaceId,
  ) => _publicSubscriptions.publicSpaceSubscription(spaceId);

  /// Return the author-signed public discussion for one subscribed post.
  ///
  /// The public snapshot has already passed its owner manifest gate. Folding
  /// here verifies every contributing author again and rejects broken chains,
  /// so UI callers never need access to the service's private signer.
  Future<List<SpacePublicCommentView>> publicSpacePostComments(
    NodeId spaceId,
    String postId,
  ) => _publicSubscriptions.publicSpacePostComments(spaceId, postId);

  Future<SpacePublicReactions> publicSpacePostReactions(
    NodeId spaceId,
    String postId,
  ) => _publicSubscriptions.publicSpacePostReactions(spaceId, postId);

  /// Stable public root refs known to an active member. The composer uses this
  /// to prevent accidentally marking a reply public when its parent was
  /// members-only (which would otherwise be rejected by the service).
  Future<Set<String>> publicSpacePostCommentRefs(
    NodeId spaceId,
    String postId,
  ) => _publicSubscriptions.publicSpacePostCommentRefs(spaceId, postId);

  Future<List<SpacePublicSubscriptionView>> publicSpaceSubscriptions() =>
      _publicSubscriptions.publicSpaceSubscriptions();

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
  ) => _publicSubscriptions.subscribeToPublicSpace(descriptor, holders);

  Future<SpacePublicSubscriptionView?> subscribeToPublicSpaceDiscovery(
    SpacePublicDiscoveryResult result,
  ) => _publicSubscriptions.subscribeToPublicSpaceDiscovery(result);

  Future<SpacePublicSubscriptionView?> refreshPublicSpaceSubscription(
    NodeId spaceId, {
    Duration timeout = const Duration(seconds: 8),
  }) => _publicSubscriptions.refreshPublicSpaceSubscription(
    spaceId,
    timeout: timeout,
  );

  /// Refresh the exact public descriptor/holders before opening a media grant.
  /// Stored bytes remain usable offline, but a new transfer never relies on an
  /// expired holder captured in a local snapshot.
  Future<bool> requestSubscribedPublicSpaceMedia(
    NodeId spaceId,
    String contentId, {
    Duration timeout = const Duration(seconds: 8),
  }) => _publicSubscriptions.requestSubscribedPublicSpaceMedia(
    spaceId,
    contentId,
    timeout: timeout,
  );

  /// Deactivate first, then best-effort scrub the now-unreachable public
  /// snapshot. Shared downloaded media is reclaimed only by the global GC.
  Future<bool> unsubscribeFromPublicSpace(NodeId spaceId) =>
      _publicSubscriptions.unsubscribeFromPublicSpace(spaceId);

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

  late final _SpaceFeed _spaceFeed = _SpaceFeed(this);

  Future<void> setSpaceFeedEnabled(NodeId spaceId, bool enabled) =>
      _spaceFeed.setSpaceFeedEnabled(spaceId, enabled);

  Future<void> setSpaceNotificationsEnabled(NodeId spaceId, bool enabled) =>
      _spaceFeed.setSpaceNotificationsEnabled(spaceId, enabled);

  Future<void> setSpaceCommentNotifications(
    NodeId spaceId,
    SpaceCommentNotificationMode mode,
  ) => _spaceFeed.setSpaceCommentNotifications(spaceId, mode);

  Future<void> setSpaceHiddenFromRecommendations(NodeId spaceId, bool hidden) =>
      _spaceFeed.setSpaceHiddenFromRecommendations(spaceId, hidden);

  /// Merge subscribed Space logs in descending chronological order. The
  /// signed `(publishedAt, spaceId, author, seq)` tuple is a stable cursor and
  /// the identity set prevents duplicates regardless of roles or sync paths.
  Future<List<SpaceFeedItem>> spaceFeed({
    SpaceFeedCursor? before,
    int limit = 50,
    Set<SpacePostType>? types,
    SpaceFeedFilter? filter,
    bool? pinned,
  }) => _spaceFeed.spaceFeed(
    before: before,
    limit: limit,
    types: types,
    filter: filter,
    pinned: pinned,
  );

  Future<int> unreadSpacePosts(NodeId spaceId) =>
      _spaceFeed.unreadSpacePosts(spaceId);

  Future<List<SpacePostView>> unreadSpacePostViews(NodeId spaceId) =>
      _spaceFeed.unreadSpacePostViews(spaceId);

  Future<void> markSpaceFeedSeen(NodeId spaceId) =>
      _spaceFeed.markSpaceFeedSeen(spaceId);

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
    // ADMISSION FIRST (audit report6 XV-09). The fold above is the cheapest
    // thing that can answer "is this peer a member", so it is the last work
    // done before the answer. Everything below — materializing the retention
    // history, walking every retained row, scanning for forks, then building
    // and shipping a reply — is proportional to the whole group and used to
    // run BEFORE anyone asked whether the sender was entitled to any of it.
    // A Space id is public by construction (it IS the group id), so that was
    // reachable with nothing but a transport session and a published id.
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
    final manifest = SpaceManifest.fromJson(decoded?['m']);
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
      _spaceInvites._serializeSpaceInvites(() async {
        final store = await _spaceInvites._loadSpaceInvites();
        await _spaceInvites._saveSpaceInvites(
          incoming: [
            for (final entry in store.incoming)
              if (entry.invite.inviteId != inviteId) entry,
          ],
          outgoing: store.outgoing,
        );
        changes.value++;
      });

  /// The NON-contact variant of [ingestGroupEntry]: a member's sync vector is
  /// answered and a bundle is merged, both only through [allowStrangerGroupSync]
  /// — the one admission every non-contact ingress passes.
  ///
  /// The sync-request branch used to reach the handler directly, so a stranger's
  /// entitlement was decided deep inside it rather than here (audit report6
  /// XV-09). It is asked here now, before the handler is entered at all: this is
  /// the boundary where "we have never agreed to talk to this node" is known,
  /// and the wire layer already consults the same gate before spending
  /// reassembly RAM on a stranger's chunks. A stranger that IS a member of a
  /// group we hold still passes — that legitimate member-to-member sync without
  /// a pairwise contact handshake is exactly what the gate exists to allow.
  Future<bool> ingestGroupEntryFromStranger(NodeId peer, String json) async {
    Map? decoded;
    try {
      final d = jsonDecode(json);
      if (d is Map) decoded = d;
    } catch (_) {
      return false; // malformed — drop
    }
    if (decoded != null && decoded['sreq'] == 1) {
      final gidHex = decoded['gid'];
      if (gidHex is! String || !await allowStrangerGroupSync(peer, gidHex)) {
        devLog(() => 'xVeil[groups]: stranger sync request DENIED — drop');
        return false;
      }
      return handleGroupSyncRequest(peer, decoded);
    }
    SpaceJoinOutboxEntry? acceptedJoinRequest;
    final manifest = SpaceManifest.fromJson(decoded?['m']);
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
    final manifest = SpaceManifest.fromJson(wire['m']);
    if (manifest == null ||
        wire['c'] is! List ||
        (wire['c'] as List).isNotEmpty) {
      return;
    }
    var messages = (wire['g'] as List? ?? const [])
        .map(GroupMessage.fromJson)
        .whereType<GroupMessage>()
        .toList();
    var reactions = (wire['r'] as List? ?? const [])
        .map(GroupReaction.fromJson)
        .whereType<GroupReaction>()
        .toList();
    var posts = (wire['p'] as List? ?? const [])
        .map(SpacePost.fromJson)
        .whereType<SpacePost>()
        .toList();
    var publicComments = (wire['pc'] as List? ?? const [])
        .map(SpacePublicComment.fromJson)
        .whereType<SpacePublicComment>()
        .toList();
    var publicReactions = (wire['pr'] as List? ?? const [])
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
    // Collapse repeats before anything else looks at them. A delta that
    // carries one row ten times is a delta about ONE row, and relaying ten
    // copies of it to every neighbour is the amplification this is about
    // (audit XV-11).
    messages = _distinctRows(messages, (row) => row.toJson());
    reactions = _distinctRows(reactions, (row) => row.toJson());
    posts = _distinctRows(posts, (row) => row.toJson());
    publicComments = _distinctRows(publicComments, (row) => row.toJson());
    publicReactions = _distinctRows(publicReactions, (row) => row.toJson());
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
    // Rank on the DERIVED stamp, not the signed one. `ts` is the author's own
    // word and the signature over it proves only who said it, so one member
    // stamping itself years ahead would otherwise own the bottom of this log
    // for as long as the stamp lasts. Rewriting it is not available here (it is
    // inside `canonicalBytes`), so a row whose stamp could not be believed on
    // arrival is ordered by the moment it arrived instead.
    //
    // Applied from a value frozen at ingest, not from a live clock, so the row
    // lands once and stays there. The map is empty unless this group has
    // actually been handed such a row, and then this whole pass is skipped.
    if (b.messageReceipts.isNotEmpty) {
      for (var i = 0; i < out.length; i++) {
        final receivedAtMs = b.messageReceipts[groupMessageReceiptKey(out[i])];
        if (receivedAtMs == null) continue;
        out[i] = out[i].withOrderedAt(
          groupMessageOrderAt(out[i].createdAtMs, receivedAtMs),
        );
      }
    }
    out.sort((a, b) {
      final t = a.orderedAtMs.compareTo(b.orderedAtMs);
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
    () => _reactions.react(
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
    () => _reactions.react(
      spaceId,
      postId,
      emoji,
      targetKind: ReactionTargetKind.spacePost,
      publiclyVisible: publiclyVisible,
      broadcast: broadcast,
    ),
  );

  /// The folded reactions of [groupId]: `messageRef -> emoji -> reactors`.
  Future<Map<String, MessageReactions>> reactionsOf(NodeId groupId) =>
      _reactions.reactionsOf(groupId);

  /// The folded reactions of visible, non-deleted Space publication roots.
  Future<Map<String, MessageReactions>> spacePostReactionsOf(NodeId spaceId) =>
      _reactions.spacePostReactionsOf(spaceId);

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
    SpaceManifest? manifest;
    try {
      final d = jsonDecode(bundleJson);
      manifest = SpaceManifest.fromJson(d is Map ? d['m'] : null);
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
  /// A counter behind [_freshTransferTag], so two pushes of an UNCHANGED
  /// bundle within the same millisecond still differ.
  int _transferSeq = 0;

  /// A value that has never been used for this bundle before.
  ///
  /// WHY A FULL-HISTORY PUSH NEEDS ONE: the durable frame id of a snapshot is
  /// derived from the snapshot's own bytes (messaging_replication.dart, "key
  /// the frame by CONTENT"), which is right for a re-drive — the same content
  /// twice should collapse into one delivery. It is wrong for re-seeding a
  /// peer that LOST what it had: the bundle has not changed, so the frames
  /// carry exactly the ids the peer acknowledged in its previous life, the
  /// delivery layer treats them as settled, and the snapshot can never land.
  /// Measured live on a device whose store was erased: 204 chunks arrived and
  /// reassembly never completed; one row appended to the source bundle changed
  /// the content, and adoption then succeeded on the first attempt.
  String _freshTransferTag() => '${_now()}-${_transferSeq++}';

  String snapshotJson(
    GroupBundle b, {
    NodeId? recipient,
    String? receipt,
    String? transferTag,
  }) {
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
      // Carried only by a full-history push. Older builds ignore an unknown
      // envelope key, so this is safe in both directions on the wire.
      'tx': ?transferTag,
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
    final manifest = SpaceManifest.fromJson(d['m']);
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
    final messageReceipts = <String, int>{...?existing?.messageReceipts};
    final postReceipts = <String, int>{...?existing?.postReceipts};
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
      messageReceipts: messageReceipts,
      postReceipts: postReceipts,
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
      // A signed `ts` no clock could have produced. The stamp itself is left
      // exactly as signed — it has to be, `canonicalBytes` covers it — so what
      // is recorded instead is the one time this device actually knows: now.
      // [_messagesOfBundle] orders on that; nothing else here changes.
      //
      // putIfAbsent, and OUTSIDE the dedup below on purpose. Peers re-ship
      // whole snapshots continuously, so this exact row arrives again and
      // again against a clock that has moved on; the first arrival is the only
      // one that may set the value, or the row would walk down the log on
      // every sync. Outside the dedup so a row already on disk from before
      // this rule existed is bounded the next time it is offered, instead of
      // keeping its 2100 forever.
      if (groupMessageOrderAt(m.createdAtMs, ingestAtMs) != m.createdAtMs) {
        messageReceipts.putIfAbsent(
          groupMessageReceiptKey(m),
          () => ingestAtMs,
        );
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
      // A signed `published` no clock could have produced. The stamp itself
      // is left exactly as signed — it has to be, `canonicalBytes` covers it
      // and every public-feed page hashes over it — so what is recorded
      // instead is the one time this device actually knows: now.
      // [_postsOfBundle] orders on that; nothing else here changes.
      //
      // Only publication ROOTS: an edit or delete row carries its own
      // `published` but is never what a Feed cursor names, so binding one
      // would be an entry nothing ever looks up.
      //
      // putIfAbsent, and OUTSIDE the dedup below on purpose. Peers re-ship
      // whole snapshots continuously, so this exact row arrives again and
      // again against a clock that has moved on; the first arrival is the
      // only one that may set the value, or the post would walk down the Feed
      // on every sync — and, since the Feed pages on that order, would be
      // skipped or repeated across an open page boundary. Outside the dedup
      // so a row already on disk from before this rule existed is bounded the
      // next time it is offered, instead of keeping its 2027 forever.
      if (post.operation == SpacePostOperation.publish &&
          spacePostOrderAt(post.publishedAtMs, ingestAtMs) !=
              post.publishedAtMs) {
        postReceipts.putIfAbsent(spacePostReceiptKey(post), () => ingestAtMs);
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
      messageReceipts: messageReceipts,
      postReceipts: postReceipts,
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
      messageReceipts: messageReceipts,
      postReceipts: postReceipts,
      // Carried, never recomputed here. If ingest dropped these, a peer that
      // keeps re-shipping snapshots would reset every channel key's age on
      // every sync and the age bound would never fire again — the same
      // fail-open the claimed stamp used to give, from the other side.
      channelEpochReceipts:
          existing?.channelEpochReceipts ?? const <String, int>{},
      // Carried for the same reason, and here the fail-open is sharper: a peer
      // re-shipping snapshots would make every row look as if it had arrived
      // on the last sync, and the floor under a backdated row would vanish
      // exactly when it is needed. [_save] then stamps whatever is new.
      controlReceipts: existing?.controlReceipts ?? const <String, int>{},
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
      unawaited(_channels.repairEpochs(man.groupId));
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
  ///
  /// Against the DERIVED stamp, because this watermark is a local wall-clock
  /// reading ([markGroupSeen]) while `createdAtMs` is whatever the author
  /// claimed. One member stamping itself into the future is otherwise newer
  /// than every watermark this device will ever write, and the badge on that
  /// group can never be cleared again — the mirror image of what a future
  /// stamp did to the 1:1 badge, where the watermark is taken FROM the
  /// messages and the badge went permanently silent instead.
  Future<int> unreadOf(NodeId groupId) async {
    final wm =
        int.tryParse(
          await _storage.getSetting('group.seen:${groupId.hex}') ?? '',
        ) ??
        0;
    final msgs = await messagesOf(groupId);
    return msgs.where((m) => m.orderedAtMs > wm && m.author != selfId).length;
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

  Uint8List _manifestHash(SpaceManifest manifest) =>
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
    return broadcast(NodeId.fromHex(gidHex), reseed: true);
  }

  bool _sovereignMatches(
    SpaceManifest manifest,
    SovereignGroupSigner sovereign,
  ) =>
      manifest.isSovereignDevice &&
      manifest.signatureAlgorithm == sovereign.algorithm &&
      manifest.owner == sovereign.nodeId &&
      _listEquals(manifest.genesisPubKey, sovereign.publicKey);

  bool _canUpgradeSovereign(
    SpaceManifest manifest,
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
    final unsignedManifest = SpaceManifest(
      groupId: gid,
      owner: sovereign.nodeId,
      genesisPubKey: Uint8List.fromList(sovereign.publicKey),
      name: kDeviceGroupName,
      createdAtMs: _now(),
      version: SpaceManifest.sovereignDeviceVersion,
      kind: SpaceManifest.sovereignDeviceKind,
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
      // The membership filter this caller used to do by hand now lives inside
      // the pass, where `compactLocked` gets it too (report9 X-18).
      final compact =
          _compaction.compactDeviceMessages(
            migrateFrom.manifest.groupId,
            migrateFrom.messages,
            isMember: oldState.isMember,
          )..sort((a, b) {
            final ts = a.createdAtMs.compareTo(b.createdAtMs);
            return ts != 0 ? ts : _compaction.messageIdentityCompare(a, b);
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
    if (broadcastSnapshot) await broadcast(gid, reseed: true);
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
    final unsignedManifest = SpaceManifest(
      groupId: gid,
      owner: sovereign.nodeId,
      genesisPubKey: Uint8List.fromList(sovereign.publicKey),
      name: kDeviceGroupName,
      createdAtMs: _now(),
      version: SpaceManifest.sovereignDeviceVersion,
      kind: SpaceManifest.sovereignDeviceKind,
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
    final ok = await _revokeDevice(device, sovereign: sovereign);
    // A revoked device is never coming back to this group, so whatever is still
    // queued for it is dead weight — on the stand a wiped device held 3473
    // frames and 9.56 MB of undelivered snapshots. Only on SUCCESS: if the
    // revoke failed the device is still a member and still owes that state.
    if (ok) {
      try {
        await onMemberRevoked?.call(device);
      } catch (_) {
        // Tidy-up must never turn a completed revoke into a failure.
      }
    }
    return ok;
  }

  /// Told when a device has really been removed, so the transport layer can let
  /// go of anything it was still holding for it. Wired by the provider; null in
  /// tests that do not care.
  Future<void> Function(NodeId device)? onMemberRevoked;

  Future<bool> _revokeDevice(
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
  /// Ship the device group to the other devices.
  ///
  /// [reseed] marks the calls that exist for a device which may hold nothing —
  /// adoption and the explicit snapshot send. The boot catch-up does NOT set
  /// it: it runs on every bridge build, and a fresh identity there is what
  /// turned two idle devices into a permanent exchange of whole bundles.
  Future<int> nudgeDeviceSync({bool reseed = false}) async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return 0;
    return broadcast(NodeId.fromHex(hex), reseed: reseed);
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

  void _publishDeviceMembersCache(SpaceManifest manifest, GroupState state) {
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
  ///
  /// Rows stamped past [kDeviceSyncClockSkew] ahead of this device's clock are
  /// left out — a linked device must not be able to win a key by claiming to
  /// live in the future. They stay in the log and fold in on a later read.
  Future<Map<(DeviceSyncKind, String), DeviceSyncEvent>>
  deviceSyncState() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const {};
    final msgs = await messagesOf(NodeId.fromHex(hex));
    final nowMs = _now();
    return foldDeviceSync([
      for (final m in msgs)
        if (DeviceSyncEvent.fromBody(m.body) case final e?)
          if (deviceSyncEffectiveAt(e, nowMs)) e,
    ]);
  }

  /// Every validated device-sync row with its signed message author retained.
  /// Most LWW kinds need only [deviceSyncState]; cloud replica claims must also
  /// prove `claimed device == author`, so discarding the author would turn the
  /// group into a replica-count spoofing oracle.
  ///
  /// Same clock bound as [deviceSyncState]: this is what the personal-cloud and
  /// capability-registry folds read, so a future-stamped tombstone must not be
  /// able to retire an item until its own timestamp actually arrives.
  Future<List<DeviceSyncRecord>> deviceSyncRecords() async {
    final hex = await deviceGroupIdHex();
    if (hex == null) return const [];
    final messages = await messagesOf(NodeId.fromHex(hex));
    final nowMs = _now();
    return [
      for (final message in messages)
        if (DeviceSyncEvent.fromBody(message.body) case final event?)
          if (deviceSyncEffectiveAt(event, nowMs))
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
  Future<int> broadcast(NodeId groupId, {bool reseed = false}) async {
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
    // A fresh transfer identity ONLY when the peer may hold nothing.
    //
    // Keying the frame by content is what lets an unchanged bundle collapse
    // into no delivery at all, and that is load-bearing far beyond bandwidth:
    // measured live, minting a fresh identity on EVERY broadcast had two
    // devices shipping the whole bundle to each other without pause — 256
    // chunk frames in one short window — because each push arrived as new and
    // provoked the next. The dedup was not only in the way of re-seeding, it
    // was also what stopped that.
    //
    // So the freshness is reserved for the moments that MEAN "they may have
    // nothing": adoption, linking, a member joining, an explicit snapshot
    // send. Everything else stays content-keyed and silent when nothing moved.
    final transferTag = reseed ? _freshTransferTag() : null;
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
            snapshotJson(
              b,
              recipient: m.nodeId,
              receipt: receipt,
              transferTag: transferTag,
            ),
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
    // The one place a membership-ending decision is handed to the person it
    // ends. `state` is folded AFTER the removal is already in the log, so the
    // target is gone from `state.members` and the ordinary recipient list above
    // excludes them from the very delta that carries the news about them. That
    // is right for `leave` (see [_leaveGroup]) and wrong for every authority
    // decision: measured live, a removed member sat on epoch 2 with
    // `selfRole: member` four minutes later and was told `ok` for writes that
    // reached nobody. `revokeAuthority` reaches the same end without naming
    // anybody — see [_membershipEndedTargets], which answers for both.
    //
    // They are served OUT of that loop, never inside it. Measured on the
    // ordinary per-peer tailoring: `_epochEnvelopesFor` /
    // `_channelEpochEnvelopesFor` do come back empty for the target of the very
    // delta that removes them (the new epoch is sealed without them, and their
    // retained old envelopes verify against no descriptor this delta carries) —
    // but the CONTENT filters do not. With encryption not yet established, or
    // for any epoch the target still holds an envelope for,
    // `_peerCanDecryptEpoch` says yes and the ordinary loop hands them message,
    // reaction and post rows (pinned in test/removed_member_notice_test.dart).
    // So the notice is built here from the control rows alone rather than
    // filtered down to them, and no envelope helper is consulted for it at all.
    final departed = control.isEmpty
        ? const <NodeId>[]
        : [
            for (final target in _membershipEndedTargets(b, state, control))
              if (target != _signer.selfId &&
                  !exclude.contains(target) &&
                  (!b.manifest.isSovereignDevice || target != b.manifest.owner))
                target,
          ];
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
      for (final target in departed) {
        // Manifest + the signed control rows, and nothing else. No epoch
        // envelope, no message, reaction or post row, no overlay id — and no
        // delivery receipt either: a node that has just been removed is not a
        // replication holder and must not be counted as one.
        await send(
          target,
          groupId,
          jsonEncode({
            'm': b.manifest.toJson(),
            'c': control.map((entry) => entry.toJson()).toList(),
            'g': const <Map<String, dynamic>>[],
            'r': const <Map<String, dynamic>>[],
          }),
        );
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

  /// The nodes whose membership THIS delta ends — however it ends it. [state]
  /// is [b]'s log folded WITH [control] already in it; [control] are the rows
  /// this delta carries.
  ///
  /// Two derivations, and they live in this one function on purpose. A second
  /// function answering the same question is a second answer waiting to drift
  /// from the first, and the whole class of defect here is exactly that: a
  /// decision that ends someone's membership while the recipient list is
  /// computed somewhere that does not know it did.
  ///
  ///  1. The decision that NAMES its target — `removeMember`, `ban`, a
  ///     membership-removing `moderate`. Read straight off the rows, so it
  ///     still answers for a delta whose rows this device has not (or not yet)
  ///     appended to [b], where there is nothing to fold a difference against.
  ///
  ///  2. The decision that does not name anyone. `revokeAuthority` carries a
  ///     boundary that reaches BACKWARDS over its target's chain, and a
  ///     withdrawn `addMember` takes the person who was admitted out of the
  ///     Space without mentioning them in any op above. It can also work at one
  ///     remove — withdrawing a `revokeModeration` re-arms a readmission bar,
  ///     which rejects a later, perfectly valid `addMember` by someone else
  ///     entirely. Neither is reachable by asking an op what it is called, so
  ///     this asks the fold instead: who did the log hold as a member before
  ///     these rows, and no longer holds now. That question needs no
  ///     maintenance when a new op joins [ControlOp].
  ///
  /// A `leave` is excluded, and only a `leave` is. The person who left authored
  /// the row and already holds it, and [_leaveGroup] depends on the fanout
  /// reaching only the members who remain.
  List<NodeId> _membershipEndedTargets(
    GroupBundle b,
    GroupState state,
    List<ControlEntry> control,
  ) {
    final ended = <String, NodeId>{};
    final rowsInThisDelta = <String>{};
    final departedOfTheirOwnAccord = <String>{};
    for (final entry in control) {
      rowsInThisDelta.add('${entry.author.hex}:${entry.seq}');
      if (entry.op == ControlOp.leave) {
        departedOfTheirOwnAccord.add(entry.author.hex);
      }
      final target = switch (entry.op) {
        ControlOp.removeMember || ControlOp.ban => entry.target,
        ControlOp.moderate
            when entry.moderationAction?.kind.removesMembership == true =>
          entry.moderationAction!.target,
        _ => null,
      };
      if (target == null) continue;
      ended[target.hex] = target;
    }
    // The same log without this delta's rows. Every caller appends before it
    // broadcasts, so these are the tail of their author's chain and removing
    // them leaves the remaining chains intact.
    //
    // A difference is not the whole answer, which is why derivation (1) above
    // stays: a catch-up delta carrying both someone's admission AND their
    // removal folds to no difference at all — the log without those rows never
    // held them either — and they are still exactly the person it is about
    // (pinned in test/removed_member_notice_test.dart).
    final before = foldControlLog(
      owner: b.manifest.owner,
      entries: [
        for (final entry in b.control)
          if (!rowsInThisDelta.contains('${entry.author.hex}:${entry.seq}'))
            entry,
      ],
      verify: (e) => _validControlFor(b.manifest, e),
    ).state;
    for (final member in before.members.values) {
      if (departedOfTheirOwnAccord.contains(member.nodeId.hex)) continue;
      ended[member.nodeId.hex] = member.nodeId;
    }
    // Whoever the folded state still holds is a member, and a member is served
    // by the ordinary recipient list: a remove that a later row in the same
    // delta undid, or someone a withdrawal put BACK into the Space.
    ended.removeWhere((hex, _) => state.members.containsKey(hex));
    return ended.values.toList(growable: false);
  }

  /// The identity of an overlay delta: WHAT it carries, not how many times.
  ///
  /// This was `(type, author, seq)` per row, collected into a LIST, and two
  /// things followed from that. Repeating one valid row N times in a single
  /// delta produced N different ids, so the relay dedup saw a brand new delta
  /// every time and an accepted contact could pump the same signed row through
  /// the overlay without limit — one string, unlimited identities (audit
  /// XV-11). And two differently-signed rows that shared an (author, seq)
  /// collided, so the second was silently never relayed.
  ///
  /// Both stop when the id is a hash of the row CONTENT and the parts are a
  /// SET: multiplicity stops mattering, and different bytes stop colliding.
  ///
  /// This does NOT weaken deniability. The id is ephemeral — it lives in RAM
  /// for the lifetime of the process, is never signed, never persisted, and
  /// never leaves this device except as the opaque `ov` field it already was.
  String _overlayDeltaId(
    NodeId groupId,
    Iterable<GroupMessage> messages,
    Iterable<GroupReaction> reactions, [
    Iterable<SpacePost> posts = const [],
    Iterable<SpacePublicComment> publicComments = const [],
    Iterable<SpacePublicReaction> publicReactions = const [],
  ]) {
    final identities = <String>{
      for (final message in messages) 'm:${_rowDigest(message.toJson())}',
      for (final reaction in reactions) 'r:${_rowDigest(reaction.toJson())}',
      for (final post in posts) 'p:${_rowDigest(post.toJson())}',
      // Already content-derived, and cheaper than re-hashing the row.
      for (final comment in publicComments) 'pc:${comment.recordHash}',
      for (final reaction in publicReactions) 'pr:${reaction.recordHash}',
    }.toList()..sort();
    return crypto.sha256
        .convert(utf8.encode('${groupId.hex}|${identities.join('|')}'))
        .toString();
  }

  /// A row's content, canonically. The same `toJson`-then-encode equality the
  /// relay's stored-row lookup already uses, so the two cannot disagree about
  /// whether two rows are the same row.
  static String _rowDigest(Map<String, dynamic> json) =>
      crypto.sha256.convert(utf8.encode(jsonEncode(json))).toString();

  /// Distinct rows, by that same canonical content, order preserved.
  static List<T> _distinctRows<T>(
    List<T> rows,
    Map<String, dynamic> Function(T) json,
  ) {
    if (rows.length < 2) return rows;
    final seen = <String>{};
    return [
      for (final row in rows)
        if (seen.add(_rowDigest(json(row)))) row,
    ];
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
