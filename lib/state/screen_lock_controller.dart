import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../domain/screen_lock.dart';
import 'providers.dart';

/// Checks the password that lifts the screen lock, without closing anything.
///
/// The container is already open when this is asked, so there is nothing to
/// re-open and nothing to derive keys for — the only question is whether the
/// person typing is the person who unlocked it. The answer is an HMAC over a
/// per-session random key, held in memory and never written anywhere.
///
/// A deliberately cheap KDF, and worth being explicit about why rather than
/// letting it look like an oversight: this value lives in the same process
/// memory as the container's keys and the plaintext messages. Anyone who can
/// read it has already got everything it could ever protect, so iterating it a
/// hundred thousand times would buy nothing and cost a second of the user's
/// time on every unlock. What the random per-session key DOES buy is that the
/// value is not a stable function of the password: it is useless the moment
/// the process ends, and it is not the same across two runs.
@immutable
class ScreenLockVerifier {
  const ScreenLockVerifier._(this._key, this._digest);

  factory ScreenLockVerifier.forPassword(String password) {
    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    return ScreenLockVerifier._(key, _digestOf(key, password));
  }

  final List<int> _key;
  final List<int> _digest;

  static List<int> _digestOf(List<int> key, String password) =>
      Hmac(sha256, key).convert(utf8.encode(password)).bytes;

  /// Constant-time: an early return on the first differing byte would time the
  /// comparison, and a lock screen is exactly where somebody gets to try over
  /// and over.
  bool matches(String candidate) {
    final actual = _digestOf(_key, candidate);
    if (actual.length != _digest.length) return false;
    var difference = 0;
    for (var i = 0; i < actual.length; i++) {
      difference |= actual[i] ^ _digest[i];
    }
    return difference == 0;
  }
}

@immutable
class ScreenLockState {
  const ScreenLockState({
    this.timeout = ScreenLockTimeout.off,
    this.locked = false,
    this.wrongPassword = false,
  });

  final ScreenLockTimeout timeout;

  /// Whether the password prompt is over the app right now. Nothing behind it
  /// is torn down — see [ScreenLockController].
  final bool locked;

  /// Whether the last thing SUBMITTED was compared and came back no.
  ///
  /// Not "the last thing that was looked at": the field it drives sits under
  /// the box, so it reads as a verdict on the text in the box right now. An
  /// attempt refused unread replaces a verdict with the absence of one — see
  /// [ScreenLockController.tryUnlock].
  final bool wrongPassword;

  ScreenLockState copyWith({
    ScreenLockTimeout? timeout,
    bool? locked,
    bool? wrongPassword,
  }) => ScreenLockState(
    timeout: timeout ?? this.timeout,
    locked: locked ?? this.locked,
    wrongPassword: wrongPassword ?? this.wrongPassword,
  );
}

/// Locks the SCREEN after the app has been away for the configured time.
///
/// The whole point of this controller is what it does NOT do. It never touches
/// storage, the node, the messaging service or the notification binder — it
/// flips one boolean that a cover in `app.dart` watches. Everything behind the
/// cover stays mounted and running, so messages keep arriving and the shade
/// keeps filling up while the screen is locked. That is the user's decision
/// stated plainly: pay nothing in delivery, gain a prompt in front of the
/// screen. Closing the container instead is a different setting that does not
/// exist yet, and it would have the opposite trade.
///
/// The clock is injected because "after fifteen minutes" is not a thing a test
/// should have to wait for.
class ScreenLockController extends Notifier<ScreenLockState> {
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  /// The persisted read is async, so a user who changes the setting while it is
  /// still in flight would otherwise have their choice overwritten by the old
  /// value a moment later.
  bool _userSet = false;

  ScreenLockVerifier? _verifier;
  DateTime? _leftForegroundAt;

