import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/domain/file_download_policy.dart';

void main() {
  const mb = 1024 * 1024;

  test('allowsAuto: size cap + blocked types', () {
    const p = FileDownloadPolicy(autoMaxBytes: 2 * mb, blockedExts: {'apk'});
    expect(p.allowsAuto(mb, 'photo.png'), isTrue, reason: 'small + allowed');
    expect(p.allowsAuto(5 * mb, 'photo.png'), isFalse, reason: 'over cap → offer');
    expect(p.allowsAuto(mb, 'app.apk'), isFalse, reason: 'blocked type → offer');
    expect(p.allowsAuto(mb, 'APP.APK'), isFalse, reason: 'case-insensitive');
    expect(p.allowsAuto(null, 'x.png'), isFalse, reason: 'unknown size → offer');
    expect(p.allowsAuto(mb, null), isTrue, reason: 'no name → only size gates');
  });

  test('autoMaxBytes 0 ⇒ always ask (offer everything non-empty)', () {
    const p = FileDownloadPolicy(autoMaxBytes: 0, blockedExts: {});
    expect(p.allowsAuto(1, 'x.txt'), isFalse);
    expect(p.allowsAuto(5 * mb, 'x.txt'), isFalse);
  });

  test('extensionOf / normalizeExt', () {
    expect(FileDownloadPolicy.extensionOf('a.b.PNG'), 'png');
    expect(FileDownloadPolicy.extensionOf('noext'), isNull);
    expect(FileDownloadPolicy.extensionOf('trailing.'), isNull);
    expect(FileDownloadPolicy.normalizeExt('  .APK '), 'apk');
    expect(FileDownloadPolicy.normalizeExt('...sh'), 'sh');
    expect(FileDownloadPolicy.normalizeExt('   '), isNull);
  });

  test('json round-trips; corrupt blob degrades to defaults, never throws', () {
    final p =
        FileDownloadPolicy(autoMaxBytes: 8 * mb, blockedExts: {'exe', 'sh'});
    final back = FileDownloadPolicy.fromJson(p.toJson());
    expect(back, p, reason: 'value equality after round-trip');
    // Missing fields → defaults.
    final partial = FileDownloadPolicy.fromJson({'max': 123});
    expect(partial.autoMaxBytes, 123);
    expect(partial.blockedExts, FileDownloadPolicy.defaultBlockedExts);
    // Junk types → defaults, no throw.
    final junk = FileDownloadPolicy.fromJson({'max': 'oops', 'block': 'nope'});
    expect(junk.autoMaxBytes, FileDownloadPolicy.defaultAutoMaxBytes);
    expect(junk.blockedExts, FileDownloadPolicy.defaultBlockedExts);
  });

  test('blocked exts stored normalized (deduped, dot-stripped, lowercased)', () {
    final p = FileDownloadPolicy.fromJson({
      'max': mb,
      'block': ['.APK', 'apk', 'Exe', '  ', '.sh.'],
    });
    expect(p.blockedExts, {'apk', 'exe', 'sh.'});
  });

  test('defaults are the safe Phase-A1 policy', () {
    expect(FileDownloadPolicy.defaults.autoMaxBytes, 2 * mb);
    expect(FileDownloadPolicy.defaults.blockedExts, contains('apk'));
    expect(FileDownloadPolicy.defaults.blockedExts, contains('exe'));
  });

  test('largeFileMode: defaults to ASK, round-trips, copyWith, equality', () {
    expect(FileDownloadPolicy.defaults.largeFileMode, LargeFileMode.ask);
    final open =
        FileDownloadPolicy.defaults.copyWith(largeFileMode: LargeFileMode.open);
    expect(open.largeFileMode, LargeFileMode.open);
    expect(FileDownloadPolicy.fromJson(open.toJson()).largeFileMode,
        LargeFileMode.open);
    expect(open, isNot(FileDownloadPolicy.defaults), reason: 'mode in equality');
    // Missing / junk mode → ASK (fail safe, not unencrypted).
    expect(FileDownloadPolicy.fromJson({'max': mb}).largeFileMode,
        LargeFileMode.ask);
    expect(FileDownloadPolicy.fromJson({'max': mb, 'lfm': 'nope'}).largeFileMode,
        LargeFileMode.ask);
  });
}
