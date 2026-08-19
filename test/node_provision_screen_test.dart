import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xveil/data/node/managed_node.dart';
import 'package:xveil/data/node/network_flavor.dart';
import 'package:xveil/data/node/node_provisioner.dart';
import 'package:xveil/data/node/ssh_credentials.dart';
import 'package:xveil/data/node/veil_github_release.dart';
import 'package:xveil/features/network/node_provision_screen.dart';
import 'package:xveil/l10n/app_localizations.dart';

const _shaX64 =
    'de5f630023cdd7753bce89aae8b56b7ea2c410e2b0f7c40233b9d0ff939af069';
const _shaArm =
    '5406a992a4d81777c8bcdd5534a72f40fd9bc6d7863f5eed5751701c6c3249df';

VeilGithubReleaseResolver _resolver() => VeilGithubReleaseResolver(
  fetcher: (uri) async => jsonEncode({
    'tag_name': kMinimumVeilReleaseTag,
    'assets': [
      for (final target in VeilLinuxReleaseTarget.values)
        for (final component in NodeComponent.values)
          {
            'name': '${component.binaryName}-${target.triple}',
            'browser_download_url':
                'https://github.com/veilnetwork/veil/releases/download/'
                '$kMinimumVeilReleaseTag/'
                '${component.binaryName}-${target.triple}',
            'digest': target == VeilLinuxReleaseTarget.x86_64Musl
                ? 'sha256:$_shaX64'
                : 'sha256:$_shaArm',
          },
    ],
  }),
);

Widget _host() => ProviderScope(
  child: MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: NodeProvisionScreen(
      node: const ManagedNode(
        id: 'test-node',
        label: 'Test server',
        sshHost: 'server.example',
        sshUser: 'root',
      ),
      initialCredentials: const SavedSshCredentials(),
      releaseResolver: _resolver(),
    ),
  ),
);

// Any non-empty value will do: the screen only asks whether a deployment PSK
// exists at all, and the checksum/base64 rules live in the provisioner.
//
// The KEY, though, is not a constant. It comes from the same rule the screen
// reads (`veilNetwork.obfs4PskAsset`), and it has to: this used to spell out
// the production path, and then the testnet landed — a test build resolves to
// `assets/testnet/...`, the mock answered a question nobody asked, and the
// screen fell back to its "no PSK" body. Six tests then looked for controls
// that were not on screen and failed for a reason that had nothing to do with
// what they assert.
String get _pskAsset => veilNetwork.obfs4PskAsset;
const _testPsk = 'dGVzdC1vYmZzNC1wc2s=';

