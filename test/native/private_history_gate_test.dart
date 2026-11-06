import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../support/private_history_gate.dart';

void main() {
  late Directory root;
  late PrivateHistoryGate gate;
  const prefix = 'synthetic-archive-';
  const kind = HistoryGateKind.apply;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('history-gate-');
    gate = PrivateHistoryGate(root, prefix);
  });
  tearDown(() => root.delete(recursive: true));
  Future<void> entered() async {
    final deadline = Stopwatch()..start();
    while (!await gate.file(kind, 'entered.json').exists()) {
      if (deadline.elapsed > const Duration(seconds: 2)) fail('no gate marker');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<bool> wait({bool Function()? active, String id = '${prefix}0000'}) =>
      gate.wait(
        kind: kind,
        id: id,
        body: '${prefix}body',
        isActive: active ?? () => true,
      );

  test('unarmed and nonmatching rows never wait', () async {
    expect(await wait(), isFalse);
    await gate.file(kind, 'arm').writeAsString('arm');
    expect(await wait(id: '${prefix}0001'), isFalse);
    expect(await gate.file(kind, 'entered.json').exists(), isFalse);
  });
  test(
    'one matching caller waits; its marker omits data and arm is consumed',
    () async {
      await gate.file(kind, 'arm').writeAsString('arm');
      var done = false;
      final pending = wait().then((value) {
        done = true;
        return value;
      });
      await entered();
      try {
        expect(done, isFalse);
        expect(await wait(), isFalse);
        expect(await gate.file(kind, 'arm').exists(), isFalse);
        final marker = await gate.file(kind, 'entered.json').readAsString();
        expect(marker, isNot(contains(prefix)));
        expect(marker, isNot(contains('body')));
      } finally {
        await gate.file(kind, 'release').writeAsString('release');
      }
      expect(await pending, isTrue);
    },
  );
  test('stop marker cancels the owned wait', () async {
    await gate.file(kind, 'arm').writeAsString('arm');
    final pending = wait();
    final observed = expectLater(pending, throwsStateError);
    await entered();
    await File('${root.path}/stop-worker').writeAsString('stop');
    await observed;
  });
  test('retired binding takes priority over release', () async {
    var active = true;
    await gate.file(kind, 'arm').writeAsString('arm');
    final pending = wait(active: () => active);
    final observed = expectLater(pending, throwsStateError);
    await entered();
    active = false;
    await gate.file(kind, 'release').writeAsString('release');
    await observed;
  });
  test('lease is bounded independently of controller teardown', () async {
    gate = PrivateHistoryGate(root, prefix, lease: Duration.zero);
    await gate.file(kind, 'arm').writeAsString('arm');
    await expectLater(wait(), throwsStateError);
  });
}
