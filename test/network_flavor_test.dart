// Which network a build talks to, and the one rule that decides it.
//
// The cost of getting this wrong is asymmetric and neither direction is
// acceptable: development traffic on the network real installs use, or a
// release build that finds nothing because it is dialling a test network. So
// the rule is data, tested here, and read by both halves of the build.

import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/network_flavor.dart';

void main() {
  test('a debug build talks to the testnet, a release build to production', () {
    expect(resolveVeilNetwork(debugBuild: true), VeilNetwork.testnet);
    expect(resolveVeilNetwork(debugBuild: false), VeilNetwork.prod);
  });

  test('an explicit name wins over the build mode, both ways', () {
    expect(
      resolveVeilNetwork(override: 'prod', debugBuild: true),
      VeilNetwork.prod,
      reason: 'a debug build must be able to reproduce a production report',
    );
    expect(
      resolveVeilNetwork(override: 'testnet', debugBuild: false),
      VeilNetwork.testnet,
      reason: 'a release build must be able to rehearse against the testnet',
    );
  });

  // It runs during boot, before anything can show an error. Throwing would take
  // the app down; silently choosing production for a build that asked for
  // something else is the outcome this exists to avoid, so the fallback is the
  // build mode rather than a fixed network.
  test('an unrecognised name falls back to the build mode, not to production',
      () {
    expect(
      resolveVeilNetwork(override: 'testnetz', debugBuild: true),
      VeilNetwork.testnet,
    );
    expect(
      resolveVeilNetwork(override: '', debugBuild: false),
      VeilNetwork.prod,
    );
    expect(
      resolveVeilNetwork(override: '  TESTNET  ', debugBuild: false),
      VeilNetwork.testnet,
      reason: 'trimmed and case-folded — a shell exports what it exports',
    );
  });

  // The asset paths and the cargo feature are the whole point of the enum: the
  // Dart half and the native half must be reading the same word.
  test('each network names its own assets and its own cargo feature', () {
    expect(VeilNetwork.prod.seedsAsset, 'assets/prod/seeds.json');
    expect(VeilNetwork.prod.obfs4PskAsset, 'assets/prod/obfs4_psk.b64');
    expect(VeilNetwork.prod.cargoFeature, 'production-seeds');
    expect(VeilNetwork.testnet.seedsAsset, 'assets/testnet/seeds.json');
    expect(VeilNetwork.testnet.obfs4PskAsset, 'assets/testnet/obfs4_psk.b64');
    expect(VeilNetwork.testnet.cargoFeature, 'testnet-seeds');
  });
}
