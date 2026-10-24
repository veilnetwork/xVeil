import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/storage/storage.dart';

import '../core/log.dart';
import '../core/local_authentication.dart';
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

  Map<String, Object> toJson() => {
    'k': base64Encode(_key),
    'h': base64Encode(_digest),
  };

  static ScreenLockVerifier? fromJson(Object? raw) {
    try {
      if (raw is! Map) return null;
      final key = base64Decode(raw['k'] as String);
      final digest = base64Decode(raw['h'] as String);
      if (key.length != 32 || digest.length != 32) return null;
      return ScreenLockVerifier._(key, digest);
    } catch (_) {
      return null;
    }
  }

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
    this.patternGrid,
    this.systemAuthentication = false,
  });

  final ScreenLockTimeout timeout;
  final int? patternGrid;
  final bool systemAuthentication;

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
    int? patternGrid,
    bool clearPattern = false,
    bool? systemAuthentication,
  }) => ScreenLockState(
    timeout: timeout ?? this.timeout,
    patternGrid: clearPattern ? null : patternGrid ?? this.patternGrid,
    systemAuthentication: systemAuthentication ?? this.systemAuthentication,
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
  ScreenLockVerifier? _patternVerifier;
  Object _session = Object();
  bool _authInFlight = false;
  bool _configurationInFlight = false;
  bool get systemPromptActive => _authInFlight;
  static const _quickKey = 'screen_lock_quick.v1';
  DateTime? _leftForegroundAt;

  /// The storage THIS build belongs to.
  late Storage _storage;

  /// Which load is the current one.
  ///
  /// Several run at once by design — `build` starts one while the container is
  /// still shut, `reloadTimeout` starts another the moment it opens, and a
  /// switch starts a third. They are not ordered: the one that finishes LAST
  /// used to win, so A's `off` could land on top of B's `immediately` and the
  /// cover that hides the screen in the app switcher never appeared (report17
  /// XV17-M4).
  int _loadGeneration = 0;

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
    _session = Object();
    _verifier = null;
    _patternVerifier = null;
    final storage = ref.watch(storageProvider);
    _storage = storage;
    _load(storage);
    ref.onDispose(() => storage.isOpen);
    return const ScreenLockState();
  }

  Future<void> _load(Storage storage) async {
    final mine = ++_loadGeneration;
    try {
      final raw = await storage.getSetting(kScreenLockTimeoutSettingKey);
      final quickRaw = await storage.getSetting(_quickKey);
      Map? quick;
      try {
        quick = quickRaw == null ? null : jsonDecode(quickRaw) as Map;
      } catch (_) {}
      // Only the newest load may speak.
      //
      // That covers the identity switch as well, and deliberately so: a switch
      // rebuilds this notifier, `build` starts a load of its own, and the read
      // still parked against the previous identity is by construction an older
      // generation. A separate "is this still my storage" check was written
      // here first and removed — nothing could redden it, and a guard that
      // cannot fail is a guard nobody can trust.
      if (mine != _loadGeneration || _userSet) return;
      final grid = quick?['grid'];
      final verifier = ScreenLockVerifier.fromJson(quick?['pattern']);
      _patternVerifier = (grid == 3 || grid == 4 || grid == 5)
          ? verifier
          : null;
      state = state.copyWith(
        timeout: screenLockTimeoutFromName(raw),
        patternGrid: _patternVerifier == null ? null : grid as int,
        clearPattern: _patternVerifier == null,
        systemAuthentication: quick?['system'] == true,
      );
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
    return _load(_storage);
  }

  Future<void> setTimeout(ScreenLockTimeout value) async {
    final storage = _storage;
    _userSet = true;
    state = state.copyWith(timeout: value);
    try {
      // Into the storage this choice was made under.
      await storage.putSetting(kScreenLockTimeoutSettingKey, value.name);
    } catch (_) {
      // Persist best-effort; the live setting already applies.
    }
  }

  /// Called from [AppController.unlock] once the container is open. This is the
  /// only moment the password is in hand, and it is not kept — only something
  /// that can recognise it again.
  void rememberPassword(String password) {
    _session = Object();
    _verifier = ScreenLockVerifier.forPassword(password);
  }

  /// Called from [AppController.lock]: the session is over, so the screen lock
  /// has nothing left to guard and must not carry a verifier into the next one.
  void forgetSession() {
    _session = Object();
    _loadGeneration++;
    _patternVerifier = null;
    _verifier = null;
    _leftForegroundAt = null;
    state = state.copyWith(
      locked: false,
      wrongPassword: false,
      clearPattern: true,
      systemAuthentication: false,
    );
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
    if (screenLockDue(
      timeout: state.timeout,
      awayFor: now().difference(left),
    )) {
      _lock();
    }
  }

  void _lock() {
    // Nothing to unlock with means nothing to lock: a session opened by a path
    // that never saw a password (a test harness, a headless boot) must not end
    // up behind a prompt that cannot be answered.
    if (_verifier == null) {
      devLog(
        () => 'xVeil[screenlock]: no verifier for this session — not locking',
      );
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
    return _tryVerifier(_verifier, password);
  }

  bool _tryVerifier(ScreenLockVerifier? verifier, String candidate) {
    if (verifier == null || !verifier.matches(candidate)) {
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

  static bool validPattern(int grid, List<int> nodes) =>
      (grid == 3 || grid == 4 || grid == 5) &&
      nodes.length >= 4 &&
      nodes.length <= grid * grid &&
      nodes.toSet().length == nodes.length &&
      nodes.every((n) => n >= 0 && n < grid * grid);

  static String _patternText(int grid, List<int> nodes) =>
      '$grid:${nodes.join(',')}';

  bool tryUnlockPattern(List<int> nodes) {
    final grid = state.patternGrid;
    if (throttleRemaining > Duration.zero) {
      state = state.copyWith(wrongPassword: false);
      return false;
    }
    return _tryVerifier(
      _patternVerifier,
      grid != null && validPattern(grid, nodes)
          ? _patternText(grid, nodes)
          : 'invalid',
    );
  }

  /// Changes require the session password; persisted only inside this identity's
  /// encrypted space. No low-entropy pattern is used to derive container keys.
  Future<bool> configureQuickUnlock({
    required String password,
    int? grid,
    List<int>? nodes,
    bool clearPattern = false,
    required bool system,
    required String reason,
  }) async {
    if (_configurationInFlight ||
        state.locked ||
        throttleRemaining > Duration.zero) {
      return false;
    }
    _configurationInFlight = true;
    try {
      if (_verifier?.matches(password) != true) {
        _failures++;
        _blockedUntil = _clock.elapsed + throttleAfter(_failures);
        return false;
      }
      final keepPattern =
          !clearPattern &&
          grid == state.patternGrid &&
          (nodes == null || nodes.isEmpty) &&
          _patternVerifier != null;
      if (grid != null &&
          !keepPattern &&
          (nodes == null || !validPattern(grid, nodes))) {
        return false;
      }
      final session = _session;
      final storage = _storage;
      if (system && !state.systemAuthentication) {
        _authInFlight = true;
        try {
          if (!await ref
              .read(localScreenAuthenticationProvider)
              .authenticate(reason)) {
            return false;
          }
        } finally {
          _authInFlight = false;
        }
      }
      if (session != _session || state.locked) return false;
      final pattern = keepPattern
          ? _patternVerifier
          : grid == null
          ? null
          : ScreenLockVerifier.forPassword(_patternText(grid, nodes!));
      ++_loadGeneration; // an older settings read must not undo this choice
      await storage.putSetting(
        _quickKey,
        jsonEncode({
          'grid': grid,
          'pattern': pattern?.toJson(),
          'system': system,
        }),
      );
      if (session != _session) return false;
      _patternVerifier = pattern;
      _failures = 0;
      _blockedUntil = Duration.zero;
      state = state.copyWith(
        patternGrid: grid,
        clearPattern: grid == null,
        systemAuthentication: system,
        wrongPassword: false,
      );
      return true;
    } finally {
      _configurationInFlight = false;
    }
  }

  Future<T> duringSystemPrompt<T>(Future<T> Function() action) async {
    if (_authInFlight) throw StateError('Authentication already in progress');
    _authInFlight = true;
    try {
      return await action();
    } finally {
      _authInFlight = false;
    }
  }

  Future<bool> tryUnlockSystem(String reason) async {
    if (!state.locked ||
        !state.systemAuthentication ||
        _verifier == null ||
        _authInFlight ||
        throttleRemaining > Duration.zero) {
      return false;
    }
    final session = _session;
    _authInFlight = true;
    try {
      final ok = await ref
          .read(localScreenAuthenticationProvider)
          .authenticate(reason);
      if (!ok ||
          session != _session ||
          !state.locked ||
          !state.systemAuthentication) {
        return false;
      }
      _failures = 0;
      _blockedUntil = Duration.zero;
      state = state.copyWith(locked: false, wrongPassword: false);
      return true;
    } finally {
      _authInFlight = false;
    }
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
