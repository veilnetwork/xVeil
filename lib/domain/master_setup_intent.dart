import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import '../core/secret_wipe.dart';
import 'roster.dart';
import 'storage_locator.dart';

const kMasterSetupJournalFile = 'master.setup.intent.v1';

enum MasterSetupFailureKind { invalid, conflict, unavailable }

final class MasterSetupFailure implements Exception {
  const MasterSetupFailure(this.kind);
  final MasterSetupFailureKind kind;
  @override
  String toString() => 'MasterSetupFailure(${kind.name})';
}

/// Protected creation intent, never catalog or preference metadata. Owns all
/// key buffers. The planned local child locator is chosen BEFORE child creation;
/// a later step attaches its actual keys before writing personalized payloads.
final class MasterSetupIntent {
  MasterSetupIntent._(
    this.root,
    this._owner,
    this._base,
    this.childLocator,
    this.childLabel,
    this.childAnonymous,
    this._childKeys,
    this.append,
    this._attempt,
  );

  static const maxBytes = 16 * 1024;
  static const maxBaseEntries = 32;
  // Above the number of minimum-size rows fitting the existing roster-file
  // ceiling. Append metadata never duplicates the roster's payload.
  static const maxAppendEntries = 65536;
  final IdentityStorageLocator root, childLocator;
  final String childLabel;
  final bool childAnonymous;
  final bool append;
  final Uint8List _owner;
  final List<RosterEntry> _base;
  final Uint8List? _childKeys;
  final Uint8List? _attempt;
  bool _destroyed = false;

