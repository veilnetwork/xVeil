import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/state/background_node_controller.dart';

void main() {
  test('defaults off and toggles state', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(c.read(backgroundNodeProvider), isFalse);

    await c.read(backgroundNodeProvider.notifier).set(true);
    expect(c.read(backgroundNodeProvider), isTrue);

    await c.read(backgroundNodeProvider.notifier).set(false);
    expect(c.read(backgroundNodeProvider), isFalse);
  });

  test('applyIfNodeUp is a safe no-op off-Android', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // Never throws regardless of nodeUp (VeilBackground is a no-op off-Android).
    await c.read(backgroundNodeProvider.notifier).applyIfNodeUp(nodeUp: true);
    await c.read(backgroundNodeProvider.notifier).applyIfNodeUp(nodeUp: false);
  });
}
