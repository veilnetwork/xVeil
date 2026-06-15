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

/// Reproduces the live "add a 3rd identity to an EXISTING master" lockout the
/// user hit (Personal/Work survive, Anon never created, master roster loses an
/// entry). The bug is in how the roster is rebuilt on each add: the old flow
/// OVERWRITES the master's roster from an in-memory base instead of loading the
/// master's on-disk roster and APPENDING. When the in-memory base is stale (no
/// active master session — e.g. after all-online or a relaunch), entries vanish.
void main() {
  final skip = ensureHiddenVolumeLoaded() ? null : 'no dylib';
  NodeId nid(int s) => NodeId(Uint8List.fromList(List.filled(32, s)));

  HiddenVolumeStorage single(String path) => HiddenVolumeStorage(
        hvSpaceOpener(path, argon: hv.ArgonPreset.min),
        keysOpener: hvKeysSpaceOpener(path),
      );

  /// Onboard `Personal` + convert to master with `Work`, exactly as the app
  /// does on the first add. Returns the master roster after conversion.
  Future<void> seedMasterWithPersonalAndWork(String path) async {
    // Onboarding: first identity by 111111.
    final s0 = single(path);
    await s0.open(password: '111111', createIfMissing: true);
    await s0.saveIdentity(Identity(nodeId: nid(1), displayName: 'Personal'));
    final kPersonal = s0.exportSpaceKeys();
    await s0.close();

    // First add (convert to master 000000, new identity Work/222222).
    final st = single(path);
    final roster = <RosterEntry>[
      RosterEntry(label: 'Personal', spaceKeys: kPersonal),
    ];
    await st.open(password: '000000', createIfMissing: true); // create master
    await st.close();
    await st.open(password: '222222', createIfMissing: true); // create Work
    await st.saveIdentity(Identity(nodeId: nid(2), displayName: 'Work'));
    roster.add(RosterEntry(label: 'Work', spaceKeys: st.exportSpaceKeys()));
    await st.close();
    await st.open(password: '000000'); // master
    await st.saveRoster(roster);
    await st.close();
  }

  test('BUG: rebuilding the roster from a stale in-memory base drops Work',
      () async {
    final dir = Directory('/tmp').createTempSync('xveil_bug_');
    final path = '${dir.path}/test.store';
    try {
      await seedMasterWithPersonalAndWork(path);

      // Add Anon (333333) to the EXISTING master 000000 — but with a STALE
      // in-memory base (only Personal, as if _pendingRoster was lost). This is
      // the OLD logic: build base = [Personal], append Anon, OVERWRITE master.
      final st = single(path);
      final staleBase = <RosterEntry>[
        RosterEntry(label: 'Personal', spaceKeys: Uint8List(64)),
      ];
      await st.open(password: '000000', createIfMissing: true);
      await st.close();
      await st.open(password: '333333', createIfMissing: true);
      await st.saveIdentity(Identity(nodeId: nid(3), displayName: 'Anon'));
      staleBase
          .add(RosterEntry(label: 'Anon', spaceKeys: st.exportSpaceKeys()));
      await st.close();
      await st.open(password: '000000');
      await st.saveRoster(staleBase); // OVERWRITES [Personal, Work] !
      await st.close();

      // The master roster has LOST Work — exactly the live symptom.
      final m = single(path);
      await m.open(password: '000000');
      final labels = (await m.loadRoster())!.map((e) => e.label).toList();
      await m.close();
      expect(labels, ['Personal', 'Anon'],
          reason: 'reproduces the overwrite: Work dropped from the roster');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);

  test('FIX: loading the master on-disk roster and appending keeps all three',
      () async {
    final dir = Directory('/tmp').createTempSync('xveil_fix_');
    final path = '${dir.path}/test.store';
    try {
      await seedMasterWithPersonalAndWork(path);

      // Add Anon (333333) the FIXED way: open master, LOAD its on-disk roster,
      // append the new child, save back. No reliance on in-memory state.
      final st = single(path);
      await st.open(password: '000000', createIfMissing: true);
      final base = await st.loadRoster() ?? const <RosterEntry>[];
      await st.close();
      await st.open(password: '333333', createIfMissing: true);
      await st.saveIdentity(Identity(nodeId: nid(3), displayName: 'Anon'));
      final withAnon = [
        ...base,
        RosterEntry(label: 'Anon', spaceKeys: st.exportSpaceKeys()),
      ];
      await st.close();
      await st.open(password: '000000');
      await st.saveRoster(withAnon);
      await st.close();

      // All three present in the master roster, each opens with its identity.
      final m = single(path);
      await m.open(password: '000000');
      expect((await m.loadRoster())!.map((e) => e.label),
          ['Personal', 'Work', 'Anon']);
      await m.close();

      for (final pw in const {'111111': 'Personal', '222222': 'Work', '333333': 'Anon'}.entries) {
        final p = single(path);
        expect(await p.open(password: pw.key), isTrue,
            reason: '${pw.value} must still open by its own password');
        expect((await p.loadIdentity())?.displayName, pw.value);
        await p.close();
      }
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, skip: skip);
}
