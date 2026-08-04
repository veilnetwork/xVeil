import 'package:flutter_test/flutter_test.dart';
import 'package:veil_flutter/veil_flutter.dart' as sdk;
import 'package:xveil/data/transport/veil_transport.dart';

/// Audit X/V-01, the seam between veil's answer and this app's question.
///
/// `SenderProvenance` is now defined twice: once by `veil_flutter` (its decode
/// of the byte veil puts on the IPC wire) and once by this app's transport port.
/// `VeilFlutterTransport` does NOT map them member-to-member — it re-decodes the
/// SDK value through this app's `fromWire`, so both definitions are held to the
/// same wire bytes and the translation cannot drift into a silent upgrade.
///
/// These tests are what makes that safe. Without them, veil renumbering a level
/// (or this app doing so) would keep compiling and start answering the wrong
/// question at every gate built on the result.
void main() {
  group('SenderProvenance crosses the SDK boundary by wire byte', () {
    test('every SDK level re-decodes to the SAME app level', () {
      const pairs = <sdk.SenderProvenance, SenderProvenance>{
        sdk.SenderProvenance.claimed: SenderProvenance.claimed,
        sdk.SenderProvenance.localIpc: SenderProvenance.localIpc,
        sdk.SenderProvenance.sessionPeer: SenderProvenance.sessionPeer,
        sdk.SenderProvenance.signed: SenderProvenance.signed,
      };
      // Every level of BOTH enums is covered, so a new level on either side
      // fails here instead of arriving as a silent `claimed`.
      expect(pairs.length, sdk.SenderProvenance.values.length);
      expect(pairs.length, SenderProvenance.values.length);
      for (final entry in pairs.entries) {
        expect(
          SenderProvenance.fromWire(entry.key.wireByte),
          entry.value,
          reason:
              'the SDK level ${entry.key.name} (byte ${entry.key.wireByte}) '
              'must reach the app as ${entry.value.name}',
        );
      }
    });

    test('authentication survives the crossing in both directions', () {
      // The property every gate actually reads. A translation that preserved
      // the NAMES but flipped this would pass the test above.
      for (final level in sdk.SenderProvenance.values) {
        expect(
          SenderProvenance.fromWire(level.wireByte).isAuthenticated,
          level.isAuthenticated,
          reason: '${level.name} changed meaning while crossing the boundary',
        );
      }
    });

    test('a level this build does not know arrives as claimed', () {
      // Fail-closed on this side too, not merely inside the SDK: "I could not
      // read the evidence" and "there was no evidence" must decide the same.
      final known = {
        for (final level in sdk.SenderProvenance.values) level.wireByte,
      };
      for (var byte = 0; byte <= 255; byte++) {
        if (known.contains(byte)) continue;
        expect(
          SenderProvenance.fromWire(byte),
          SenderProvenance.claimed,
          reason: 'byte $byte must read as claimed',
        );
        expect(SenderProvenance.fromWire(byte).isAuthenticated, isFalse);
      }
    });
  });
}