  @override
  ScreenLockState build() {
    // Same shape as the other in-container policies: watching storage makes
    // this reload when all-online switches the active identity's space.
    //
    // Reset here, and NOT only in the field initializer: Riverpod reuses the
    // notifier instance across an invalidation, so a `_userSet` left standing
    // from the previous identity makes [_load] return early and the new
    // identity's persisted choice never lands — it reads as `off` while the
    // user believes it is set. Caught by the reload test below.
    _userSet = false;
    final storage = ref.watch(storageProvider);
    _load();
    ref.onDispose(() => storage.isOpen);
    return const ScreenLockState();
  }

  Future<void> _load() async {
    try {
      final raw = await ref
          .read(storageProvider)
          .getSetting(kScreenLockTimeoutSettingKey);
      if (_userSet) return;
      state = state.copyWith(timeout: screenLockTimeoutFromName(raw));
    } catch (_) {
      // Closed storage (the lock screen, tests) — keep the default. Which is
      // why [reloadTimeout] exists: this is the NORMAL outcome at build time,
      // not an edge case, and something has to come back for the answer.
    }
  }

  /// Read the persisted timeout again now that the container is actually open.
  ///
  /// [build] runs while it is still shut. `ScreenLockHost` lives in
  /// `MaterialApp.builder`, so it is mounted from the first frame — before the
  /// unlock screen, let alone the unlock — and the `getSetting` in [_load]
  /// throws "storage is locked" there. That throw is swallowed, and on the
  /// single-identity path nothing ever retried it: `storageProvider` hands back
  /// the SAME object that `open()` mutates in place, so `ref.watch` never fires
  /// a second time and the saved choice read as `off` for the whole run. (The
  /// multi-identity path re-points the provider at a different object and
  /// happened to self-heal, which is why this only ever bit some users.)
  ///
  /// Called from `AppController._enterSession`, i.e. from the one moment the
  /// container has answered — not from a rebuild that may never come.
  Future<void> reloadTimeout() {
    // Whatever the previous session chose must not veto the space that just
    // opened: this IS the moment its stored value became readable, so the
    // container wins. The in-flight guard inside [_load] still protects a user
    // who changes the setting while this read is running.
    _userSet = false;
    return _load();
  }

  Future<void> setTimeout(ScreenLockTimeout value) async {
    _userSet = true;
    state = state.copyWith(timeout: value);
    try {
      await ref
          .read(storageProvider)
          .putSetting(kScreenLockTimeoutSettingKey, value.name);
    } catch (_) {
      // Persist best-effort; the live setting already applies.
    }
  }

  /// Called from [AppController.unlock] once the container is open. This is the
  /// only moment the password is in hand, and it is not kept — only something
  /// that can recognise it again.
  void rememberPassword(String password) {
    _verifier = ScreenLockVerifier.forPassword(password);
  }

  /// Called from [AppController.lock]: the session is over, so the screen lock
  /// has nothing left to guard and must not carry a verifier into the next one.
  void forgetSession() {
    _verifier = null;
    _leftForegroundAt = null;
    state = state.copyWith(locked: false, wrongPassword: false);
  }

  /// The app stopped being frontmost. Records WHEN rather than locking here:
  /// `immediately` locks now, everything else is decided on the way back, so a
  /// user who flips to another app for two seconds under a 15-minute setting
  /// does not come back to a prompt.
  void onLeftForeground() {
    if (state.timeout == ScreenLockTimeout.off) return;
    _leftForegroundAt ??= now();
    if (state.timeout == ScreenLockTimeout.immediately) _lock();
  }

  /// The app is frontmost again. Locks if it was away long enough.
  void onReturnedToForeground() {
    final left = _leftForegroundAt;
    _leftForegroundAt = null;
    if (left == null || state.locked) return;
    if (screenLockDue(timeout: state.timeout, awayFor: now().difference(left))) {
      _lock();
    }
  }

  void _lock() {
    // Nothing to unlock with means nothing to lock: a session opened by a path
    // that never saw a password (a test harness, a headless boot) must not end
    // up behind a prompt that cannot be answered.
    if (_verifier == null) {
      devLog(() => 'xVeil[screenlock]: no verifier for this session — not locking');
      return;
    }
    if (state.locked) return;
    state = state.copyWith(locked: true, wrongPassword: false);
  }

