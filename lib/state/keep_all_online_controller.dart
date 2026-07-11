import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _kKeepAllOnlineKey = 'keep_all_online';

/// Whether a master session should keep ALL its identities online at once
/// (every identity's node running simultaneously) instead of one active at a
/// time. Persisted to `shared_preferences`; default **true** — all-online is
/// the NORM of a master session (user decision 2026-07-11): switching is
/// instant and no identity drops offline, at the cost of resources (N nodes;
/// noticeable on mobile) and of one-device correlation.
///
/// Off remains the strict-unlinkability opt-out: only the active identity is
/// on the network, so an observer can't correlate the user's identities by
/// their co-located nodes. Either way, mark individual identities `anonymous`
/// to route them over onion and keep them uncorrelated even when always-on.
class KeepAllOnlineController extends Notifier<bool> {
  bool _userSet = false;

  @override
  bool build() {
    _load();
    return true;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      // Don't clobber a set() that raced ahead of this async load. A user who
      // explicitly chose one-active before the default flip keeps that choice
      // (the pref is only absent when never touched).
      if (!_userSet) state = prefs.getBool(_kKeepAllOnlineKey) ?? true;
    } catch (_) {
      // No prefs (e.g. widget tests) — stay on the default (all-online).
    }
  }

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;
    final prefs = await ref.read(prefsProvider.future);
    await prefs.setBool(_kKeepAllOnlineKey, value);
  }

  /// The persisted value, AWAITED — for decision points that must not race
  /// the async prefs load. A lazily-created provider returns the default
  /// synchronously while [_load] is still in flight; with the default now ON,
  /// that race would boot all-online against an explicit one-active opt-out
  /// (before the flip it merely fell back to the safe picker). The master
  /// unlock reads this instead of [state].
  Future<bool> resolved() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      return prefs.getBool(_kKeepAllOnlineKey) ?? true;
    } catch (_) {
      return state; // no prefs (tests) — the in-memory value is all there is
    }
  }
}

final keepAllOnlineProvider =
    NotifierProvider<KeepAllOnlineController, bool>(KeepAllOnlineController.new);
