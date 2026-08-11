// Whether a person can actually READ the 24 words they are told to write down.
//
// The recovery step says, in the app's own words, that these 24 words ARE the
// identity and that losing them loses it forever. On an iPhone 17 Pro
// (402x874) the grid of chips put a fraction of them on screen, clipped flush
// with the row above — no partial row, no scrollbar, nothing saying anything
// followed — and the confirm checkbox that says "I have written them down"
// was pinned OUTSIDE that inner scroll, so it could be ticked without the
// later words ever having been rendered. At 360x640, a real Android floor, the
// step's Column overflowed outright and NOT ONE word was on screen.
//
// The failure is silent, and it is discovered years later at the one moment
// the phrase is needed. So everything here is asserted on RENDERED GEOMETRY:
// the widgets always existed, off screen, which is precisely why a test that
// looks for widgets could not see the defect.
//
// ## Why the size matters and the font does not lie about it
//
// A widget test draws with a placeholder font whose glyphs are roughly one em
// WIDE — about twice a real face — so the prose on this step measures ~550 px
// here against ~200 px on a device. Twenty-four words plus that inflated prose
// do not share an 874 px screen no matter how the words are laid out. Rather
// than pretend otherwise, each size below asserts the honest disjunction: all
// 24 on screen, or an affordance that cannot be missed AND a confirmation the
// person cannot reach without word 24 having passed under their finger. The
// desktop size exercises the first branch, so "they all fit" is a case the
// suite really runs and not a comment.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xveil/data/node/node_controller.dart';
import 'package:xveil/features/onboarding/onboarding_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';
import 'package:xveil/state/providers.dart';