  /// How long until another attempt is even looked at (audit report10 X-05).
  ///
  /// Zero when nothing is owed. Read by `ScreenLockCover`, which counts it down
  /// in the field's error line rather than leaving a person tapping at a field
  /// that silently ignores them. That consumer is not decoration: inside this
  /// window [tryUnlock] refuses before it computes anything, so the CORRECT
  /// password comes back indistinguishable from a wrong one — and for as long
  /// as nothing said otherwise, the app told a person who had typed their own
  /// password that it was wrong.
  Duration get throttleRemaining {
    final owed = _blockedUntil - _clock.elapsed;
    return owed.isNegative ? Duration.zero : owed;
  }

  /// The wait after [failures] consecutive wrong answers.
  ///
  /// Nothing for the first two — fingers slip, and a person who mistypes once
  /// should not be punished. Then doubling from a quarter second, capped at
  /// thirty. The cap matters: an uncapped backoff locks a person out of their
  /// own messenger for hours after a cat walks over the keyboard, and that is a
  /// denial of service with extra steps.
  @visibleForTesting
  static Duration throttleAfter(int failures) {
    if (failures <= 2) return Duration.zero;
    final steps = failures - 2;
    final ms = 250 * (1 << (steps - 1).clamp(0, 8));
    return Duration(milliseconds: ms.clamp(0, 30000));
  }

  /// Returns true when the screen was unlocked.
  ///
  /// A wrong password destroys nothing — it never had access to anything in the
  /// first place — but it does buy the next attempt a wait; see [throttleAfter]
  /// and [throttleRemaining].
  bool tryUnlock(String password) {
    // Refused before the HMAC is even computed. The check is deliberately
    // cheap — see [ScreenLockVerifier] — so the only thing standing between a
    // weak PIN and UI automation is how often it may be asked.
    if (throttleRemaining > Duration.zero) {
      // CLEARED, not set. This line used to say `wrongPassword: true`, and it
      // was measured on an Android phone: wrong answers until a wait is owed,
      // then the CORRECT password, refused by the throttle and counted down
      // honestly — and at the tick the countdown expired the field flipped to
      // "wrong password" with that correct password still visible in the box,
      // nobody having touched the phone. The countdown had only been covering
      // the claim; running out uncovered it.
      //
      // Nothing was compared here — the return above the HMAC is the whole
      // point of the throttle — so the app has no opinion to hold, and the
      // one it was holding is about a different string than the one now in the
      // box. What replaces it is nothing at all: no verdict is the truth, and
      // the button coming back live is already the invitation to try again.
      //
      // Scoped to THIS event, deliberately. A person who gets it wrong and
      // then just waits still sees "wrong password" when the wait ends, and
      // should: that answer was reached, about the text still in front of
      // them. Clearing on the countdown instead would throw it away.
      state = state.copyWith(wrongPassword: false);
      return false;
    }
    final verifier = _verifier;
    if (verifier == null || !verifier.matches(password)) {
      _failures++;
      // MONOTONIC, not wall time. A deadline compared against DateTime.now()
      // is skipped by putting the device clock back, which is a setting, not
      // an exploit.
      _blockedUntil = _clock.elapsed + throttleAfter(_failures);
      state = state.copyWith(wrongPassword: true);
      return false;
    }
    _failures = 0;
    _blockedUntil = Duration.zero;
    state = state.copyWith(locked: false, wrongPassword: false);
    return true;
  }

  /// Counts from process start and cannot be moved. A `Stopwatch` rather than
  /// a clock: the question is only ever "how much later than that", and no
  /// answer to it should depend on what the device thinks the date is.
  final Stopwatch _clock = Stopwatch()..start();
  int _failures = 0;
  Duration _blockedUntil = Duration.zero;

  /// For tests: pretend [amount] of monotonic time has passed.
  @visibleForTesting
  void debugAdvance(Duration amount) => _blockedUntil -= amount;
}

final screenLockProvider =
    NotifierProvider<ScreenLockController, ScreenLockState>(
      ScreenLockController.new,
    );
