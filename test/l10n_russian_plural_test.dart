import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/l10n/app_localizations_ru.dart';

/// Russian puts 21, 31, 101 … in the SAME plural category as 1. A branch that
/// spells the number out as a literal "1" instead of substituting the count is
/// therefore not a harmless shortcut: it renders 21 items as "1 объект".
///
/// Twelve strings had exactly that, found by opening the storage screen on a
/// device holding 21 files and reading "1 объект" back. Unit tests never saw it
/// because they count in ones and twos.
void main() {
  final ru = AppL10nRu();

  test('a count ending in 1 is not rendered as one', () {
    expect(ru.cloudUsageItems(21), contains('21'));
    expect(ru.cloudUsageItems(1), '1 объект');
    expect(ru.cloudUsageNotHeldHere(21), contains('21'));
    expect(ru.cloudReplicas(21), contains('21'));
    expect(ru.cloudFolderItems(21), contains('21'));
    expect(ru.cloudNoteBranches(21), contains('21'));
    expect(ru.cloudBulkDeleteTitle(21), contains('21'));
    expect(ru.groupMembers(21), contains('21'));
    expect(ru.spaceMembers(21), contains('21'));
    expect(ru.stickerImported(21), contains('21'));
    expect(ru.spaceDiscoveryResults(21), contains('21'));
    expect(ru.spaceDiscoveryPosts(21), contains('21'));
    expect(ru.spaceDiscoverySources(21), contains('21'));
  });

  test('101 and 31 behave like 21, and 11 keeps the many form', () {
    expect(ru.cloudUsageItems(101), contains('101'));
    expect(ru.cloudUsageItems(31), contains('31'));
    // 11 is the exception Russian makes to the rule above: it is NOT "one".
    expect(ru.cloudUsageItems(11), contains('11'));
  });
}
