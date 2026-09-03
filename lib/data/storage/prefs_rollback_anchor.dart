import 'package:shared_preferences/shared_preferences.dart';

import 'rollback_anchor.dart';

/// The rollback anchor, kept in this profile's preference file.
///
/// That file is outside the container, is written 0600, and — the point of
/// all this — is not restored when somebody puts an older copy of the
/// container back. See [RollbackAnchorStore], and read the honest limits at
/// the top of `rollback_anchor.dart`: this stops a container that was
/// restored, synced backwards or copied back, not an adversary who puts the
/// whole disk back at once.
///
/// ONE key, for the one acknowledged space. Never a key per space: a second
/// entry appearing when a second password is typed would announce that a
/// second space exists, which is the thing the container is built to deny.
class PrefsRollbackAnchorStore implements RollbackAnchorStore {
  const PrefsRollbackAnchorStore(this._prefs);

  final SharedPreferences _prefs;

  static const String _key = 'hv.anchor.commit_seq';

  @override
  Future<int?> read() async {
    final seq = _prefs.getInt(_key);
    // A negative value is not an anchor. Treat it as absent rather than as a
    // commit nothing can be behind.
    return (seq == null || seq < 0) ? null : seq;
  }

  @override
  Future<void> write(int seq) async {
    if (seq < 0) return;
    await _prefs.setInt(_key, seq);
  }
}
