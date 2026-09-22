// A linked device can only dial its master by a name the master publishes.
//
// A device group names its owner by the IDENTITY, which resolves to ONE device
// and travels by the mailbox — measured on the two-device stand as 166 sends
// out of 166 by that name and not one live. The master already announces its
// identity document keyed by its own DEVICE id; marking that row as the
// owner's is what turns the journal both devices already share into an address
// book. These are the two halves of that: the pure rewrite, and the guarantee
// that every site which announces the row carries the mark.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/core/ids.dart';
import 'package:xveil/state/group_service.dart';

NodeId _id(int seed) => NodeId(Uint8List.fromList(List.filled(32, seed)));

void main() {
  final owner = _id(0x09);
  final master = _id(0xD7);
  final sibling = _id(0x03);

  group('addressedByDevice', () {
    test('the owner entry becomes the master device, the rest is untouched', () {
      expect(
        addressedByDevice(
          recipients: [sibling, owner],
          owner: owner,
          masterDevice: master,
        ),
        [sibling, master],
      );
    });

    test('an unnamed master leaves the list exactly as the scan built it', () {
      // The compatibility story, and the reason a mixed pair keeps working: an
      // older master never writes the mark, so the identity stands.
      expect(
        addressedByDevice(
          recipients: [sibling, owner],
          owner: owner,
          masterDevice: null,
        ),
        [sibling, owner],
      );
    });

    test('a master whose device IS the owner changes nothing', () {
      // A device booted on the master key has one value for both names. The
      // rewrite must not turn that into a second, identical recipient.
      expect(
        addressedByDevice(
          recipients: [sibling, owner],
          owner: owner,
          masterDevice: owner,
        ),
        [sibling, owner],
      );
    });

    test('a list without the owner in it is returned unchanged', () {
      // What the MASTER's own scan produces: the owner is dropped before this
      // is ever called, and nothing here may invent it.
      expect(
        addressedByDevice(
          recipients: [sibling],
          owner: owner,
          masterDevice: master,
        ),
        [sibling],
      );
    });
  });

  group('syncReplyTarget', () {
    // MEASURED, 2026-09-22. The master logged `sync serve to 636e6538: 5 row(s)`
    // — the IDENTITY — while the linked device's fold sat on a row from the
    // previous boot for six minutes. A linked device's frames arrive under the
    // identity, that resolves to one device, and the answer went to the
    // responder's own node.
    final peerIdentity = _id(0x11);
    final asker = _id(0x12);
    final stranger = _id(0x13);
    final members = [peerIdentity, asker];

    test('a device named in my own device group takes the answer', () {
      expect(
        syncReplyTarget(
          isDeviceGroup: true,
          members: members,
          peer: peerIdentity,
          claimed: asker.hex,
        ),
        asker,
      );
    });

    test('a device that is NOT a member cannot steer the answer', () {
      // The whole of this rule's safety. A claim ABOUT ONESELF decides where
      // bytes go, so it is believed only for a member of my own device group.
      expect(
        syncReplyTarget(
          isDeviceGroup: true,
          members: members,
          peer: peerIdentity,
          claimed: stranger.hex,
        ),
        peerIdentity,
      );
    });

    test('an ordinary group never redirects', () {
      expect(
        syncReplyTarget(
          isDeviceGroup: false,
          members: members,
          peer: peerIdentity,
          claimed: asker.hex,
        ),
        peerIdentity,
      );
    });

    test('a missing or malformed claim leaves the sender as the answer', () {
      for (final claimed in <Object?>[
        null,
        '',
        'zz',
        42,
        asker.hex.substring(2),
      ]) {
        expect(
          syncReplyTarget(
            isDeviceGroup: true,
            members: members,
            peer: peerIdentity,
            claimed: claimed,
          ),
          peerIdentity,
          reason: 'claim $claimed changed the address',
        );
      }
    });
  });

  test('every announcement of the identity document carries the owner mark', () {
    // WHY A SOURCE GUARD. The fold keeps the newest event per (kind, key), so
    // a single unmarked re-announcement from the master retires its own mark
    // and drops every linked device back to addressing the identity — silently,
    // and with no failing behaviour anywhere until someone measures the wire.
    // The sites are far apart (the sync bridge, the devices screen, the soak
    // hook) and a fourth is one copy-paste away, so the guard is on the shape
    // of the call rather than on any one caller's behaviour.
    final roots = [Directory('lib')];
    final sites = <String>[];
    final unmarked = <String>[];
    for (final root in roots) {
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('kind: DeviceSyncKind.identityDoc,')) continue;
          final where = '${entity.path}:${i + 1}';
          sites.add(where);
          // The payload follows the kind within a couple of lines in every
          // shape this call takes.
          final window = lines
              .sublist(i, (i + 6).clamp(0, lines.length))
              .join('\n');
          if (!window.contains("if (ownsGroup) 'o': true")) {
            unmarked.add(where);
          }
        }
      }
    }
    // VACUITY: a guard that finds no sites proves nothing. The count is the
    // assertion's subject, so a site that disappears is news too.
    expect(
      sites.length,
      greaterThanOrEqualTo(3),
      reason:
          'the scan found ${sites.length} announcement sites — it used to find '
          'three, so either the guard stopped matching or a caller was lost',
    );
    expect(
      unmarked,
      isEmpty,
      reason:
          'these announce the identity document without the owner mark, so a '
          'master running them retires its own address and every linked device '
          'falls back to the mailbox',
    );
  });
}
