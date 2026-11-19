/// Fixed profile-owned preference names, shared by the Flutter backend and
/// the Flutter-free erasure worker. The installation's profile pointer is a
/// separate resource and is deliberately not part of this layout.
abstract final class ProfilePreferencesLayout {
  static const file = 'xveil.prefs.json';
  static const temporary = '$file.tmp';
  static const lock = '$file.lock';
  static const files = <String>{file, temporary, lock};
}
