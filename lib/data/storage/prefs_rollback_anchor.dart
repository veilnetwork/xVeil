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
  Future<AnchorRecord?> read() async =>
      AnchorRecord.decode(_prefs.getString(_key));

  @override
  Future<bool> write(AnchorRecord record) async {
    if (record.seq < 0 || record.generation.isEmpty) return false;
    // The answer is the platform's, not a guess: `setString` reports whether
    // the write landed, and an anchor that did not land leaves the next
    // launch measuring against a commit this device has already moved past
    // (report22 XV-RA4).
    return _prefs.setString(_key, record.encode());
  }
}
