import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../core/ids.dart';
import '../data/node/space_discovery_transport.dart';
import '../domain/public_directory_pointer.dart';
import '../domain/space_discovery.dart' show SpacePublicSignatureVerifier;
import '../domain/space_discovery_carrier.dart'
    show kSpaceDiscoveryCarrierLifetime;

/// The persisted + live state of this identity's one public directory.
class PublicDirectoryStatus {
  const PublicDirectoryStatus({
    this.folderId,
    this.shareId,
    this.link,
    this.title,
    this.lastPublishedAtMs,
  });

  final String? folderId;
  final String? shareId;
  final String? link;
  final String? title;
  final int? lastPublishedAtMs;

  bool get isPublished => link != null;

  Map<String, Object?> toJson() => {
    if (folderId != null) 'folderId': folderId,
    if (shareId != null) 'shareId': shareId,
    if (link != null) 'link': link,
    if (title != null) 'title': title,
    if (lastPublishedAtMs != null) 'ts': lastPublishedAtMs,
  };

  static PublicDirectoryStatus? fromJson(Object? value) {
    if (value is! Map) return null;
    final link = value['link'];
    if (link is! String) return null;
    return PublicDirectoryStatus(
      folderId: value['folderId'] as String?,
      shareId: value['shareId'] as String?,
      link: link,
      title: value['title'] as String?,
      lastPublishedAtMs: value['ts'] as int?,
    );
  }
}

/// Publishes this identity's public file directory (a signed pointer to a
/// bearer folder link) and resolves anyone else's by nickname or nodeId.
///
/// One directory per identity: publishing replaces. The record lives on the
/// DHT for at most 2h, so a periodic republish keeps it alive while published.
/// Everything anonymity-relevant is delegated to the proven carrier + folder
/// share paths; this class only signs the pointer, keeps it fresh, and
/// verifies resolved records fail-closed.
class PublicDirectoryService {
  PublicDirectoryService({
    required SpaceDiscoveryTransport transport,
    required NodeId selfId,
    required Uint8List selfPublicKey,
    required ({Uint8List signature, Uint8List publicKey}) Function(Uint8List)
    sign,
    required SpacePublicSignatureVerifier verify,
    required Future<void> Function(String key, String value) putSetting,
    required Future<String?> Function(String key) getSetting,
    required Future<NodeId?> Function(String nickname) resolveNickname,
    Future<void> Function(String shareId)? revokeShare,
    DateTime Function()? now,
    Duration? republishEvery = const Duration(minutes: 90),
    Duration resolveTimeout = const Duration(seconds: 8),
    // ignore: prefer_initializing_formals
  }) : _transport = transport,
       // ignore: prefer_initializing_formals
       _selfId = selfId,
       _selfPublicKey = Uint8List.fromList(selfPublicKey),
       // ignore: prefer_initializing_formals
       _sign = sign,
       // ignore: prefer_initializing_formals
       _verify = verify,
       // ignore: prefer_initializing_formals
       _putSetting = putSetting,
       // ignore: prefer_initializing_formals
       _getSetting = getSetting,
       // ignore: prefer_initializing_formals
       _resolveNickname = resolveNickname,
       // ignore: prefer_initializing_formals
       _revokeShare = revokeShare,
       _now = now ?? DateTime.now,
       // ignore: prefer_initializing_formals
       _republishEvery = republishEvery,
       // ignore: prefer_initializing_formals
       _resolveTimeout = resolveTimeout;

  static const _settingKey = 'publicdir.published.v1';

  final SpaceDiscoveryTransport _transport;
  final NodeId _selfId;
  final Uint8List _selfPublicKey;
  final ({Uint8List signature, Uint8List publicKey}) Function(Uint8List) _sign;
  final SpacePublicSignatureVerifier _verify;
  final Future<void> Function(String, String) _putSetting;
  final Future<String?> Function(String) _getSetting;
  final Future<NodeId?> Function(String) _resolveNickname;
  final Future<void> Function(String shareId)? _revokeShare;
  final DateTime Function() _now;
  final Duration? _republishEvery;
  final Duration _resolveTimeout;

  PublicDirectoryStatus _status = const PublicDirectoryStatus();
  Timer? _timer;
  bool _started = false;
  bool _closed = false;

  PublicDirectoryStatus get status => _status;

