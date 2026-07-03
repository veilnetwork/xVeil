import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/messaging.dart';

typedef _Ev = ({String contentId, int done, int total});

void main() {
  late StreamController<_Ev> progress;
  late StreamController<String> failed;
  late ContentProgressNotifier notifier;

  setUp(() {
    progress = StreamController<_Ev>.broadcast();
    failed = StreamController<String>.broadcast();
    notifier = ContentProgressNotifier.forStreams(
      progress.stream,
      failed.stream,
    );
  });
  tearDown(() async {
    notifier.dispose();
    await progress.close();
    await failed.close();
  });

  Future<void> emit(String cid, int done, int total) async {
    progress.add((contentId: cid, done: done, total: total));
    await Future<void>.delayed(Duration.zero);
  }

  test('progress is monotonic: restart markers and lower baselines from '
      'concurrent pulls never roll the bar back', () async {
    await emit('c1', 5, 10);
    expect(notifier.state['c1'], 0.5);
    // The 0/1 "download (re)started" marker of a retry / auto-resume re-drive.
    await emit('c1', 0, 1);
    expect(notifier.state['c1'], 0.5);
    // A duplicate pull counting from its own (lower) resume baseline.
    await emit('c1', 2, 10);
    expect(notifier.state['c1'], 0.5);
    // Real forward progress still lands.
    await emit('c1', 6, 10);
    expect(notifier.state['c1'], 0.6);
  });

  test('a terminal failure resets the latch so the next attempt starts '
      'from its true position', () async {
    await emit('c1', 8, 10);
    failed.add('c1');
    await Future<void>.delayed(Duration.zero);
    expect(notifier.state.containsKey('c1'), isFalse);
    await emit('c1', 1, 10);
    expect(notifier.state['c1'], 0.1);
  });

  test('late echoes of a completed transfer do not resurrect the bar',
      () async {
    await emit('c1', 10, 10);
    expect(notifier.state['c1'], 1.0);
    // Completion cleanup removes the entry shortly after.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(notifier.state.containsKey('c1'), isFalse);
    // A still-draining duplicate pull keeps emitting — must stay ignored.
    await emit('c1', 5, 10);
    expect(notifier.state.containsKey('c1'), isFalse);
  });

  test('independent contents track independently', () async {
    await emit('c1', 5, 10);
    await emit('c2', 1, 10);
    expect(notifier.state['c1'], 0.5);
    expect(notifier.state['c2'], 0.1);
  });
}
