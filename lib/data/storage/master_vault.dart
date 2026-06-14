import 'dart:convert';
import 'dart:typed_data';

import 'kv_log_store.dart';

/// A reference to one child space (an Identity's container), held inside a
/// master vault. The [password] is the child's unlock secret — safe here
/// because the master space is itself encrypted under the master password.
class ChildSpaceRef {
  const ChildSpaceRef({
    required this.label,
    required this.containerPath,
    required this.password,
  });

  final String label;
  final String containerPath;
  final Uint8List password;

  Map<String, dynamic> _toJson() => {
        'label': label,
        'path': containerPath,
        'pw': base64.encode(password),
      };

  static ChildSpaceRef _fromJson(Map<String, dynamic> m) => ChildSpaceRef(
        label: m['label'] as String,
        containerPath: m['path'] as String,
        password: base64.decode(m['pw'] as String),
      );
}

/// An optional "master space" that unlocks several child spaces with one
/// password — the app-layer construct hidden-volume itself does not provide
/// (each password unlocks exactly one space). There can be zero or many master
/// vaults; this wraps one already-unlocked master space [KvLogStore].
///
/// hidden-volume exposes no KV key enumeration, so child labels are tracked in
/// an explicit index key, updated atomically with each child entry.
class MasterVault {
  MasterVault(this._store);

  final KvLogStore _store;

  static const int _ns = Ns.settings;
  static const String _indexKey = 'mv:index';
  static String _childKey(String label) => 'mv:child:$label';

  Uint8List _k(String s) => Uint8List.fromList(utf8.encode(s));

  List<String> _labels() {
    final raw = _store.get(_ns, _k(_indexKey));
    if (raw == null) return [];
    return (jsonDecode(utf8.decode(raw)) as List).cast<String>();
  }

  /// Add or replace a child reference (atomic: child entry + index).
  void addChild(ChildSpaceRef ref) {
    final labels = _labels();
    if (!labels.contains(ref.label)) labels.add(ref.label);
    _store.commit([
      PutOp(_ns, _k(_childKey(ref.label)),
          _k(jsonEncode(ref._toJson()))),
      PutOp(_ns, _k(_indexKey), _k(jsonEncode(labels))),
    ]);
  }

  ChildSpaceRef? getChild(String label) {
    final raw = _store.get(_ns, _k(_childKey(label)));
    if (raw == null) return null;
    return ChildSpaceRef._fromJson(
        jsonDecode(utf8.decode(raw)) as Map<String, dynamic>);
  }

  List<ChildSpaceRef> listChildren() {
    final out = <ChildSpaceRef>[];
    for (final label in _labels()) {
      final c = getChild(label);
      if (c != null) out.add(c);
    }
    return out;
  }

  /// Remove a child reference (atomic: delete entry + update index).
  void removeChild(String label) {
    final labels = _labels()..remove(label);
    _store.commit([
      DeleteOp(_ns, _k(_childKey(label))),
      PutOp(_ns, _k(_indexKey), _k(jsonEncode(labels))),
    ]);
  }
}
