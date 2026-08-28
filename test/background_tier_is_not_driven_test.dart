import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A tripwire on a lever the app does not pull.
///
/// `VeilClient.setBackgroundMode` scales the daemon's keepalives and
/// suppresses its background maintenance; it exists end to end, down to
/// `veil_set_background_mode` in the FFI. This app never calls it. Its
/// lifecycle observers cover the privacy screen and calls, neither of which
/// tells the node it went to the background, and the plugin carries no
/// observer of its own — so the tier is simply never set.
///
/// Three no-op `setEconomyMode` implementations described that lever as the
/// thing driving the scaling, which is what made an unattended gap read as an
/// arrangement already in place (report17). This fails the day somebody wires
/// it, so those comments are rewritten rather than left contradicting the
/// code — and it fails just as loudly if the lever disappears, so it cannot
/// quietly become a test about nothing.
void main() {
  test('nothing in the app drives the background tier yet', () {
    final callers = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final line in source.split('\n')) {
        // A call, not a mention: the notes about this lever name it in prose.
        if (line.contains('.setBackgroundMode(')) callers.add('${file.path}: $line');
      }
    }

    expect(
      callers,
      isEmpty,
      reason:
          'the background tier is now driven from ${callers.join("; ")} — update '
          'the setEconomyMode comments in subprocess_node_controller.dart, '
          'embedded_node.dart and fake_node_controller.dart, which say it is not, '
          'and retire this guard',
    );
  });

  test('CONTROL: the lever this is about still exists', () {
    // Without this the guard above passes forever by finding no callers of a
    // method that no longer exists, which is a green test about nothing.
    final client = File(
      'third_party/veil/flutter/veil_flutter/lib/src/client.dart',
    );
    expect(
      client.existsSync(),
      isTrue,
      reason: 'the plugin moved; re-anchor this guard',
    );
    expect(
      client.readAsStringSync(),
      contains('Future<void> setBackgroundMode('),
      reason: 'the plugin no longer exposes the tier this guard is written about',
    );
  });
}
