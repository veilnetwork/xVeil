import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

const _kKeepAllOnlineKey = 'keep_all_online';

/// Whether a master session should keep ALL its identities online at once
/// (every identity's node running simultaneously) instead of one active at a
/// time. Persisted to `shared_preferences`; default **false**.
///
/// Off (default) is the anonymity-safe choice: only the active identity is on
/// the network, so a observer can't correlate the user's identities by their
/// co-located nodes. On trades that unlinkability for availability (no identity
/// goes offline when you switch) — mark individual identities `anonymous` to
/// route them over onion and keep them uncorrelated even when always-on.
class KeepAllOnlineController extends Notifier<bool> {
  bool _userSet = false;

  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    try {
      final prefs = await ref.read(prefsProvider.future);
      // Don't clobber a set() that raced ahead of this async load.
      if (!_userSet) state = prefs.getBool(_kKeepAllOnlineKey) ?? false;
    } catch (_) {
      // No prefs (e.g. widget tests) — stay on the safe default (off).
    }
  }

  Future<void> set(bool value) async {
    _userSet = true;
    state = value;
    final prefs = await ref.read(prefsProvider.future);
    await prefs.setBool(_kKeepAllOnlineKey, value);
  }
}

final keepAllOnlineProvider =
    NotifierProvider<KeepAllOnlineController, bool>(KeepAllOnlineController.new);
