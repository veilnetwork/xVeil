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
      // Closed storage (the lock screen, tests) — keep the default.
    }
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

  /// Returns true when the screen was unlocked. A wrong password only sets the
  /// error — there is nothing here to rate-limit or destroy, because the wrong
  /// password never had access to anything in the first place.
  bool tryUnlock(String password) {
    final verifier = _verifier;
    if (verifier == null || !verifier.matches(password)) {
      state = state.copyWith(wrongPassword: true);
      return false;
    }
    state = state.copyWith(locked: false, wrongPassword: false);
    return true;
  }
}

final screenLockProvider =
    NotifierProvider<ScreenLockController, ScreenLockState>(
      ScreenLockController.new,
    );
