import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/app.dart';

void main() {
  testWidgets('boots to the splash screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: XVeilApp()));
    await tester.pump();
    // Splash shows the brand mark while bootstrapping.
    expect(find.byIcon(Icons.shield_moon_outlined), findsOneWidget);
  });
}