void main() {
  // This screen renders NOTHING but "PSK missing" when the bundled deployment
  // PSK cannot be read — `_loadPsk` reads `assets/prod/obfs4_psk.b64` and an
  // empty result replaces the whole body. That asset is a network secret and
  // is gitignored, so it is present only on a machine that was handed one:
  // on CI, and on any clean clone, it is not there, and every test below was
  // silently asking whether this host holds a production secret rather than
  // what it says it asks. Serve the asset instead of depending on the host.
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    // `rootBundle` caches per key, and a cached entry belongs to the zone of
    // the test that filled it — a later test awaiting it waits forever. Clear
    // it so each test resolves the PSK in its own zone and no test depends on
    // running first.
    rootBundle.clear();
    binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async {
        final key = utf8.decode(Uint8List.sublistView(message!));
        if (key != _pskAsset) return null;
        return ByteData.sublistView(utf8.encode(_testPsk));
      },
    );
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    rootBundle.clear();
  });

  // The release URL decides which binary a remote machine downloads and runs.
  // `isSafeHttpsUrl` is the check that says whether it is one this app will
  // fetch, and the screen never consulted it — so a plain-http or malformed
  // URL was accepted at the field and failed later, somewhere the reader
  // could not connect back to what they had typed. The sentence for it was
  // written into both ARBs and attached to nothing.
  testWidgets('a release URL this app will not fetch is refused at the field', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    final l = AppL10n.of(tester.element(find.byType(NodeProvisionScreen)));

    // The field is read-only while the URL comes from GitHub; the custom
    // source is the one a person types into.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('artifact-source-veil-cli')),
        matching: find.text(l.provisionSourceCustom),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('veil-release-url')),
      'http://example.test/veil-cli',
    );
    await tester.pumpAndSettle();
    expect(
      find.text(l.provisionNeedUrl),
      findsOneWidget,
      reason:
          'plain http was taken without a word — the failure then happens far '
          'from the field that caused it',
    );

    // And the other direction: a URL it WILL fetch must not be flagged. An
    // error that is always on is the same as no error.
    await tester.enterText(
      find.byKey(const ValueKey('veil-release-url')),
      'https://example.test/veil-cli',
    );
    await tester.pumpAndSettle();
    expect(find.text(l.provisionNeedUrl), findsNothing);
  });

  testWidgets('auto-fills URL and SHA and refreshes them for architecture', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    TextField field(Key key) => tester.widget<TextField>(find.byKey(key));
    expect(
      field(const ValueKey('veil-release-url')).controller!.text,
      endsWith('veil-cli-x86_64-unknown-linux-musl'),
    );
    expect(field(const ValueKey('veil-release-sha')).controller!.text, _shaX64);

    await tester.tap(find.byKey(const ValueKey('veil-release-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ARM64 Linux (portable musl)').last);
    await tester.pumpAndSettle();

    expect(
      field(const ValueKey('veil-release-url')).controller!.text,
      endsWith('veil-cli-aarch64-unknown-linux-musl'),
    );
    expect(field(const ValueKey('veil-release-sha')).controller!.text, _shaArm);
  });

  testWidgets('keeps each port inside its transport card', (tester) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final obfs4 = find.byKey(const ValueKey('transport-obfs4-tcp'));
    expect(obfs4, findsOneWidget);
    expect(
      find.descendant(
        of: obfs4,
        matching: find.byKey(const ValueKey('transport-port-obfs4-tcp')),
      ),
      findsOneWidget,
    );

    final quic = find.byKey(const ValueKey('transport-quic'));
    await tester.ensureVisible(quic);
    await tester.tap(
      find.descendant(of: quic, matching: find.byType(Checkbox)).first,
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: quic,
        matching: find.byKey(const ValueKey('transport-port-quic')),
      ),
      findsOneWidget,
    );
    expect(find.text('Network protocol: UDP'), findsOneWidget);
    expect(find.text('TLS certificate'), findsOneWidget);
  });

  testWidgets(
    'automatic TLS chooses Let\'s Encrypt for DNS and self-signed for IP',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final quic = find.byKey(const ValueKey('transport-quic'));
      await tester.tap(
        find.descendant(of: quic, matching: find.byType(Checkbox)).first,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tls-automatic-name')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('advertise-host')),
        '203.0.113.10',
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('self-signed certificate with this IP'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('tls-self-signed-days')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tls-email')), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('tls-automatic-name')),
        'node.example.com',
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining("Let's Encrypt will be requested"),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('tls-email')), findsOneWidget);
      expect(find.byKey(const ValueKey('tls-agree-terms')), findsOneWidget);
      expect(find.byKey(const ValueKey('tls-self-signed-days')), findsNothing);
    },
  );

  testWidgets('TLS certificate source can use existing files', (tester) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final tls = find.byKey(const ValueKey('transport-tls'));
    await tester.tap(
      find.descendant(of: tls, matching: find.byType(Checkbox)).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tls-certificate-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Existing files').last);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('tls-existing-cert')), findsOneWidget);
    expect(find.byKey(const ValueKey('tls-existing-key')), findsOneWidget);
    expect(find.byKey(const ValueKey('tls-existing-ca')), findsOneWidget);
    expect(find.byKey(const ValueKey('tls-automatic-name')), findsNothing);
  });

  testWidgets('optional component offers GitHub or a custom link', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    await tester.tap(find.text('ogate'));
    await tester.pumpAndSettle();

    final urlFinder = find.byKey(const ValueKey('artifact-url-ogate'));
    final shaFinder = find.byKey(const ValueKey('artifact-sha-ogate'));
    expect(
      tester.widget<TextField>(urlFinder).controller!.text,
      endsWith('ogate-x86_64-unknown-linux-musl'),
    );
    expect(tester.widget<TextField>(shaFinder).controller!.text, _shaX64);
    expect(tester.widget<TextField>(urlFinder).readOnly, isTrue);

    final source = find.byKey(const ValueKey('artifact-source-ogate'));
    await tester.tap(
      find.descendant(of: source, matching: find.text('Custom link')),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(urlFinder).readOnly, isFalse);
    await tester.enterText(urlFinder, 'https://example.com/custom-ogate');
    expect(
      tester.widget<TextField>(urlFinder).controller!.text,
      'https://example.com/custom-ogate',
    );
  });
}
