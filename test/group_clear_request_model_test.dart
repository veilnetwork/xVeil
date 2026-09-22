// A GROUP clear request is kept in the same list as the 1:1 ones, so the
// record has to say which question it is — and survive being stored.
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/clear_request.dart';

void main() {
  PendingClearRequest make({String? kind}) => PendingClearRequest(
    chatHex: 'a' * 64,
    requesterHex: 'b' * 64,
    atMs: 1,
    seq: 0,
    watermark: {'b' * 64: 3},
    groupKind: kind,
  );

  test('the kind survives being stored', () {
    final back = PendingClearRequest.fromJson(
      make(kind: kGroupClearAll).toJson(),
    )!;
    expect(back.groupKind, kGroupClearAll);
    expect(back.isGroup, isTrue);
  });

  test('a 1:1 request stays a 1:1 request', () {
    final back = PendingClearRequest.fromJson(make().toJson())!;
    expect(back.groupKind, isNull);
    expect(back.toJson().containsKey('gk'), isFalse);
  });

  test('an unknown kind is not shown as a question', () {
    // Offering "yes" to something this build cannot carry out exactly is
    // worse than not offering it.
    final raw = make(kind: kGroupClearOwn).toJson()..['gk'] = 'everything';
    expect(PendingClearRequest.fromJson(raw), isNull);
  });

  test('"mine" and "everyone\'s" from one person are two questions', () {
    expect(
      make(kind: kGroupClearOwn).key,
      isNot(make(kind: kGroupClearAll).key),
      reason: 'one would silently replace the other in the list',
    );
  });
}
