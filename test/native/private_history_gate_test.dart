import 'dart:async';
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
  Future<void> entered([PrivateHistoryGate? selected]) async {
    final deadline = Stopwatch()..start();
    while (!await (selected ?? gate).file(kind, 'entered.json').exists()) {
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
  test('a selected row has an independent one-shot gate and a data-free marker',
      () async {
    final selected = PrivateHistoryGate(root, prefix,
        rowIndex: 350, filePrefix: 'history-midpoint');
    await gate.file(kind, 'arm').writeAsString('arm');
    await selected.file(kind, 'arm').writeAsString('arm');
    expect(await selected.wait(kind: kind, id: '${prefix}0000',
        body: '${prefix}body', isActive: () => true), isFalse);
    final first = wait();
    final middle = selected.wait(kind: kind, id: '${prefix}0350',
        body: '${prefix}body', isActive: () => true);
    try {
      await entered();
      await entered(selected);
      expect(await selected.file(kind, 'arm').exists(), isFalse);
      expect(await selected.wait(kind: kind, id: '${prefix}0350',
          body: '${prefix}body', isActive: () => true), isFalse);
      final marker = await selected.file(kind, 'entered.json').readAsString();
      expect(marker, isNot(contains(prefix)));
      expect(marker, isNot(contains('body')));
      expect(selected.snapshot['applySelectedRowCalls'], 2);
      expect(gate.snapshot['applyFirstRowCalls'], 1);
    } finally {
      await gate.file(kind, 'release').writeAsString('release');
      await selected.file(kind, 'release').writeAsString('release');
    }
    expect(await first, isTrue);
    expect(await middle, isTrue);
  });
  test('gate selectors cannot escape the owned directory', () {
    expect(() => PrivateHistoryGate(root, prefix, rowIndex: -1),
        throwsArgumentError);
    for (final stem in ['../escape', '/tmp/escape', '', 'a/b']) {
      expect(() => PrivateHistoryGate(root, prefix, filePrefix: stem),
          throwsArgumentError);
    }
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
  test('retirement during release observation wins', () async {
    var active = true;
    final releaseRead = Completer<void>();
    final finishRead = Completer<void>();
    gate = PrivateHistoryGate(
      root,
      prefix,
      signalExists: (file) async {
        if (file.path == gate.file(kind, 'release').path) {
          releaseRead.complete();
          await finishRead.future;
        }
        return file.exists();
      },
    );
    await gate.file(kind, 'arm').writeAsString('arm');
    final pending = wait(active: () => active);
    final observed = expectLater(pending, throwsStateError);
    await releaseRead.future;
    active = false;
    try {
      await gate.file(kind, 'release').writeAsString('release');
    } finally {
      finishRead.complete();
    }
    await observed;
    expect(gate.snapshot['applyReleased'], 0);
    expect(gate.snapshot['applyFailures'], 1);
  });
  test('lease is bounded independently of controller teardown', () async {
    gate = PrivateHistoryGate(root, prefix, lease: Duration.zero);
    await gate.file(kind, 'arm').writeAsString('arm');
    await expectLater(wait(), throwsStateError);
  });
}
