import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/capture_resource_lifetime.dart';

class _Source implements CaptureResource {
  _Source(this.owner);
  final CaptureResourceLifetime owner;
  Completer<void>? gate;
  bool refuse = false, acknowledgeWithoutRelease = false;
  int retires = 0;
  @override
  Future<void> retire() async {
    retires++;
    await gate?.future;
    if (refuse) throw StateError('synthetic source refusal');
    if (!acknowledgeWithoutRelease) owner.forget(this);
  }
}

class _PrivateSource extends _Source implements PrivacyCaptureResource {
  _PrivateSource(super.owner);
  @override
  Future<void> stopForPrivacy() => retire();
}

void main() {
  tearDown(CaptureResourceLifetime.resetForTesting);
  test(
    'retirement joins owned sources and seals admission before first await',
    () async {
      final old = CaptureResourceLifetime.current();
      final source = _Source(old)..gate = Completer<void>();
      expect(old.admit(source), isTrue);
      final retiring = old.retire();
      expect(identical(retiring, old.retire()), isTrue);
      expect(old.admit(_Source(old)), isFalse);
      var returned = false;
      final observed = retiring.then((_) => returned = true);
      try {
        await Future<void>(() {});
        expect(returned, isFalse);
        expect(source.retires, 1);
      } finally {
        source.gate!.complete();
        await observed;
      }
      final receipt = await retiring;
      await receipt.verifyReleasedResources();
      receipt.releaseAdmission();
      expect(old.admit(_Source(old)), isFalse);
      final fresh = CaptureResourceLifetime.current();
      final next = _Source(fresh);
      expect(fresh.admit(next), isTrue);
      receipt.releaseAdmission();
      expect(identical(CaptureResourceLifetime.current(), fresh), isTrue);
      await fresh.retire();
      expect(next.retires, 1);
    },
  );

  test(
    'failed close retains source for retry, never reopens the old lifetime',
    () async {
      final owner = CaptureResourceLifetime.current();
      final source = _Source(owner)..refuse = true;
      owner.admit(source);
      await expectLater(
        owner.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
      expect(owner.admit(_Source(owner)), isFalse);
      source.refuse = false;
      final receipt = await owner.retire();
      expect(source.retires, 2);
      expect(identical(await owner.retire(), receipt), isTrue);
      await receipt.verifyReleasedResources();
    },
  );

  test('a returned close without ownership release is not absence', () async {
    final owner = CaptureResourceLifetime.current();
    final source = _Source(owner)..acknowledgeWithoutRelease = true;
    owner.admit(source);
    await expectLater(
      owner.retire(),
      throwsA(isA<CaptureResourceRetirementFailure>()),
    );
    source.acknowledgeWithoutRelease = false;
    await owner.retire();
    expect(source.retires, 2);
  });
  test(
    'privacy interruption revokes old admission before stopping sources',
    () async {
      final scope = CaptureResourceLifetime.current();
      final old = scope.captureAdmission();
      final private = _PrivateSource(scope)..gate = Completer<void>();
      final call = _Source(scope);
      scope.admit(private, admission: old);
      scope.admit(call);
      final stopping = scope.stopForPrivacy();
      try {
        expect(old.isActive, isFalse);
        expect(private.retires, 1);
        expect(call.retires, 0, reason: 'screen lock is not a call hangup');
        expect(scope.admit(_Source(scope), admission: old), isFalse);
        expect(scope.captureAdmission().isActive, isTrue);
        final other = CaptureResourceLifetime.isolatedForTesting();
        expect(
          other.admit(_Source(other), admission: scope.captureAdmission()),
          isFalse,
        );
      } finally {
        private.gate!.complete();
        await stopping;
        await scope.retire();
      }
      expect(call.retires, 1);
    },
  );

  test('failed privacy stop retains owner and remains retryable', () async {
    final scope = CaptureResourceLifetime.current();
    final source = _PrivateSource(scope)..refuse = true;
    scope.admit(source);
    try {
      await expectLater(scope.stopForPrivacy(), throwsStateError);
      expect(scope.captureAdmission().isActive, isTrue);
      await expectLater(
        scope.retire(),
        throwsA(isA<CaptureResourceRetirementFailure>()),
      );
    } finally {
      source.refuse = false;
      await scope.retire();
    }
    expect(source.retires, 3);
  });
}
