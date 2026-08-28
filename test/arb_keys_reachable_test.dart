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
/// Also gone: the three hold-to-record hints (`chatVoiceHold`,
/// `chatVoiceSlideCancel`, `chatVoiceReleaseCancel`). The composer records on
/// a TAP and says why — a hold works differently on desktop, and an explicit
/// stop is the same on both — so those three described a gesture the app
/// deliberately does not have, and wiring them up would have documented an
/// interaction that is not there. `groupEmpty` went with them: groups and 1:1
/// conversations share one list, and it has `chatsEmpty`.
///
/// The API-token trio went three different ways, which is the point of doing
/// these one at a time. `settingsApiReadOnlyHint` was a control missing its
/// explanation — the read-only switch said "Read-only" and left the reader to
/// guess whether that stops sending messages or only changing settings — so it
/// is now that switch's subtitle. `settingsApiToken` and
/// `settingsApiRegenerate` are leftovers of the SINGLE-token design: with a
/// list of named tokens there is no bare "API token" label to write, and
/// "Regenerate" is revoke-plus-add, which the screen already offers.
///
/// `chatFileSave` was a third kind again: a control with no name at all. The
/// save button on a video preview is a `GestureDetector` around an icon in a
/// translucent disc — no tooltip, and a screen reader announced nothing where
/// it sits. It is a `Tooltip` now, which carries the semantics label as well
/// as the hover text.
///
/// `folderSyncNever` was the strongest case of that kind yet: the DATA was
/// there too. `lastPassAtMs` is carried all the way into the folder-sync
/// view and was never rendered, so a mirror never said when it last ran and
/// the string for "not yet" sat unused. It is the row's second subtitle line
/// now — and wiring it turned up that `formatAgo` returned English to
/// everyone, inside a localised sentence, which is the shape that hides an
/// untranslated value.
///
/// `voiceModelTitle` went the other way: the speech-model tile is titled by
/// its STATE ("Downloading…", "Speech model installed", "Download the speech
/// model"), so there is no static title to write.
///
/// `spaceMemberMute` was a label for an action this list does not offer: the
/// member menu can UNMUTE, and muting happens on the moderation surface,
/// which has its own wording. Deleting it turned up a bare `volume_off` icon
/// that a viewer with no actions to offer sees on its own — no tooltip, and a
/// screen reader announcing nothing. It says `spaceMemberMuted` now, the same
/// string the row's subtitle already uses.
///
/// Three more, three different answers again. `provisionNeedUrl` is now the
/// release-URL field's errorText: `isSafeHttpsUrl` decides that question and
/// was only consulted deeper in, so a plain-http or malformed URL was taken
/// here and failed somewhere the reader could not connect to what they had
/// typed. `nicknameOwnedTitle` is deleted — that screen has no section
/// headings at all, and a lone "Your name" above a card already showing
/// `@name` under an at-sign icon would be the only one.
/// `spaceAccessRolePermissions` is deleted too: the permission count it
/// carries is inside `spaceAccessRoleGrantSummary`, which the row uses, since
/// areas were added beside it.
///
/// `chatMoreActions` names a gesture, which is a fourth kind again. A
/// conversation's actions are behind a long press and a right-click with
/// nothing on screen saying so, and a screen reader announced the row as a
/// plain tap target — so for its users those actions did not exist. It is the
/// row's `onLongPressHint` now, which is what VoiceOver and TalkBack read out
/// for that gesture, and it changes nothing visually.
///
/// `chatListDelete` ("Delete chat") is deleted: the sheet says "Delete
/// conversation" and uses `chatMenuDeleteConversation` for it.
///
/// `newChatPeerOrNickname` ("Node id (hex) or @name") is deleted because it
/// was WRONG, which is a fifth kind. The paste field takes an invite link, a
/// peers-share token and an `@name`; anything else — a bare node id
/// included — goes to the invite parser and comes back "invalid invite".
/// Wiring the string up would have promised something the field refuses. The
/// field did need to say what it takes, so it does now, accurately.
///
/// `groupCallTitle` was a hex id wearing a title. The overlay used
/// `groupId.short` whenever the room had no name — and `stateOf` is a future,
/// so that id also flashed on the first frame of EVERY call before the name
/// arrived. The rule now lives in `groupCallTitleFor`, which is a function
/// rather than three lines inside a `FutureBuilder` because that is the
/// difference between something assertable and something needing the whole
/// app mounted around a live call to look at.
///
/// What is left falls into three groups, and each wants a different answer:
///  * text kept ON PURPOSE for a row that was removed rather than shipped
///    half-done — `networkExt*` and `networkComingLater`; see the comment in
///    network_screen.dart, which explains that a chevron leading to a "coming
///    later" snackbar reads as a feature that exists and is switched off. The
///    strings stay so restoring the row costs one widget, not a translation
///    round;
///  * a message for a rule that does not exist. `groupVoiceTooLong` asked
///    whether the LIMIT was missing rather than the string, and the answer is
///    that the limit went on purpose: a group voice clip is registered in the
///    content store and the message carries only its reference, precisely so
///    there is no inline clear-media fallback at any clip length. Length
///    stopped mattering and the refusal outlived it. Gone, with
///    `cloudNoteSaved` (the editor POPS on success — returning to a list with
///    the note in it is the confirmation, and a notice it closes before
///    showing is not) and `nodeOperationSuccess` (the SSH dialog already
///    prints the output and the exit-code line);
///  * `spaceRenameDenied` WAS listed here, on the reasoning that `renameGroup`
///    answers with a bare bool so the screen could not tell a denial from a
///    network failure, and that wiring the string in would mean claiming "no
///    permission" for a dropped connection. Attempted, and the reason did not
///    hold: the broadcast is unawaited and never decides that bool, so a
///    network failure is not among the answers — while the refusal IS knowable
///    from the same ACL that decides whether to draw the button at all. It is
///    wired, and the generic sentence it used to get told the user to check a
///    network that had nothing to do with it (report17);
///  * one-off labels a refactor left behind. Checked one at a time, they
///    turned out to want six different answers, which is why none of this was
///    a sweep: a duplicate to delete, a control that lost its name, a control
///    that lost its EXPLANATION, a gesture no screen reader announced, data
///    that reached the screen and was never drawn, and one string that was
///    simply WRONG about what its field accepts.
///
/// The last three settled here: `routeRestartNode` labels a button this screen
/// does not have — it says "changes apply the next time the node starts",
/// which is true, and restarting lives on the node screen; `callScreens`
/// (plural) is a tab for several shared screens, and a call has one;
/// `actionUnderstood` is an acknowledge button for a dialog that acknowledges
/// with the platform's own OK. `devicesFreshRegistryRequired` was the
/// opposite — a real answer being thrown away, see the recovery sheet.
const _knownUnreachable = {
  'networkComingLater',
  'networkExtSub',
  'networkExtTitle',
};
