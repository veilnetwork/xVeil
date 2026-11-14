import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/profile_model_work.dart';

void main() {
  test(
    'a failed task cannot release another accepted writer or finish retirement',
    () async {
      final owner = ProfileModelWork();
      final speech = owner.begin(lane: 'speech')!,
          translation = owner.begin(lane: 'translation')!;
      final first = Completer<void>(), second = Completer<void>();
      final failed = speech
          .run(() async {
            await first.future;
            throw StateError('synthetic failure');
          })
          .then<Object?>((_) => null, onError: (Object e) => e);
      final pending = translation.run(() => second.future);
      final draining = owner.retire();
      expect(identical(draining, owner.retire()), isTrue);
      expect(speech.current, isFalse);
      expect(translation.current, isFalse);
      expect(owner.begin(), isNull);
      var drained = false;
      final observed = draining.then((_) => drained = true);
      first.complete();
      expect(await failed, isA<StateError>());
      expect(drained, isFalse);
      second.complete();
      await pending;
      await observed;
      expect(drained, isTrue);
      expect(owner.begin(lane: 'speech'), isNull);
    },
  );

  test(
    'stale client remains cancelled and holds its lane until actual completion',
    () async {
      final owner = ProfileModelWork();
      var clientAlive = true;
      final old = owner.begin(lane: 'speech', stillCurrent: () => clientAlive)!;
      final release = Completer<void>();
      final pending = old.run(() => release.future);
      clientAlive = false;
      expect(old.current, isFalse);
      expect(owner.begin(lane: 'speech'), isNull);
      release.complete();
      await pending;
      final fresh = owner.begin(lane: 'speech')!;
      // A duplicate old run must not clear the fresh writer's lane or satisfy
      // its completion barrier.
      await expectLater(old.run(() {}), throwsStateError);
      expect(owner.begin(lane: 'speech'), isNull);
      await fresh.run(() {});
      await owner.retire();
    },
  );
}
