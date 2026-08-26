import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/secure_screen.dart';
import 'package:xveil/features/network/ssh_private_key_field.dart';

/// Every OTHER secret on the SSH screens is one line and is obscured — the SSH
/// password, the key passphrase, the space password. A PEM cannot be: Flutter's
/// `obscureText` forces `maxLines: 1`, and a private key rendered as one
/// unreadable line is a key nobody can check they pasted correctly.
///
/// So all four SSH screens drew it in a monospace box in plain sight, on routes
/// nothing protected — while the obscured password beside it gave up nothing. A
/// recording, a task-switcher snapshot or a shoulder took the key that opens
/// root on the operator's server.
///
/// The field now carries the guard the onboarding phrase step already uses for
/// the same shape, and it lives in ONE widget: four bare copies in four files is
/// how the first one stayed bare.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('the flag is held while a key can be on screen', (tester) async {
    final calls = <bool>[];
    final channel = MethodChannel(SecureScreen.channelName);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'setSecure') {
        calls.add((call.arguments as Map)['secure'] as bool);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    final screen = SecureScreen(channel: channel);
    expect(screen.engaged, isFalse, reason: 'premise: nothing held yet');

    await tester.pumpWidget(
      host(
        SshPrivateKeyField(
          controller: TextEditingController(),
          labelText: 'key',
          controllerOverride: screen,
        ),
      ),
    );
    await tester.pump();
    expect(
      screen.engaged,
      isTrue,
      reason: 'a pasted PEM is readable on screen; the route must be protected',
    );
    expect(calls, contains(true), reason: 'and the platform was actually told');

    // Gone when the sheet closes — the flag also blacks out this app's own
    // screen sharing, so holding it after the field leaves would break a
    // feature that has nothing to do with SSH.
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();
    expect(screen.engaged, isFalse);
    expect(calls.last, isFalse);
  });

  testWidgets('the key stays readable — obscuring is not the fix', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        SshPrivateKeyField(
          controller: TextEditingController(text: '-----BEGIN'),
          labelText: 'key',
        ),
      ),
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.obscureText,
      isFalse,
      reason:
          'a PEM collapsed to one masked line cannot be checked after pasting',
    );
    expect(field.maxLines, greaterThan(1));
  });

  /// The invariant, not the four instances: a fifth screen that hand-rolls the
  /// field would be bare again. Reads the OTHER files rather than its own
  /// source, so no assertion here can be satisfied by this file's own prose.
  test('no secret input in lib/features is left unmasked and unguarded', () {
    final secretish = RegExp(
      r'_(key|privateKey|pem|password|passphrase|secret|psk)\b',
      caseSensitive: false,
    );
    final offenders = <String>[];
    var obscuredSeen = 0;
    for (final entity in Directory('lib/features').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      for (final m in RegExp(
        r'TextField\((.*?)\n\s*\),',
        dotAll: true,
      ).allMatches(src)) {
        final body = m.group(1)!;
        final ctrl = RegExp(r'controller:\s*(\w+)').firstMatch(body);
        if (ctrl == null || !secretish.hasMatch(ctrl.group(1)!)) continue;
        if (body.contains('obscureText: true')) {
          obscuredSeen++;
        } else {
          offenders.add('${entity.path} (${ctrl.group(1)})');
        }
      }
    }
    // Premise: the scan finds the masked ones, so an empty offender list is a
    // statement about the code and not about a regex that matches nothing.
    expect(
      obscuredSeen,
      greaterThan(5),
      reason: 'the scan must actually be finding secret fields',
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'an unobscured secret field must go through SshPrivateKeyField, '
          'which carries the screenshot guard with it',
    );
  });
}
