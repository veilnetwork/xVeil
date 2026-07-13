import 'dart:convert';
import 'dart:typed_data';

import 'package:characters/characters.dart';

import '../core/ids.dart';
import 'cloud_document.dart';

const cloudRichTextCodecV1 = 'xveil.note.rga.v1';
const cloudRichTextOperationType = 'rt.v1';

const int _maxInsertGraphemes = 65536;
const int _maxTargets = 65536;
final RegExp _operationIdPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _atomIdPattern = RegExp(r'^([0-9a-f]{64}):([0-9]{1,5})$');

enum CloudRichTextBlock {
  paragraph,
  heading1,
  heading2,
  quote,
  bullet,
  code;

  static CloudRichTextBlock? fromName(String? value) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }
}

/// Exact formatting register for one or more sequence atoms.
///
/// Formatting operations replace this complete value. That makes removing a
/// mark as deterministic as adding it and avoids nullable/toggle semantics
/// whose result would depend on delivery order.
class CloudRichTextStyle {
  const CloudRichTextStyle({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.inlineCode = false,
    this.block = CloudRichTextBlock.paragraph,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool inlineCode;
  final CloudRichTextBlock block;

  bool get isPlain =>
      !bold &&
      !italic &&
      !underline &&
      !strike &&
      !inlineCode &&
      block == CloudRichTextBlock.paragraph;

  CloudRichTextStyle copyWith({
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strike,
    bool? inlineCode,
    CloudRichTextBlock? block,
  }) => CloudRichTextStyle(
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    inlineCode: inlineCode ?? this.inlineCode,
    block: block ?? this.block,
  );

  Map<String, Object> toJson() => {
    if (bold) 'b': true,
    if (italic) 'i': true,
    if (underline) 'u': true,
    if (strike) 's': true,
    if (inlineCode) 'c': true,
    if (block != CloudRichTextBlock.paragraph) 'p': block.name,
  };

  static CloudRichTextStyle? fromJson(Object? value) {
    if (value is! Map || value.length > 6) return null;
    const flags = {'b', 'i', 'u', 's', 'c'};
    for (final entry in value.entries) {
      if (entry.key is! String ||
          (!flags.contains(entry.key) && entry.key != 'p')) {
        return null;
      }
      if (flags.contains(entry.key) && entry.value is! bool) return null;
    }
    final rawBlock = value['p'];
    final block = rawBlock == null
        ? CloudRichTextBlock.paragraph
        : CloudRichTextBlock.fromName(rawBlock is String ? rawBlock : null);
    if (block == null) return null;
    return CloudRichTextStyle(
      bold: value['b'] == true,
      italic: value['i'] == true,
      underline: value['u'] == true,
      strike: value['s'] == true,
      inlineCode: value['c'] == true,
      block: block,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CloudRichTextStyle &&
      bold == other.bold &&
      italic == other.italic &&
      underline == other.underline &&
      strike == other.strike &&
      inlineCode == other.inlineCode &&
      block == other.block;

  @override
  int get hashCode =>
      Object.hash(bold, italic, underline, strike, inlineCode, block);
}

enum CloudRichTextEditKind {
  insert,
  delete,
  format,
  documentDelete,
  checkpoint,
  merge,
}

/// Strict bounded cleartext payload encrypted by the document epoch layer.
class CloudRichTextEdit {
  const CloudRichTextEdit._({
    required this.kind,
    this.afterAtomId,
    this.text,
    this.style,
    this.targetAtomIds = const [],
    this.insertStyles = const [],
    this.checkpointStyles = const [],
  });

  factory CloudRichTextEdit.insert({
    required String? afterAtomId,
    required String text,
    CloudRichTextStyle style = const CloudRichTextStyle(),
  }) => CloudRichTextEdit._(
    kind: CloudRichTextEditKind.insert,
    afterAtomId: afterAtomId,
    text: text,
    insertStyles: List.filled(text.characters.length, style),
  );

  factory CloudRichTextEdit.insertStyled({
    required String? afterAtomId,
    required String text,
    required List<CloudRichTextStyle> styles,
  }) => CloudRichTextEdit._(
    kind: CloudRichTextEditKind.insert,
    afterAtomId: afterAtomId,
    text: text,
    insertStyles: List.unmodifiable(styles),
  );

  factory CloudRichTextEdit.delete(Iterable<String> targetAtomIds) =>
      CloudRichTextEdit._(
        kind: CloudRichTextEditKind.delete,
        targetAtomIds: List.unmodifiable(targetAtomIds),
      );

  factory CloudRichTextEdit.format({
    required Iterable<String> targetAtomIds,
    required CloudRichTextStyle style,
  }) => CloudRichTextEdit._(
    kind: CloudRichTextEditKind.format,
    targetAtomIds: List.unmodifiable(targetAtomIds),
    style: style,
  );

  const CloudRichTextEdit.documentDelete()
    : this._(kind: CloudRichTextEditKind.documentDelete);

  factory CloudRichTextEdit.checkpoint({
    required String text,
    required List<CloudRichTextStyle> styles,
  }) => CloudRichTextEdit._(
    kind: CloudRichTextEditKind.checkpoint,
    text: text,
    checkpointStyles: List.unmodifiable(styles),
  );

  const CloudRichTextEdit.merge() : this._(kind: CloudRichTextEditKind.merge);

  final CloudRichTextEditKind kind;
  final String? afterAtomId;
  final String? text;
  final CloudRichTextStyle? style;
  final List<String> targetAtomIds;
  final List<CloudRichTextStyle> insertStyles;
  final List<CloudRichTextStyle> checkpointStyles;

  Uint8List encode() {
    final value = <String, Object?>{'v': 1, 'k': kind.name};
    switch (kind) {
      case CloudRichTextEditKind.insert:
        value['after'] = afterAtomId;
        value['text'] = text;
        value['runs'] = _encodeStyleRuns(insertStyles);
        break;
      case CloudRichTextEditKind.delete:
        value['ids'] = targetAtomIds;
        break;
      case CloudRichTextEditKind.format:
        value['ids'] = targetAtomIds;
        value['style'] = style!.toJson();
        break;
      case CloudRichTextEditKind.documentDelete:
        break;
      case CloudRichTextEditKind.checkpoint:
        value['text'] = text;
        value['runs'] = _encodeStyleRuns(checkpointStyles);
        break;
      case CloudRichTextEditKind.merge:
        break;
    }
    return Uint8List.fromList(utf8.encode(jsonEncode(value)));
  }

  static CloudRichTextEdit? decode(Uint8List bytes) {
    try {
      final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      if (value is! Map || value['v'] != 1 || value['k'] is! String) {
        return null;
      }
      final kind = CloudRichTextEditKind.values
          .where((candidate) => candidate.name == value['k'])
          .firstOrNull;
      if (kind == null) return null;
      switch (kind) {
        case CloudRichTextEditKind.insert:
          if (value.length != 5) return null;
          final after = value['after'];
          final text = value['text'];
          final graphemes = text is String ? text.characters.length : -1;
          final styles = _decodeStyleRuns(value['runs'], graphemes);
          if ((after != null && !_validAtomId(after)) ||
              text is! String ||
              text.isEmpty ||
              graphemes > _maxInsertGraphemes ||
              styles == null) {
            return null;
          }
          return CloudRichTextEdit.insertStyled(
            afterAtomId: after as String?,
            text: text,
            styles: styles,
          );
        case CloudRichTextEditKind.delete:
          if (value.length != 3) return null;
          final ids = _parseTargets(value['ids']);
          if (ids == null || ids.isEmpty) return null;
          return CloudRichTextEdit.delete(ids);
        case CloudRichTextEditKind.format:
          if (value.length != 4) return null;
          final ids = _parseTargets(value['ids']);
          final style = CloudRichTextStyle.fromJson(value['style']);
          if (ids == null || ids.isEmpty || style == null) return null;
          return CloudRichTextEdit.format(targetAtomIds: ids, style: style);
        case CloudRichTextEditKind.documentDelete:
          return value.length == 2
              ? const CloudRichTextEdit.documentDelete()
              : null;
        case CloudRichTextEditKind.checkpoint:
          if (value.length != 4 || value['text'] is! String) return null;
          final text = value['text'] as String;
          final graphemes = text.characters.length;
          if (graphemes > _maxInsertGraphemes) return null;
          final styles = _decodeStyleRuns(value['runs'], graphemes);
          if (styles == null) return null;
          return CloudRichTextEdit.checkpoint(text: text, styles: styles);
        case CloudRichTextEditKind.merge:
          return value.length == 2 ? const CloudRichTextEdit.merge() : null;
      }
    } catch (_) {
      return null;
    }
  }
}

List<Object> _encodeStyleRuns(List<CloudRichTextStyle> styles) {
  final runs = <Object>[];
  for (final style in styles) {
    final code = _styleCode(style);
    if (runs.isNotEmpty) {
      final prior = runs.last as List<Object>;
      if (prior[1] == code) {
        prior[0] = (prior[0] as int) + 1;
        continue;
      }
    }
    runs.add(<Object>[1, code]);
  }
  return runs;
}

List<CloudRichTextStyle>? _decodeStyleRuns(Object? value, int expected) {
  if (value is! List || value.length > _maxTargets) return null;
  final result = <CloudRichTextStyle>[];
  for (final raw in value) {
    if (raw is! List || raw.length != 2 || raw[0] is! int) return null;
    final count = raw[0] as int;
    final style = raw[1] is int ? _styleFromCode(raw[1] as int) : null;
    if (count <= 0 || style == null || result.length + count > expected) {
      return null;
    }
    result.addAll(List.filled(count, style));
  }
  return result.length == expected ? result : null;
}

int _styleCode(CloudRichTextStyle style) =>
    (style.bold ? 1 : 0) |
    (style.italic ? 2 : 0) |
    (style.underline ? 4 : 0) |
    (style.strike ? 8 : 0) |
    (style.inlineCode ? 16 : 0) |
    (style.block.index << 5);

CloudRichTextStyle? _styleFromCode(int code) {
  final blockIndex = code >> 5;
  if (code < 0 || code >= CloudRichTextBlock.values.length << 5) {
    return null;
  }
  return CloudRichTextStyle(
    bold: code & 1 != 0,
    italic: code & 2 != 0,
    underline: code & 4 != 0,
    strike: code & 8 != 0,
    inlineCode: code & 16 != 0,
    block: CloudRichTextBlock.values[blockIndex],
  );
}

bool _validAtomId(Object? value) =>
    value is String && _atomIdPattern.hasMatch(value);

List<String>? _parseTargets(Object? value) {
  if (value is! List || value.length > _maxTargets) return null;
  final result = value.whereType<String>().toList();
  if (result.length != value.length ||
      result.any((id) => !_validAtomId(id)) ||
      result.toSet().length != result.length) {
    return null;
  }
  final sorted = [...result]..sort();
  for (var index = 0; index < result.length; index++) {
    if (result[index] != sorted[index]) return null;
  }
  return result;
}

class CloudRichTextAtomView {
  const CloudRichTextAtomView({
    required this.id,
    required this.value,
    required this.style,
  });

  final String id;
  final String value;
  final CloudRichTextStyle style;
}

class CloudRichTextSpan {
  const CloudRichTextSpan({required this.text, required this.style});

  final String text;
  final CloudRichTextStyle style;
}

class CloudRichTextSnapshot {
  const CloudRichTextSnapshot({
    required this.atoms,
    required this.spans,
    required this.headOperationIds,
    required this.invalidOperationIds,
    required this.unavailableOperationIds,
    required this.hasDocumentDelete,
    required this.hasConcurrentRecovery,
  });

  final List<CloudRichTextAtomView> atoms;
  final List<CloudRichTextSpan> spans;
  final List<String> headOperationIds;
  final List<String> invalidOperationIds;
  final List<String> unavailableOperationIds;
  final bool hasDocumentDelete;
  final bool hasConcurrentRecovery;

  String get text => atoms.map((atom) => atom.value).join();
  bool get isDeleted => hasDocumentDelete && atoms.isEmpty;
}

class _Atom {
  _Atom({
    required this.id,
    required this.operationId,
    required this.after,
    required this.value,
    required this.style,
    required this.rank,
  });

  final String id;
  final String operationId;
  final String? after;
  final String value;
  CloudRichTextStyle style;
  final int rank;
  bool deleted = false;
}

/// Deterministically materializes the authenticated operation set.
///
/// A document-delete only tombstones atoms whose insert operation is in its
/// causal past. An insert unknown to the deleting replica is concurrent and
/// therefore remains visible and explicitly reported as recovered content.
CloudRichTextSnapshot materializeCloudRichText({
  required Iterable<CloudDocumentOperation> operations,
  required Map<String, Uint8List> cleartextByOperationId,
  required NodeId checkpointOwner,
}) {
  final relevant = <String, CloudDocumentOperation>{};
  for (final operation in operations) {
    if (operation.opType == cloudRichTextOperationType &&
        _operationIdPattern.hasMatch(operation.operationId)) {
      relevant[operation.operationId] = operation;
    }
  }
  final ordered = _topologicalOperations(relevant);
  final ranks = <String, int>{};
  final operationChildren = <String, Set<String>>{};
  for (final operation in ordered) {
    var rank = 0;
    for (final parent in operation.parentOperationIds) {
      if (!relevant.containsKey(parent)) continue;
      rank = rank > (ranks[parent] ?? 0) ? rank : (ranks[parent] ?? 0);
      operationChildren
          .putIfAbsent(parent, () => {})
          .add(operation.operationId);
    }
    ranks[operation.operationId] = rank + 1;
  }
  final causalPastCache = <String, Set<String>>{};
  Set<String> causalPast(String operationId) =>
      causalPastCache.putIfAbsent(operationId, () {
        final seen = <String>{};
        final pending = <String>[...?relevant[operationId]?.parentOperationIds];
        while (pending.isNotEmpty) {
          final candidate = pending.removeLast();
          if (!seen.add(candidate)) continue;
          pending.addAll(relevant[candidate]?.parentOperationIds ?? const []);
        }
        return seen;
      });
  final causalFutureCache = <String, Set<String>>{};
  Set<String> causalFuture(String operationId) =>
      causalFutureCache.putIfAbsent(operationId, () {
        final seen = <String>{};
        final pending = <String>[...operationChildren[operationId] ?? const {}];
        while (pending.isNotEmpty) {
          final candidate = pending.removeLast();
          if (!seen.add(candidate)) continue;
          pending.addAll(operationChildren[candidate] ?? const {});
        }
        return seen;
      });

  final atoms = <String, _Atom>{};
  final invalid = <String>[];
  final unavailable = <String>[];
  final documentDeletes = <String>[];
  final checkpoints = <String>[];
  for (final operation in ordered) {
    final bytes = cleartextByOperationId[operation.operationId];
    if (bytes == null) {
      unavailable.add(operation.operationId);
      continue;
    }
    final edit = CloudRichTextEdit.decode(bytes);
    if (edit == null) {
      invalid.add(operation.operationId);
      continue;
    }
    switch (edit.kind) {
      case CloudRichTextEditKind.insert:
        if (edit.afterAtomId != null && !atoms.containsKey(edit.afterAtomId)) {
          invalid.add(operation.operationId);
          continue;
        }
        var after = edit.afterAtomId;
        var offset = 0;
        for (final grapheme in edit.text!.characters) {
          final id = '${operation.operationId}:$offset';
          atoms[id] = _Atom(
            id: id,
            operationId: operation.operationId,
            after: after,
            value: grapheme,
            style: edit.insertStyles[offset],
            rank: ranks[operation.operationId]!,
          );
          after = id;
          offset++;
        }
        break;
      case CloudRichTextEditKind.delete:
        if (edit.targetAtomIds.any((id) => !atoms.containsKey(id))) {
          invalid.add(operation.operationId);
          continue;
        }
        for (final id in edit.targetAtomIds) {
          atoms[id]!.deleted = true;
        }
        break;
      case CloudRichTextEditKind.format:
        if (edit.targetAtomIds.any((id) => !atoms.containsKey(id))) {
          invalid.add(operation.operationId);
          continue;
        }
        for (final id in edit.targetAtomIds) {
          atoms[id]!.style = edit.style!;
        }
        break;
      case CloudRichTextEditKind.documentDelete:
        documentDeletes.add(operation.operationId);
        final causal = causalPast(operation.operationId);
        for (final atom in atoms.values) {
          if (causal.contains(atom.operationId)) atom.deleted = true;
        }
        break;
      case CloudRichTextEditKind.checkpoint:
        if (operation.author != checkpointOwner) {
          invalid.add(operation.operationId);
          continue;
        }
        checkpoints.add(operation.operationId);
        var after = null as String?;
        var offset = 0;
        for (final grapheme in edit.text!.characters) {
          final id = '${operation.operationId}:$offset';
          atoms[id] = _Atom(
            id: id,
            operationId: operation.operationId,
            after: after,
            value: grapheme,
            style: edit.checkpointStyles[offset],
            rank: ranks[operation.operationId]!,
          );
          after = id;
          offset++;
        }
        break;
      case CloudRichTextEditKind.merge:
        break;
    }
  }

  // Epoch checkpoints replace the complete owner-signed prior epoch even if
  // some old heads were not named as parents (the wire parent cap is 32) or
  // were processed after the checkpoint's lexicographic tie-break.
  for (final checkpointId in checkpoints) {
    final checkpoint = relevant[checkpointId]!;
    final causal = causalPast(checkpointId);
    for (final atom in atoms.values) {
      if (atom.operationId == checkpointId) continue;
      final insertion = relevant[atom.operationId];
      if (causal.contains(atom.operationId) ||
          (insertion != null &&
              insertion.membershipEpoch < checkpoint.membershipEpoch)) {
        atom.deleted = true;
      }
    }
  }

  final children = <String?, List<_Atom>>{};
  for (final atom in atoms.values) {
    children.putIfAbsent(atom.after, () => []).add(atom);
  }
  for (final siblings in children.values) {
    siblings.sort((left, right) {
      final byRank = right.rank.compareTo(left.rank);
      return byRank != 0 ? byRank : right.id.compareTo(left.id);
    });
  }
  final visible = <CloudRichTextAtomView>[];
  final pendingAtoms = <_Atom>[...(children[null] ?? const <_Atom>[]).reversed];
  while (pendingAtoms.isNotEmpty) {
    final atom = pendingAtoms.removeLast();
    if (!atom.deleted) {
      visible.add(
        CloudRichTextAtomView(
          id: atom.id,
          value: atom.value,
          style: atom.style,
        ),
      );
    }
    pendingAtoms.addAll((children[atom.id] ?? const <_Atom>[]).reversed);
  }
  final spans = <CloudRichTextSpan>[];
  for (final atom in visible) {
    if (spans.isNotEmpty && spans.last.style == atom.style) {
      final prior = spans.removeLast();
      spans.add(
        CloudRichTextSpan(text: prior.text + atom.value, style: atom.style),
      );
    } else {
      spans.add(CloudRichTextSpan(text: atom.value, style: atom.style));
    }
  }

  final parentIds = <String>{
    for (final operation in relevant.values) ...operation.parentOperationIds,
  };
  final heads = relevant.keys.where((id) => !parentIds.contains(id)).toList()
    ..sort();
  var concurrentRecovery = false;
  for (final atom in visible) {
    for (final deletion in documentDeletes) {
      final insertOperation = atom.id.split(':').first;
      if (!causalPast(deletion).contains(insertOperation) &&
          !causalFuture(deletion).contains(insertOperation) &&
          insertOperation != deletion) {
        concurrentRecovery = true;
        break;
      }
    }
    if (concurrentRecovery) break;
  }
  return CloudRichTextSnapshot(
    atoms: List.unmodifiable(visible),
    spans: List.unmodifiable(spans),
    headOperationIds: List.unmodifiable(heads),
    invalidOperationIds: List.unmodifiable(invalid..sort()),
    unavailableOperationIds: List.unmodifiable(unavailable..sort()),
    hasDocumentDelete: documentDeletes.isNotEmpty,
    hasConcurrentRecovery: concurrentRecovery,
  );
}

List<CloudDocumentOperation> _topologicalOperations(
  Map<String, CloudDocumentOperation> operations,
) {
  final remaining = Map<String, CloudDocumentOperation>.from(operations);
  final result = <CloudDocumentOperation>[];
  final emitted = <String>{};
  while (remaining.isNotEmpty) {
    final ready =
        remaining.values
            .where(
              (operation) => operation.parentOperationIds.every(
                (parent) =>
                    !operations.containsKey(parent) || emitted.contains(parent),
              ),
            )
            .toList()
          ..sort(
            (left, right) => left.operationId.compareTo(right.operationId),
          );
    if (ready.isEmpty) {
      // The signed document fold already rejects missing dependencies. A cycle
      // can only come from a malicious codec payload graph; keep it inert.
      result.addAll(
        remaining.values.toList()..sort(
          (left, right) => left.operationId.compareTo(right.operationId),
        ),
      );
      break;
    }
    for (final operation in ready) {
      remaining.remove(operation.operationId);
      emitted.add(operation.operationId);
      result.add(operation);
    }
  }
  return result;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
