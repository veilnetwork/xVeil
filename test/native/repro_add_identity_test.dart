import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hidden_volume/hidden_volume.dart' as hv;
import 'package:xveil/core/ids.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'package:xveil/data/storage/hv_kv_log_store.dart';
import 'package:xveil/data/storage/hv_native.dart';
import 'package:xveil/domain/identity.dart';
import 'package:xveil/domain/roster.dart';

/// Reproduce the live addIdentity sequence on a real container and check that
/// ALL THREE spaces survive (first identity, master, new child).
void main() {
  final skip = ensureHiddenVolumeLoaded() ? null : 'no dylib';
  NodeId nid(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

  test('addIdentity keeps the first identity + master openable', () async {
    // Use /tmp (a symlink on macOS) deliberately — the path shape the live app
    // uses, which a filesystem-stat-based create/add decision mis-handled.
    final dir = Directory('/tmp').createTempSync('xveil_repro_');
    final path = '${dir.path}/test.store';
    HiddenVolumeStorage single() => HiddenVolumeStorage(
          hvSpaceOpener(path, argon: hv.ArgonPreset.min),
          keysOpener: hvKeysSpaceOpener(path),
        );
    try {
      // --- Onboarding: first identity by 111111 + a node-config write. ---
      final s0 = single();
      await s0.open(password: '111111', createIfMissing: true);
      await s0.saveIdentity(Identity(nodeId: nid(1), displayName: 'Personal'));
      await s0.saveNodeConfig('[Identity]\nfake = "config"\n');
      final kPersonal = s0.exportSpaceKeys();
      await s0.close();

      // --- addIdentity(master=000000, new=Work/222222) — exact sequence. ---
      final storage = single();
      // base roster from the (already-open in the app) first identity
      final roster = <RosterEntry>[
        RosterEntry(label: 'Identity 1', spaceKeys: kPersonal),
      ];
      // validate master FIRST
      expect(await storage.open(password: '000000', createIfMissing: true), isTrue);
      final clash = await storage.loadIdentity() != null &&
          await storage.loadRoster() == null;
      expect(clash, isFalse);
      await storage.close();
      // create the new child
      expect(await storage.open(password: '222222', createIfMissing: true), isTrue);
      await storage.saveIdentity(Identity(nodeId: nid(2), displayName: 'Work'));
      roster.add(RosterEntry(label: 'Work', spaceKeys: storage.exportSpaceKeys()));
      await storage.close();
      // persist the roster into the master
      expect(await storage.open(password: '000000'), isTrue);
      await storage.saveRoster(roster);
      await storage.close();

      // --- Verify all three are still openable by their own password. ---
      final p = single();
      expect(await p.open(password: '111111'), isTrue,
          reason: 'first identity must survive addIdentity');
      expect((await p.loadIdentity())?.displayName, 'Personal');
      await p.close();

      final m = single();
      expect(await m.open(password: '000000'), isTrue,
          reason: 'master must survive');
      expect((await m.loadRoster())?.map((e) => e.label), ['Identity 1', 'Work']);
      await m.close();

      final w = single();
      expect(await w.open(password: '222222'), isTrue);
      expect((await w.loadIdentity())?.displayName, 'Work');
      await w.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);
}