  factory MasterSetupIntent.create({
    required IdentityStorageLocator root,
    required Uint8List keys,
    required List<RosterEntry> base,
    required IdentityStorageLocator childLocator,
    required String childLabel,
    bool childAnonymous = false,
    bool append = false,
  }) {
    if (keys.length != 64) {
      throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
    }
    final owner = Uint8List.fromList(sha256.convert(keys).bytes);
    final random = Random.secure();
    final attempt = Uint8List.fromList(
      List.generate(16, (_) => random.nextInt(256)),
    );
    try {
      return _build(
        root,
        owner,
        base,
        childLocator,
        childLabel,
        childAnonymous,
        null,
        append,
        attempt,
      );
    } finally {
      wipeSecretBytes(owner);
      wipeSecretBytes(attempt);
    }
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static bool _label(String value) =>
      value.trim().isNotEmpty &&
      value.length <= 256 &&
      !value.contains('\x00') &&
      utf8.encode(value).length <= 1024 &&
      utf8.decode(utf8.encode(value)) == value;

  static MasterSetupIntent _build(
    IdentityStorageLocator root,
    Uint8List owner,
    List<RosterEntry> base,
    IdentityStorageLocator childLocator,
    String childLabel,
    bool anonymous,
    Uint8List? childKeys,
    bool append,
    Uint8List? attempt,
  ) {
    if (owner.length != 32 ||
        base.isEmpty ||
        base.length > (append ? maxAppendEntries : maxBaseEntries) ||
        !_label(childLabel) ||
        childKeys != null && childKeys.length != 64 ||
        attempt != null && attempt.length != 16) {
      throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
    }
    final labels = <String>{childLabel};
    final ids = <ManagedIdentityId>{
      if (root case ManagedStorageLocator(:final id)) id,
    };
    if (childLocator case ManagedStorageLocator(:final id)) {
      if (!ids.add(id)) {
        throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
      }
    }
    final seenKeys = <String>{};
    for (final row in base) {
      if (!(append
              ? row.label.isNotEmpty &&
                    utf8.decode(utf8.encode(row.label)) == row.label
              : _label(row.label)) ||
          !labels.add(row.label) ||
          row.spaceKeys.length != 64 ||
          _same(owner, sha256.convert(row.spaceKeys).bytes) ||
          !seenKeys.add(sha256.convert(row.spaceKeys).toString())) {
        throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
      }
      if (row.storageLocator case ManagedStorageLocator(:final id)) {
        if (!ids.add(id)) {
          throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
        }
      }
    }
    if (childKeys != null &&
        (_same(owner, sha256.convert(childKeys).bytes) ||
            seenKeys.contains(sha256.convert(childKeys).toString()))) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    final result = MasterSetupIntent._(
      root,
      Uint8List.fromList(owner),
      List.unmodifiable([
        for (final row in base)
          row.copyWith(spaceKeys: Uint8List.fromList(row.spaceKeys)),
      ]),
      childLocator,
      childLabel,
      anonymous,
      childKeys == null ? null : Uint8List.fromList(childKeys),
      append,
      attempt == null ? null : Uint8List.fromList(attempt),
    );
    try {
      final check = result.encode();
      wipeSecretBytes(check);
      return result;
    } catch (_) {
      result.destroy();
      rethrow;
    }
  }

  void _live() {
    if (_destroyed) {
      throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
    }
  }

  bool get childKnown {
    _live();
    return _childKeys != null;
  }

  String? get attemptId {
    _live();
    return _attempt == null ? null : base64.encode(_attempt);
  }

  List<RosterEntry> copyBase() {
    _live();
    return [
      for (final row in _base)
        row.copyWith(spaceKeys: Uint8List.fromList(row.spaceKeys)),
    ];
  }

  List<RosterEntry> copyRoster() {
    _live();
    if (_childKeys == null) {
      throw const MasterSetupFailure(MasterSetupFailureKind.unavailable);
    }
    return [
      ...copyBase(),
      RosterEntry(
        label: childLabel,
        spaceKeys: Uint8List.fromList(_childKeys),
        anonymous: childAnonymous,
        storageLocator: childLocator,
      ),
    ];
  }

  MasterSetupIntent withChildKeys(Uint8List keys) {
    _live();
    if (_childKeys != null && !_same(_childKeys, keys)) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
    return _build(
      root,
      _owner,
      _base,
      childLocator,
      childLabel,
      childAnonymous,
      keys,
      append,
      _attempt,
    );
  }

  MasterSetupIntent copy() {
    _live();
    return _build(
      root,
      _owner,
      _base,
      childLocator,
      childLabel,
      childAnonymous,
      _childKeys,
      append,
      _attempt,
    );
  }

  static Map<String, Object> _row(RosterEntry e) => {
    'label': e.label,
    'keys': base64.encode(e.spaceKeys),
    'anonymous': e.anonymous,
    'locator': e.storageLocator.encode(),
  };

  static Uint8List _baseDigest(List<RosterEntry> rows) {
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode([for (final row in rows) _row(row)])),
    );
    try {
      return Uint8List.fromList(sha256.convert(bytes).bytes);
    } finally {
      wipeSecretBytes(bytes);
    }
  }

  static bool requiresRoster(Uint8List bytes) {
    try {
      if (bytes.isEmpty || bytes.length > maxBytes) {
        throw const FormatException();
      }
      final m = jsonDecode(utf8.decode(bytes));
      return m is Map && m['v'] == 2 && m['operation'] == 'append';
    } catch (_) {
      throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
    }
  }

  void validateOwner(IdentityStorageLocator actualRoot, Uint8List keys) {
    _live();
    if (keys.length != 64 ||
        root != actualRoot ||
        !_same(_owner, sha256.convert(keys).bytes)) {
      throw const MasterSetupFailure(MasterSetupFailureKind.conflict);
    }
  }

  bool same(MasterSetupIntent other, {bool planOnly = false}) {
    Uint8List? left, right;
    try {
      left = _encode(planOnly);
      right = other._encode(planOnly);
      return _same(left, right);
    } finally {
      if (left != null) wipeSecretBytes(left);
      if (right != null) wipeSecretBytes(right);
    }
  }

  Uint8List encode() => _encode(false);
  Uint8List _encode(bool planOnly) {
    _live();
    final digest = append ? _baseDigest(_base) : null;
    try {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'v': append ? 2 : 1,
            if (append) 'operation': 'append',
            'root': root.encode(),
            'owner': base64.encode(_owner),
            if (_attempt != null) 'attempt': base64.encode(_attempt),
            'base': append
                ? {'count': _base.length, 'digest': base64.encode(digest!)}
                : [for (final e in _base) _row(e)],
            'child': {
              'label': childLabel,
              'anonymous': childAnonymous,
              'locator': childLocator.encode(),
              'keys': planOnly || _childKeys == null
                  ? null
                  : base64.encode(_childKeys),
            },
          }),
        ),
      );
      if (bytes.length > maxBytes) {
        wipeSecretBytes(bytes);
        throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
      }
      return bytes;
    } finally {
      if (digest != null) wipeSecretBytes(digest);
    }
  }

  factory MasterSetupIntent.decode(
    Uint8List bytes, {
    List<RosterEntry>? roster,
  }) {
    final buffers = <Uint8List>[];
    bool shape(Object? value, Set<String> keys) =>
        value is Map<String, dynamic> &&
        value.length == keys.length &&
        value.keys.every(keys.contains);
    Uint8List decodeKey(Object? raw, int size) {
      if (raw is! String || raw.length > 88) throw const FormatException();
      final key = base64.decode(raw);
      buffers.add(key);
      if (key.length != size || base64.encode(key) != raw) {
        throw const FormatException();
      }
      return key;
    }

    try {
      if (bytes.isEmpty || bytes.length > maxBytes) {
        throw const FormatException();
      }
      final m = jsonDecode(utf8.decode(bytes));
      final append = m is Map && m['v'] == 2 && m['operation'] == 'append';
      final hasAttempt = m is Map && m.containsKey('attempt');
      if (!shape(m, {
            'v',
            'root',
            'owner',
            'base',
            'child',
            if (append) 'operation',
            if (hasAttempt) 'attempt',
          }) ||
          m['v'] is! int ||
          m['v'] != (append ? 2 : 1) ||
          !shape(m['child'], {'label', 'anonymous', 'locator', 'keys'})) {
        throw const FormatException();
      }
      final rows = <RosterEntry>[];
      if (append) {
        final base = m['base'];
        if (!shape(base, {'count', 'digest'}) ||
            base['count'] is! int ||
            base['count'] < 1 ||
            base['count'] > maxAppendEntries ||
            roster == null ||
            (roster.length != base['count'] &&
                roster.length != base['count'] + 1)) {
          throw const FormatException();
        }
        rows.addAll(roster.take(base['count'] as int));
        final digest = _baseDigest(rows);
        buffers.add(digest);
        if (!_same(digest, decodeKey(base['digest'], 32))) {
          throw const FormatException();
        }
      } else {
        if (m['base'] is! List ||
            (m['base'] as List).isEmpty ||
            (m['base'] as List).length > maxBaseEntries) {
          throw const FormatException();
        }
        for (final row in m['base'] as List) {
          if (!shape(row, {'label', 'keys', 'anonymous', 'locator'}) ||
              row['label'] is! String ||
              row['anonymous'] is! bool) {
            throw const FormatException();
          }
          rows.add(
            RosterEntry(
              label: row['label'],
              spaceKeys: decodeKey(row['keys'], 64),
              anonymous: row['anonymous'],
              storageLocator: IdentityStorageLocator.decode(row['locator']),
            ),
          );
        }
      }
      final child = m['child'];
      if (child['label'] is! String || child['anonymous'] is! bool) {
        throw const FormatException();
      }
      final childLocator = IdentityStorageLocator.decode(child['locator']);
      final childKeys = child['keys'] == null
          ? null
          : decodeKey(child['keys'], 64);
      if (append && roster!.length == rows.length + 1) {
        final last = roster.last;
        if (childKeys == null ||
            last.label != child['label'] ||
            last.anonymous != child['anonymous'] ||
            last.storageLocator != childLocator ||
            !_same(last.spaceKeys, childKeys)) {
          throw const FormatException();
        }
      }
      return _build(
        IdentityStorageLocator.decode(m['root']),
        decodeKey(m['owner'], 32),
        rows,
        childLocator,
        child['label'],
        child['anonymous'],
        childKeys,
        append,
        hasAttempt ? decodeKey(m['attempt'], 16) : null,
      );
    } catch (_) {
      throw const MasterSetupFailure(MasterSetupFailureKind.invalid);
    } finally {
      for (final b in buffers) {
        wipeSecretBytes(b);
      }
    }
  }

  void destroy() {
    wipeSecretBytes(_owner);
    for (final row in _base) {
      wipeSecretBytes(row.spaceKeys);
    }
    if (_childKeys != null) wipeSecretBytes(_childKeys);
    if (_attempt != null) wipeSecretBytes(_attempt);
    _destroyed = true;
  }
}
