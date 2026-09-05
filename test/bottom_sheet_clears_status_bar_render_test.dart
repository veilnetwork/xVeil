import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Does `useSafeArea: true` actually keep a tall sheet off the status bar?
///
/// The other test in this suite reads the source and checks the flag is there.
/// That guards against somebody writing a new sheet without it — and it proves
/// nothing about what Flutter does with it. This one renders a sheet taller
/// than the screen under a real status-bar inset and measures where its top
/// edge lands, because the bug being fixed was reported from a phone and the
/// fix has to hold on one.
void main() {
  const inset = 48.0;

  Future<Rect> sheetRect(WidgetTester tester, {required bool useSafeArea}) async {
    // ON THE VIEW, not in a MediaQuery below the app.
    //
    // A modal bottom sheet is a route on the Navigator, and the MediaQuery it
    // consults is the one ABOVE that Navigator — the app's, derived from the
    // view. A MediaQuery wrapped around `home` is below it and the route never
    // sees it, so the first version of this test measured a sheet that had no
    // status bar to avoid and reported the fix as broken.
    //
    // Padding on the view is in PHYSICAL pixels.
    tester.view.padding = FakeViewPadding(top: inset * tester.view.devicePixelRatio);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    useSafeArea: useSafeArea,
                    builder: (_) => const SingleChildScrollView(
                      // Taller than any test viewport, which is the case that
                      // makes the sheet reach the top at all.
                      child: SizedBox(
                        height: 4000,
                        key: ValueKey('tall-sheet'),
                        child: Text('Rename'),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return tester.getRect(find.byKey(const ValueKey('tall-sheet')));
  }

  testWidgets('a sheet taller than the screen starts below the status bar', (
    tester,
  ) async {
    final rect = await sheetRect(tester, useSafeArea: true);
    expect(
      rect.top,
      greaterThanOrEqualTo(inset),
      reason:
          'the first row of the sheet is under the clock and the battery icon '
          '— which is what the phone screenshot showed',
    );
  });

  testWidgets('CONTROL: without the flag it does reach the top', (
    tester,
  ) async {
    // The vacuity guard. If a sheet never reached the top in this harness, the
    // test above would pass on a fix that does nothing.
    final rect = await sheetRect(tester, useSafeArea: false);
    expect(
      rect.top,
      lessThan(inset),
      reason:
          'the harness never reproduced the overlap, so the test above proves '
          'nothing — re-aim it',
    );
  });
}
