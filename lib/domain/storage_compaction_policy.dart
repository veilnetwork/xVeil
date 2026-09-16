// When to OFFER storage compaction, and what the offer is allowed to claim.
//
// The container never shrinks on its own: every commit writes new versions of
// the chunks it touches and the old ones stay until a repack. Measured on a
// real stand — one short message costs about twelve 4 KiB slots, and a single
// app start writes tens of megabytes — so a busy profile reaches gigabytes of
// dead padding while its live data stays in the tens of megabytes.
//
// This file holds the DECISION and nothing else: pure, so the numbers can be
// tested without a container, and so there is exactly one place that decides
// whether a person is worth interrupting.

/// How much of the file is dead, and how confidently we know it.
///
/// The honesty problem this type exists to solve: a space can count only the
/// chunks decryptable under ITS key (`ownedChunks`). In a container holding
/// several identities, every sibling's live data looks exactly like garbage
/// from here — so "reclaimable" computed from one identity ALWAYS overstates,
/// and on a decoy-bearing container it can overstate by the whole of the other
/// identity. The figure only becomes exact once every identity has been
/// unlocked and counted, which is why the offer asks for all the passwords
/// before it promises a number.
class CompactionEstimate {
  const CompactionEstimate({
    required this.fileBytes,
    required this.liveBytes,
    required this.identitiesCounted,
    required this.identitiesKnown,
  });

  /// Size of the container on disk.
  final int fileBytes;

  /// Live bytes summed over the identities counted so far.
  final int liveBytes;

  /// How many identities contributed to [liveBytes].
  final int identitiesCounted;

  /// How many identities this container is known to hold. When it exceeds
  /// [identitiesCounted] the estimate is an upper bound, not a measurement.
  final int identitiesKnown;

  /// Every identity accounted for → [reclaimableBytes] is exact.
  bool get isExact =>
      identitiesKnown > 0 && identitiesCounted >= identitiesKnown;

  /// What a repack would give back. Never negative: a container can report
  /// more live chunks than slots mid-commit, and a negative "reclaim" would
  /// read as a shrinking file.
  int get reclaimableBytes {
    final r = fileBytes - liveBytes;
    return r < 0 ? 0 : r;
  }

  /// What the file would be after a repack that keeps every counted identity.
  int get projectedBytes => fileBytes - reclaimableBytes;
}

/// The two knobs a person gets over the offer.
class CompactionOfferSettings {
  const CompactionOfferSettings({
    this.period = defaultPeriod,
    this.thresholdBytes = defaultThresholdBytes,
    this.enabled = true,
  });

  /// Don't ask again for this long after an offer was shown.
  static const Duration defaultPeriod = Duration(days: 3);

  /// Below this much reclaimable space the offer is not worth an interruption:
  /// compaction costs a teardown and a re-unlock, and on a phone that is the
  /// slow key derivation twice over.
  static const int defaultThresholdBytes = 1 << 30; // 1 GiB

  final Duration period;
  final int thresholdBytes;
  final bool enabled;

  CompactionOfferSettings copyWith({
    Duration? period,
    int? thresholdBytes,
    bool? enabled,
  }) => CompactionOfferSettings(
    period: period ?? this.period,
    thresholdBytes: thresholdBytes ?? this.thresholdBytes,
    enabled: enabled ?? this.enabled,
  );
}

/// Why an offer is (not) being shown — so the settings screen can explain
/// itself instead of silently doing nothing.
enum CompactionOfferVerdict {
  /// Show it.
  offer,

  /// The person turned offers off.
  disabled,

  /// An offer was shown less than [CompactionOfferSettings.period] ago.
  tooSoon,

  /// There is less to reclaim than the threshold asks for.
  belowThreshold,
}

/// Decide whether to interrupt with a compaction offer.
///
/// [lastOfferedAt] is when an offer was last SHOWN, not when compaction last
/// ran: declining is an answer, and re-asking the next morning would make the
/// setting meaningless.
CompactionOfferVerdict compactionOfferVerdict({
  required CompactionEstimate estimate,
  required CompactionOfferSettings settings,
  required DateTime now,
  DateTime? lastOfferedAt,
}) {
  if (!settings.enabled) return CompactionOfferVerdict.disabled;
  if (lastOfferedAt != null && now.difference(lastOfferedAt) < settings.period) {
    return CompactionOfferVerdict.tooSoon;
  }
  if (estimate.reclaimableBytes < settings.thresholdBytes) {
    return CompactionOfferVerdict.belowThreshold;
  }
  return CompactionOfferVerdict.offer;
}