/// A node controller with no timers (FakeNodeController's delayed/periodic
/// timers leak past a widget test).
class _NoopNode implements NodeController {
  @override
  NodeStatus get current => const NodeStatus(phase: NodePhase.connected);
  @override
  Stream<NodeStatus> status() => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> setEconomyMode(bool economy) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Walk the create-identity wizard to the recovery step at [size].
  Future<void> openRecovery(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [nodeControllerProvider.overrideWithValue(_NoopNode())],
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: OnboardingScreen(validatePhrase: (_) => true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    AppL10n l() => AppL10n.of(tester.element(find.byType(OnboardingScreen)));
    await tester.tap(find.text(l().actionContinue));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l().onboardCreateIdentity));
    await tester.pumpAndSettle();
    expect(
      find.text(l().recoveryTitle),
      findsOneWidget,
      reason: 'the walk must land on the recovery step',
    );
  }

  /// The box the words are actually painted into: the scroll viewport they
  /// live in, cropped to the display. A word below the viewport is clipped
  /// away; a word past the display edge is gone. The old layout produced both,
  /// and the viewport is what makes the first kind measurable — a chip sitting
  /// inside the screen but under the edge of its own inner scroll is exactly
  /// the "flush with the container, nothing after it" the person saw.
  Rect visibleBox(WidgetTester tester, Size size) => tester
      .getRect(find.byType(Scrollable).last)
      .intersect(Rect.fromLTWH(0, 0, size.width, size.height));

  Rect wordRect(WidgetTester tester, int number) {
    final row = find.byKey(recoveryWordKey(number - 1));
    expect(
      row,
      findsOneWidget,
      reason: 'word $number must be built at all before it can be seen',
    );
    return tester.getRect(row);
  }

  bool fullyInside(Rect r, Rect box) =>
      r.left >= box.left - 0.5 &&
      r.right <= box.right + 0.5 &&
      r.top >= box.top - 0.5 &&
      r.bottom <= box.bottom + 0.5;

  /// Which of the 24 word rows are FULLY inside [box], and which are not.
  ({List<int> visible, List<int> hidden}) census(
    WidgetTester tester,
    Rect box,
  ) {
    final visible = <int>[];
    final hidden = <int>[];
    for (var n = 1; n <= 24; n++) {
      (fullyInside(wordRect(tester, n), box) ? visible : hidden).add(n);
    }
    return (visible: visible, hidden: hidden);
  }

  for (final probe in const [
    // iPhone 17 Pro, where the live sweep found this.
    (size: Size(402, 874), mustAllFit: false),
    // A real Android floor. The old layout overflowed its Column here and put
    // zero words on screen.
    (size: Size(360, 640), mustAllFit: false),
    // A desktop window — xVeil ships macOS, Linux and Windows too. Tall enough
    // that even the inflated test prose leaves room for all 24, so the
    // "everything is on screen" branch is one the suite actually takes. The
    // old chip grid failed here as well: its 24 chips wanted 776 px inside a
    // 456 px inner scroll.
    (size: Size(402, 1200), mustAllFit: true),
  ]) {
    final size = probe.size;
    final label = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('every one of the 24 words can be read at $label', (
      tester,
    ) async {
      await openRecovery(tester, size);
      final seen = census(tester, visibleBox(tester, size));

      if (probe.mustAllFit || seen.hidden.isEmpty) {
        expect(
          seen.hidden,
          isEmpty,
          reason:
              'these word numbers are off screen with no scrolling: '
              '${seen.hidden.join(", ")}. Someone who copies what they can '
              'see writes down an incomplete phrase, loses the identity, and '
              'does not find out until they try to restore it. '
              '(${seen.visible.length} of 24 visible)',
        );
        return;
      }

      // They do not all fit at this size, so the other half of the promise has
      // to hold instead — and it has to hold in a way the person cannot miss.
      final scroll = find.byType(Scrollable).last;
      final position = tester.state<ScrollableState>(scroll).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: 'words are off screen and the step does not scroll, so they '
            'are simply unreachable',
      );
      expect(
        find.byType(Scrollbar),
        findsOneWidget,
        reason: 'words are off screen and nothing on it says so',
      );
      expect(
        tester.widget<Scrollbar>(find.byType(Scrollbar).first).thumbVisibility,
        isTrue,
        reason: 'a scrollbar that appears only once you scroll cannot tell '
            'you that scrolling is needed — which is exactly how 24 words '
            'looked like 21',
      );

      // The invariant that actually protects the person: the control that
      // claims the backup is done lives BELOW the last word, in the same
      // scroll. Asserted on geometry rather than on tree order, because tree
      // order is not what the finger travels.
      final lastWord = wordRect(tester, 24);
      final confirm = tester.getRect(find.byType(CheckboxListTile));
      expect(
        confirm.top,
        greaterThanOrEqualTo(lastWord.bottom),
        reason: 'the checkbox claiming all 24 words are written down sits '
            'above word 24, so it can be ticked by someone who has never had '
            'word 24 on screen',
      );

      // ...and reaching it genuinely brings word 24 along, so "below the last
      // word" is not merely far below the fold.
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final box = visibleBox(tester, size);
      expect(
        fullyInside(wordRect(tester, 24), box),
        isTrue,
        reason: 'at the bottom of the page, where the confirmation is, word '
            '24 must be readable: ${wordRect(tester, 24)} against $box',
      );
      expect(
        tester.getRect(find.byType(CheckboxListTile)).top,
        greaterThanOrEqualTo(wordRect(tester, 24).bottom),
      );
    });
  }

  testWidgets('the words are in two columns, not one long run', (tester) async {
    // Halving the height is what makes the fit possible at all, and it is a
    // property of the LAYOUT rather than of the words that happened to be
    // drawn: a Wrap of chips sized to their own text gives a ragged block
    // whose height depends on which words came up. Word 13 must start a
    // second column beside word 12, not continue below it.
    await openRecovery(tester, const Size(402, 874));
    final twelve = wordRect(tester, 12);
    final thirteen = wordRect(tester, 13);
    expect(
      thirteen.left,
      greaterThanOrEqualTo(twelve.right),
      reason: 'word 13 must be in a column of its own, clear of word 12',
    );
    expect(
      thirteen.top,
      lessThan(twelve.top),
      reason: 'word 13 must start that column at the top — flowing on below '
          'word 12 is the single-run layout that did not fit',
    );
  });

  testWidgets('the words are numbered and the count is stated', (tester) async {
    // Geometry alone leaves one gap: a person glancing at a screenful has no
    // way to know what a complete list looks like. The number on every row and
    // the sentence naming 24 are what turn "it ended" into "it ended at 21".
    await openRecovery(tester, const Size(402, 874));
    final l = AppL10n.of(tester.element(find.byType(OnboardingScreen)));
    expect(find.text(l.recoveryNumbered), findsOneWidget);
    for (final n in [1, 12, 13, 24]) {
      expect(
        find.descendant(
          of: find.byKey(recoveryWordKey(n - 1)),
          matching: find.text('$n'),
        ),
        findsOneWidget,
        reason: 'word $n must carry its own number, or a partial copy cannot '
            'be told from a complete one',
      );
    }
  });
}