  /// Load persisted state and, if published, republish now + arm the timer.
  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    final raw = await _getSetting(_settingKey);
    if (raw != null) {
      try {
        final restored = PublicDirectoryStatus.fromJson(jsonDecode(raw));
        if (restored != null) _status = restored;
      } catch (_) {}
    }
    if (_status.isPublished) {
      await _republish();
      _armTimer();
    }
  }

  /// Publish [link] (a bearer folder share for [folderId]) under this
  /// identity, replacing any existing directory. On success the PREVIOUS
  /// directory's folder share is revoked here so it stops serving bytes — the
  /// caller only needs to revoke [shareId] itself if this returns false.
  /// Returns false (state untouched) if signing/publishing failed.
  Future<bool> publish({
    required String folderId,
    required String shareId,
    required String link,
    required String title,
  }) async {
    if (_closed) return false;
    final previous = _status;
    final next = PublicDirectoryStatus(
      folderId: folderId,
      shareId: shareId,
      link: link,
      title: title,
      lastPublishedAtMs: _now().millisecondsSinceEpoch,
    );
    final ok = await _publishRecord(next);
    if (!ok) return false;
    _status = next;
    await _persist();
    _armTimer();
    if (previous.shareId != null && previous.shareId != shareId) {
      await _revoke(previous.shareId!);
    }
    return true;
  }

  /// Stop publishing and revoke the underlying folder share so it no longer
  /// serves bytes. The DHT pointer record itself simply expires (there is no
  /// delete) within its ≤2h lifetime; nothing re-publishes it after this.
  Future<PublicDirectoryStatus> withdraw() async {
    final previous = _status;
    _timer?.cancel();
    _timer = null;
    _status = const PublicDirectoryStatus();
    await _persist();
    if (previous.shareId != null) {
      await _revoke(previous.shareId!);
    }
    return previous;
  }

  /// Re-list nothing here — just republish the CURRENT link with a fresh
  /// signature/lifetime so it survives the 2h cap. No-op when not published.
  Future<void> republishNow() async {
    if (_status.isPublished) await _republish();
  }

  /// Resolve a nickname to its owner's published directory, or null if the
  /// name is unclaimed / has no live, valid directory record.
  Future<PublicDirectoryPointer?> resolveByNickname(String nickname) async {
    final owner = await _resolveNickname(nickname.trim());
    if (owner == null) return null;
    return resolveByNodeId(owner);
  }

  /// Resolve a known owner nodeId to their published directory.
  Future<PublicDirectoryPointer?> resolveByNodeId(NodeId owner) async {
    final List<Uint8List> records;
    try {
      records = await _transport.resolve(
        publicDirectoryRoute(owner),
        timeout: _resolveTimeout,
      );
    } catch (_) {
      return null;
    }
    final nowMs = _now().millisecondsSinceEpoch;
    PublicDirectoryPointer? best;
    for (final record in records) {
      final pointer = parsePublicDirectoryRecord(
        bytes: record,
        expectedOwner: owner,
        nowMs: nowMs,
        verify: _verify,
      );
      if (pointer == null) continue;
      if (best == null || pointer.issuedAtUnixMs > best.issuedAtUnixMs) {
        best = pointer;
      }
    }
    return best;
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _republish() async {
    if (_closed) return;
    final current = _status;
    if (!current.isPublished) return;
    final refreshed = PublicDirectoryStatus(
      folderId: current.folderId,
      shareId: current.shareId,
      link: current.link,
      title: current.title,
      lastPublishedAtMs: _now().millisecondsSinceEpoch,
    );
    if (await _publishRecord(refreshed)) {
      _status = refreshed;
      await _persist();
    }
  }

  Future<void> _revoke(String shareId) async {
    try {
      await _revokeShare?.call(shareId);
    } catch (_) {}
  }

  Future<bool> _publishRecord(PublicDirectoryStatus state) async {
    final link = state.link;
    if (link == null) return false;
    try {
      final issued = _now().millisecondsSinceEpoch;
      final record = signPublicDirectoryRecord(
        owner: _selfId,
        ownerPublicKey: _selfPublicKey,
        title: state.title ?? '',
        link: link,
        issuedAtUnixMs: issued,
        expiresAtUnixMs:
            issued + kSpaceDiscoveryCarrierLifetime.inMilliseconds,
        sign: _sign,
      );
      await _transport.publish(record);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _armTimer() {
    _timer?.cancel();
    final every = _republishEvery;
    if (every == null || _closed) return;
    _timer = Timer.periodic(every, (_) => unawaited(_republish()));
  }

  Future<void> _persist() =>
      _putSetting(_settingKey, jsonEncode(_status.toJson()));
}