/// The identities a compaction must keep, in the order they were unlocked.
///
/// `compact_known` keeps ONLY the spaces whose passwords it is given and drops
/// every other one, so this list is the difference between a repack and a
/// deletion. Two rules it enforces, both from how identities really nest:
///
///  * the same identity can hang under two different masters, and it must be
///    compacted ONCE — a repeated password is not a second space;
///  * unlocking a master does NOT bring its subordinates. Each identity under
///    a master is its own space with its own password, and `compact_known`
///    keeps a space only when that space's own password is supplied — the
///    library's own test says so (`repack_drops_hidden_space_when_password_not_
///    supplied`). A master's password keeps the master and destroys every
///    child. What a master DOES give is the list of them, by keys, which is
///    what [CompactionRoster.expectSpaces] turns into a checklist nobody has
///    to remember.
/// Two constraints the collecting screen has to be built around, established
/// by reading the code rather than assumed:
///
///  * A password can only be CHECKED against a closed container. The store is
///    held under `LOCK_EX` while a session is up, which is why binding an
///    existing identity to a master tears the session down before it opens the
///    space by its own password. So passwords cannot be verified one at a time
///    while the app runs normally: the offer must tear down ONCE, collect and
///    verify inside that window, compact, and reopen.
///  * A space does not carry its node id. The stored profile holds a display
///    name and a claimed username; the node id is derived from the identity's
///    key material when its node starts. Listing unlocked identities "by
///    node_id" therefore needs that derivation, not a lookup — the number is
///    not sitting in the container waiting to be read.
class CompactionRoster {
  CompactionRoster();

  final Map<String, _RosterEntry> _byNodeId = {};

  /// Node ids in insertion order — what the offer lists back to the person.
  List<String> get nodeIds => _byNodeId.keys.toList(growable: false);

  int get length => _byNodeId.length;

  bool contains(String nodeId) => _byNodeId.containsKey(nodeId);

  /// Node ids that came from a typed password rather than from a master.
  List<String> get unlockedDirectly => [
    for (final e in _byNodeId.entries)
      if (e.value.viaMaster == null) e.key,
  ];

  /// The master a subordinate arrived under, if it did.
  String? masterOf(String nodeId) => _byNodeId[nodeId]?.viaMaster;

  /// Spaces this container is KNOWN to hold, learned from a master's roster.
  ///
  /// Keyed by space keys rather than by label, because the keys are what says
  /// "this is the same space": two masters can list one identity under two
  /// names, and renaming an identity must not make it look like a second one
  /// somebody forgot.
  final Map<String, String> _expected = {};

  /// Space keys a supplied password actually opened.
  final Set<String> _covered = {};

  /// Record what a master says lives in this container.
  void expectSpaces(Iterable<({String label, List<int> keys})> children) {
    for (final child in children) {
      final id = _hex(child.keys);
      if (id.isEmpty) continue;
      _expected.putIfAbsent(id, () => child.label);
    }
  }

  /// Record the space a supplied password opened, so the checklist can tick it.
  void coverSpace(List<int> keys) {
    final id = _hex(keys);
    if (id.isNotEmpty) _covered.add(id);
  }

  /// Identities this container is known to hold that NO supplied password
  /// opens — the ones a compaction would destroy.
  ///
  /// This is the whole of the safety story for a container with a master in
  /// it: the person cannot be asked to remember a list the app is already
  /// holding, and "I typed some passwords" is not the same claim as "every
  /// identity here is on the list".
  List<String> get uncovered => [
    for (final entry in _expected.entries)
      if (!_covered.contains(entry.key)) entry.value,
  ];

  /// Every identity this container is known to hold is on the list.
  bool get isComplete => uncovered.isEmpty;

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Add an identity the person unlocked by typing its password.
  ///
  /// [spaceKeys] is what the password opened — supplying it ticks that space
  /// off the checklist built by [expectSpaces]. Omitting it keeps the password
  /// but proves nothing about coverage.
  ///
  /// Returns false when it was already on the list — the same space reached
  /// through a second master, or simply typed twice. Compaction must not
  /// receive its password twice.
  bool addUnlocked(
    String nodeId, {
    required List<int> passwordBytes,
    List<int>? spaceKeys,
  }) {
    if (spaceKeys != null) coverSpace(spaceKeys);
    return _add(nodeId, passwordBytes: passwordBytes, viaMaster: null);
  }

  /// Add a subordinate that a master brought with it.
  bool addSubordinate(
    String nodeId, {
    required List<int> passwordBytes,
    required String master,
  }) => _add(nodeId, passwordBytes: passwordBytes, viaMaster: master);

  bool _add(
    String nodeId, {
    required List<int> passwordBytes,
    required String? viaMaster,
  }) {
    if (nodeId.isEmpty) return false;
    if (_byNodeId.containsKey(nodeId)) return false;
    _byNodeId[nodeId] = _RosterEntry(passwordBytes, viaMaster);
    return true;
  }

  /// The passwords to hand to `compact_known`, deduplicated.
  ///
  /// Deduplicated by BYTES as well as by node id: two identities under one
  /// master share its password, and passing it twice would ask the container
  /// to keep the same space twice.
  List<List<int>> passwords() {
    final out = <List<int>>[];
    final seen = <String>{};
    for (final e in _byNodeId.values) {
      final key = e.password.join(',');
      if (seen.add(key)) out.add(e.password);
    }
    return out;
  }
}

class _RosterEntry {
  const _RosterEntry(this.password, this.viaMaster);
  final List<int> password;
  final String? viaMaster;
}
