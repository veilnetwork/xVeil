import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/domain/cloud_document.dart';
import 'package:xveil/domain/cloud_rich_text_crdt.dart';

String _id(int value) => value.toRadixString(16).padLeft(64, '0');

CloudDocumentOperation _operation(
  int id, {
  List<int> parents = const [],
  int author = 1,
  int epoch = 0,
}) => CloudDocumentOperation(
  documentId: NodeId(Uint8List(32)),
  membershipEpoch: epoch,
  author: NodeId(Uint8List.fromList(List.filled(32, author))),
  seq: id,
  prevAuthorHash: '',
  operationId: _id(id),
  parentOperationIds: parents.map(_id).toList()..sort(),
  opType: cloudRichTextOperationType,
  payloadHash: _id(9000 + id),
  createdAtMs: id,
  authorPubKey: Uint8List(32),
  signature: Uint8List(64),
);

Map<String, Uint8List> _payloads(Map<int, CloudRichTextEdit> edits) => {
  for (final entry in edits.entries) _id(entry.key): entry.value.encode(),
};

void main() {
  test('payload codec is strict, bounded and preserves grapheme text', () {
    const style = CloudRichTextStyle(
      bold: true,
      italic: true,
      block: CloudRichTextBlock.heading1,
    );
    final encoded = CloudRichTextEdit.insert(
      afterAtomId: '${_id(1)}:0',
      text: '👩🏽‍💻é',
      style: style,
    ).encode();
    final decoded = CloudRichTextEdit.decode(encoded)!;
    expect(decoded.kind, CloudRichTextEditKind.insert);
    expect(decoded.text, '👩🏽‍💻é');
    expect(decoded.insertStyles, everyElement(style));

    expect(
      CloudRichTextEdit.decode(
        Uint8List.fromList(
          '{"v":1,"k":"delete","ids":["${_id(1)}:0","${_id(1)}:0"]}'.codeUnits,
        ),
      ),
      isNull,
    );
    expect(
      CloudRichTextEdit.decode(
        Uint8List.fromList('{"v":1,"k":"merge","extra":1}'.codeUnits),
      ),
      isNull,
    );
  });

  test(
    'RGA converges independent of delivery order and keeps graphemes whole',
    () {
      final base = _operation(1);
      final left = _operation(2, parents: [1], author: 2);
      final right = _operation(3, parents: [1], author: 3);
      final payloads = _payloads({
        1: CloudRichTextEdit.insert(afterAtomId: null, text: 'A👩🏽‍💻'),
        2: CloudRichTextEdit.insert(afterAtomId: '${_id(1)}:0', text: 'X'),
        3: CloudRichTextEdit.insert(afterAtomId: '${_id(1)}:0', text: 'Y'),
      });

      final first = materializeCloudRichText(
        operations: [base, left, right],
        cleartextByOperationId: payloads,
      );
      final second = materializeCloudRichText(
        operations: [right, base, left],
        cleartextByOperationId: payloads,
      );
      expect(first.text, 'AYX👩🏽‍💻');
      expect(second.text, first.text);
      expect(first.atoms, hasLength(4));
      expect(first.headOperationIds, [_id(2), _id(3)]);
      expect(first.invalidOperationIds, isEmpty);
    },
  );

  test(
    'causally newer insertion wins the local cursor side of old successor',
    () {
      final initial = _operation(1);
      final later = _operation(2, parents: [1]);
      final snapshot = materializeCloudRichText(
        operations: [initial, later],
        cleartextByOperationId: _payloads({
          1: CloudRichTextEdit.insert(afterAtomId: null, text: 'AC'),
          2: CloudRichTextEdit.insert(afterAtomId: '${_id(1)}:0', text: 'B'),
        }),
      );
      expect(snapshot.text, 'ABC');
    },
  );

  test('long insertion materializes iteratively without stack growth', () {
    final text = List.filled(20000, 'x').join();
    final snapshot = materializeCloudRichText(
      operations: [_operation(1)],
      cleartextByOperationId: _payloads({
        1: CloudRichTextEdit.insert(afterAtomId: null, text: text),
      }),
    );
    expect(snapshot.text.length, 20000);
    expect(snapshot.invalidOperationIds, isEmpty);
  });

  test('delete and exact format registers converge', () {
    final insert = _operation(1);
    final format = _operation(2, parents: [1]);
    final remove = _operation(3, parents: [2]);
    final snapshot = materializeCloudRichText(
      operations: [remove, insert, format],
      cleartextByOperationId: _payloads({
        1: CloudRichTextEdit.insert(afterAtomId: null, text: 'abc'),
        2: CloudRichTextEdit.format(
          targetAtomIds: ['${_id(1)}:1'],
          style: const CloudRichTextStyle(bold: true),
        ),
        3: CloudRichTextEdit.delete(['${_id(1)}:0']),
      }),
    );
    expect(snapshot.text, 'bc');
    expect(snapshot.atoms.first.style.bold, isTrue);
    expect(snapshot.spans, hasLength(2));
  });

  test('document delete does not erase an unseen concurrent edit', () {
    final base = _operation(1);
    final deletion = _operation(2, parents: [1], author: 1);
    final unseen = _operation(3, parents: [1], author: 2);
    final snapshot = materializeCloudRichText(
      operations: [deletion, unseen, base],
      cleartextByOperationId: _payloads({
        1: CloudRichTextEdit.insert(afterAtomId: null, text: 'old'),
        2: const CloudRichTextEdit.documentDelete(),
        3: CloudRichTextEdit.insert(afterAtomId: '${_id(1)}:2', text: 'safe'),
      }),
    );
    expect(snapshot.text, 'safe');
    expect(snapshot.hasDocumentDelete, isTrue);
    expect(snapshot.hasConcurrentRecovery, isTrue);
    expect(snapshot.isDeleted, isFalse);
  });

  test(
    'delete seeing the edit clears it, later intentional restore is distinct',
    () {
      final base = _operation(1);
      final edit = _operation(2, parents: [1], author: 2);
      final deletion = _operation(3, parents: [2]);
      final empty = materializeCloudRichText(
        operations: [base, edit, deletion],
        cleartextByOperationId: _payloads({
          1: CloudRichTextEdit.insert(afterAtomId: null, text: 'old'),
          2: CloudRichTextEdit.insert(afterAtomId: '${_id(1)}:2', text: 'seen'),
          3: const CloudRichTextEdit.documentDelete(),
        }),
      );
      expect(empty.text, isEmpty);
      expect(empty.isDeleted, isTrue);
      expect(empty.hasConcurrentRecovery, isFalse);

      final restore = _operation(4, parents: [3]);
      final restored = materializeCloudRichText(
        operations: [restore, deletion, edit, base],
        cleartextByOperationId: {
          ..._payloads({
            1: CloudRichTextEdit.insert(afterAtomId: null, text: 'old'),
            2: CloudRichTextEdit.insert(
              afterAtomId: '${_id(1)}:2',
              text: 'seen',
            ),
            3: const CloudRichTextEdit.documentDelete(),
            4: CloudRichTextEdit.insert(afterAtomId: null, text: 'restored'),
          }),
        },
      );
      expect(restored.text, 'restored');
      expect(restored.hasConcurrentRecovery, isFalse);
    },
  );

  test('new-epoch checkpoint needs no historical epoch cleartext', () {
    final historical = _operation(1);
    final checkpoint = _operation(2, parents: [1]);
    const style = CloudRichTextStyle(
      bold: true,
      block: CloudRichTextBlock.quote,
    );
    final snapshot = materializeCloudRichText(
      operations: [historical, checkpoint],
      cleartextByOperationId: {
        _id(2): CloudRichTextEdit.checkpoint(
          text: 'shared 👋',
          styles: [...List.filled(7, const CloudRichTextStyle()), style],
        ).encode(),
      },
    );
    expect(snapshot.text, 'shared 👋');
    expect(snapshot.atoms.last.style, style);
    expect(snapshot.invalidOperationIds, isEmpty);
    expect(snapshot.unavailableOperationIds, [_id(1)]);
  });

  test(
    'epoch checkpoint replaces unparented prior-epoch heads in any order',
    () {
      final historical = _operation(9);
      final checkpoint = _operation(2, epoch: 1);
      final snapshot = materializeCloudRichText(
        operations: [checkpoint, historical],
        cleartextByOperationId: _payloads({
          9: CloudRichTextEdit.insert(afterAtomId: null, text: 'obsolete'),
          2: CloudRichTextEdit.checkpoint(
            text: 'current',
            styles: List.filled(7, const CloudRichTextStyle()),
          ),
        }),
      );
      expect(snapshot.text, 'current');
    },
  );

  test(
    'malformed semantic operation stays inert without poisoning descendants',
    () {
      final malformed = _operation(1);
      final valid = _operation(2, parents: [1]);
      final snapshot = materializeCloudRichText(
        operations: [malformed, valid],
        cleartextByOperationId: {
          _id(1): Uint8List.fromList('{"v":1,"k":"wat"}'.codeUnits),
          _id(2): CloudRichTextEdit.insert(
            afterAtomId: null,
            text: 'ok',
          ).encode(),
        },
      );
      expect(snapshot.text, 'ok');
      expect(snapshot.invalidOperationIds, [_id(1)]);
    },
  );
}
