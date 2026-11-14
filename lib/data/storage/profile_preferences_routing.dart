import 'dart:io' show Platform;

import 'app_profile.dart';

/// The last segment of [path], the way the HOST names paths.
///
/// `split('/').last` was wrong on Windows, where `Directory.listSync` hands
/// back `C:\…\profiles\decoy` and the whole string came back as the "name" — so
/// no directory there was ever recognised as a profile and every suffixed key
/// migrated into the default profile, which is precisely the profile those
/// values must stay away from (audit X-04).
///
/// Only Windows treats `\` as a separator. On POSIX a backslash is an ordinary
/// character in a file name, and splitting on it there would invent segments
/// that do not exist. [windows] is a parameter rather than a read of
/// `Platform`, because a Windows path is not something a test on this machine
/// can otherwise produce.
String lastPathSegment(String path, {bool? windows}) {
  var cut = path.lastIndexOf('/');
  if (windows ?? Platform.isWindows) {
    final back = path.lastIndexOf('\\');
    if (back > cut) cut = back;
  }
  return cut < 0 ? path : path.substring(cut + 1);
}

/// Which profile a legacy key belongs to, and the key with the suffix removed.
///
/// LONGEST suffix wins, which is why [known] is sorted here rather than
/// iterated in whatever order it arrived. With profiles `a` and `x.a` both on
/// the device, the first match against `proxy_routing.x.a` could be `.a` — and
/// the value, a routing policy, went to profile `a` under the invented key
/// `proxy_routing.x` (audit X-04). Only the longest match names a real profile;
/// every shorter one is a suffix of that name.
({String owner, String key}) routeLegacyKey(String bare, Set<String> known) {
  final byLength =
      known.where((name) => name != AppProfiles.defaultName).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  for (final name in byLength) {
    if (bare.endsWith('.$name')) {
      return (
        owner: name,
        key: bare.substring(0, bare.length - name.length - 1),
      );
    }
  }
  return (owner: AppProfiles.defaultName, key: bare);
}
