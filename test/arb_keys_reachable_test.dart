import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every string the app ships must be reachable from its interface.
///
/// A key nobody reads costs each language its share of 1751 strings for
/// nothing — and worse, it hides the opposite mistake: a string written into
/// the ARB for a control that was never wired up. That happened here. The
/// language chooser for voice transcription lived on an unlabelled long press,
/// the string meant to name it was added to both ARB files in the same change,
/// and nothing noticed for a week because a translated orphan looks exactly
/// like a translated string.
///
/// So this is a gate, not a report. The known-unreachable list below may
/// SHRINK and must never grow: a new key with no call site fails here, on the
/// commit that adds it, while the author still remembers what it was for.
void main() {
  final template =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
  final keys = template.keys.where((k) => !k.startsWith('@')).toSet();

  /// Everything the UI could name — generated localisations excluded, since
  /// they define the getters rather than call them.
  String uiSources() {
    final buffer = StringBuffer();
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains('${Platform.pathSeparator}l10n${Platform.pathSeparator}')) {
        continue;
      }
      buffer.writeln(entity.readAsStringSync());
    }
    return buffer.toString();
  }

  Set<String> referenced(String source) => RegExp(r'\.([a-zA-Z_][a-zA-Z0-9_]*)')
      .allMatches(source)
      .map((m) => m.group(1)!)
      .toSet();

  test('a new string must have a call site', () {
    final unreachable = keys.difference(referenced(uiSources()));
    final surprises = unreachable.difference(_knownUnreachable);
    expect(
      surprises,
      isEmpty,
      reason:
          'these keys are in the ARB but nothing in lib/ reads them:\n'
          '  ${surprises.join("\n  ")}\n'
          'Either wire the string up, or delete it from every ARB. Adding it '
          'to the known list below is for strings that already shipped '
          'unreachable, not for new ones.',
    );
  });

  test('the known-unreachable list does not rot', () {
    // A list of exceptions nobody prunes stops being a list of exceptions and
    // becomes a place to hide. Two ways it rots, both caught here: an entry
    // for a key that has since been wired up, and an entry for a key that no
    // longer exists at all.
    final unreachable = keys.difference(referenced(uiSources()));
    final nowReachable = _knownUnreachable.intersection(keys).difference(
      unreachable,
    );
    expect(
      nowReachable,
      isEmpty,
      reason: 'these are used now — remove them from the known list:\n'
          '  ${nowReachable.join("\n  ")}',
    );
    final gone = _knownUnreachable.difference(keys);
    expect(
      gone,
      isEmpty,
      reason: 'these keys no longer exist — remove them from the known list:\n'
          '  ${gone.join("\n  ")}',
    );
  });
}

/// Strings that were already unreachable when this gate was written
/// (2026-08-10). Not an approval — a debt, recorded so it cannot grow.
///
/// Already paid down: the six group-composer duplicates (the group screen uses
/// the SAME MessageComposer as a 1:1 chat and labels it with the chat keys),
/// two section titles the category layout replaced, fileDownloadTitle, which turned out to
/// be the right name for an unnamed download button, and nodeRemoveConfirm,
/// which turned out to be a confirmation nobody was being asked for.
///
/// What is left falls into three groups, and each wants a different answer:
///  * text kept ON PURPOSE for a row that was removed rather than shipped
///    half-done — `networkExt*` and `networkComingLater`; see the comment in
///    network_screen.dart, which explains that a chevron leading to a "coming
///    later" snackbar reads as a feature that exists and is switched off. The
///    strings stay so restoring the row costs one widget, not a translation
///    round;
///  * a message for a rule that does not exist — `groupVoiceTooLong` describes
///    a refusal, and nothing in the app enforces a group voice-clip limit, so
///    the question is whether the LIMIT is missing rather than the string;
///  * one-off labels a refactor left behind (`chatFileSave`, `sshDone`,
///    `chatListDelete`, …). These want checking one at a time: a duplicate of
///    a label the screen already uses can go, but "More actions" or "Delete
///    chat" may be a control that lost its name rather than a string that lost
///    its control — and those two mistakes need opposite fixes.
const _knownUnreachable = {
  'actionUnderstood',
  'callScreens',
  'chatFileSave',
  'chatListDelete',
  'chatMoreActions',
  'chatVoiceHold',
  'chatVoiceReleaseCancel',
  'chatVoiceSlideCancel',
  'cloudNoteSaved',
  'devicesFreshRegistryRequired',
  'folderSyncNever',
  'groupCallTitle',
  'groupEmpty',
  'groupVoiceTooLong',
  'networkComingLater',
  'networkExtSub',
  'networkExtTitle',
  'newChatPeerOrNickname',
  'nicknameOwnedTitle',
  'nodeOperationSuccess',
  'peersShareSelectOne',
  'provisionNeedUrl',
  'routeExitNodeHint',
  'routeRestartNode',
  'settingsApiReadOnlyHint',
  'settingsApiRegenerate',
  'settingsApiToken',
  'spaceAccessRolePermissions',
  'spaceMemberMute',
  'spaceRenameDenied',
  'sshDone',
  'voiceModelTitle',
};
