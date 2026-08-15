import 'dart:io';

import '../../core/log.dart' show kXVeilDebugBuild;

/// Which veil network this build talks to.
///
/// Two networks now run on the same hosts, on different ports, under different
/// obfs4 pre-shared keys — so they cannot even complete a handshake with each
/// other, which is the isolation that matters. The testnet exists because
/// proving a relay-side change live used to mean one of two bad options:
/// deploy it to production, or believe a unit test.
///
/// The choice reaches THREE places, and it is the same choice in all three or
/// it is worthless:
///
///   * the seed descriptors bundled as an asset ([seedsAsset]);
///   * the deployment obfs4 PSK bundled beside them ([obfs4PskAsset]);
///   * veil's own compiled-in `builtin_seeds()`, selected by a cargo feature
///     when the native library is built (`scripts/build-native.sh` reads the
///     same rule from the same environment variable).
///
/// The third is the one that bites: the node splices its compiled-in list in by
/// itself whenever the config names no peers, so an app that bundles testnet
/// descriptors while linking a production-seeded native dials production
/// anyway, and nothing in the Dart half can see it. That is why the rule lives
/// here as data rather than as an `if` at each site, and why
/// `test/bundled_seeds_match_builtin_test.dart` reads veil's source to check
/// the two halves agree.
enum VeilNetwork {
  /// The network real installs use.
  prod('prod', 'production-seeds'),

  /// The network development uses, so that a change to a relay can be proven
  /// against a relay that runs it.
  testnet('testnet', 'testnet-seeds');

  const VeilNetwork(this.assetDir, this.cargoFeature);

  /// Directory under `assets/` holding this network's seeds and PSK.
  final String assetDir;

  /// The veil cargo feature that compiles in this network's `builtin_seeds()`.
  /// Named here so the one rule has one home; the build script reads it too.
  final String cargoFeature;

  String get seedsAsset => 'assets/$assetDir/seeds.json';
  String get obfs4PskAsset => 'assets/$assetDir/obfs4_psk.b64';
}

/// The environment variable that overrides the build-mode default.
///
/// For the stand, mostly: a debug build pointed at production to reproduce
/// something a user reported, or a release build pointed at the testnet to
/// rehearse a deployment. Absent on mobile, where there is no environment —
/// there the build mode is the whole answer.
const String kNetworkEnvVar = 'XVEIL_NETWORK';

/// Resolve the network from an explicit name, falling back to the build mode.
///
/// Pure, so the rule can be tested without a process environment. An
/// unrecognised name falls back rather than throwing: this runs during boot,
/// before anything can show an error, and a typo must not decide that a
/// development build talks to production.
VeilNetwork resolveVeilNetwork({String? override, bool? debugBuild}) {
  final name = override?.trim().toLowerCase();
  if (name != null && name.isNotEmpty) {
    for (final network in VeilNetwork.values) {
      if (network.name == name || network.assetDir == name) return network;
    }
  }
  // DEBUG MEANS TESTNET. Development traffic does not belong on the network
  // real installs use, and the reverse — a release build on the testnet — is
  // worse still, so neither is the default for the other.
  return (debugBuild ?? kXVeilDebugBuild) ? VeilNetwork.testnet
                                          : VeilNetwork.prod;
}

/// The network this process talks to.
VeilNetwork get veilNetwork => resolveVeilNetwork(
      override: Platform.environment[kNetworkEnvVar],
    );
