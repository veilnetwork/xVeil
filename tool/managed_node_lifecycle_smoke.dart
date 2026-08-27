import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xveil/data/node/node_lifecycle.dart';
import 'package:xveil/data/node/node_provisioner.dart';
import 'package:xveil/data/node/ssh_client.dart';

/// Opt-in live smoke for the exact managed-node lifecycle exposed by xVeil.
///
/// This is deliberately not part of automated tests: it mutates a remote Linux
/// host and, with `--debootstrap`, returns it to a clean state. Example:
///
/// dart run tool/managed_node_lifecycle_smoke.dart \
///   --host 192.0.2.10 --user root --key ~/.ssh/id_ed25519 \
///   --release-base https://example/releases/v1 \
///   --manifest /path/to/sha256-x86_64-unknown-linux-gnu.txt \
///   --asset-suffix x86_64-unknown-linux-gnu \
///   --confirm-host 192.0.2.10 --debootstrap \
///   --confirm-debootstrap-host 192.0.2.10
Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  final key = await File(options.keyPath).readAsString();
  final manifest = await File(options.manifestPath).readAsLines();
  final hashes = _parseManifest(manifest);
  final artifacts = [
    for (final component in NodeComponent.values)
      NodeReleaseArtifact(
        component: component,
        releaseUrl:
            '${options.releaseBase}/${component.binaryName}-${options.assetSuffix}',
        expectedSha256: hashes[component.binaryName] ?? '',
      ),
  ];
  if (!artifacts.every((artifact) => artifact.isValid)) {
    stderr.writeln('release URL or manifest is incomplete/invalid');
    exitCode = 2;
    return;
  }

  final auth = SshAuth.key(key);
  String? fingerprint = options.expectedFingerprint;
  var remoteWasMutated = false;

  Future<SshResult> run(
    String stage,
    String command, {
    Duration timeout = const Duration(minutes: 6),
    bool reportOutput = true,
  }) async {
    stdout.writeln('==> $stage');
    final result = await sshRun(
      host: options.host,
      port: options.port,
      user: options.user,
      auth: auth,
      command: command,
      expectedHostFingerprint: fingerprint,
      timeout: timeout,
    );
    fingerprint ??= result.hostFingerprint;
    if (!result.ok) {
      throw StateError(
        '$stage failed (exit ${result.exitCode}): ${result.stderr.trim()}',
      );
    }
    final report = result.stdout.trim();
    if (reportOutput && report.isNotEmpty) stdout.writeln(report);
    return result;
  }

  try {
    await run('initial inventory', buildNodeInventoryScript());
    final random = Random.secure();
    final provision = NodeProvisionConfig(
      releaseUrl: artifacts.first.releaseUrl,
      expectedSha256: artifacts.first.expectedSha256,
      obfs4PskB64: base64Encode(
        List<int>.generate(32, (_) => random.nextInt(256)),
      ),
      extraArtifacts: artifacts.skip(1).toList(growable: false),
      transports: const {NodeListenTransport.obfs4Tcp, NodeListenTransport.tcp},
      advertiseHost: options.host,
    );
    if (!provision.isValid) {
      throw StateError('generated provision plan invalid');
    }

    remoteWasMutated = true;
    final installed = await run(
      'install and configure',
      buildProvisionScript(provision),
    );
    final firstNodeId = _nodeId(installed.stdout);
    if (firstNodeId == null) {
      throw StateError('installer did not report node ID');
    }

    await run('post-install inventory', buildNodeInventoryScript());
    await run(
      'veil restart',
      buildNodeServiceActionScript(
        NodeManagedService.veil,
        NodeServiceAction.restart,
      ),
    );

    final read = await run(
      'read veil config',
      buildReadNodeConfigScript(NodeConfigTarget.veil),
      reportOutput: false,
    );
    // The read answers WHAT was there and WHAT IT HASHED TO, so the write can
    // refuse a file that changed since. This tool still passed the read
    // straight into the writer as if it were the text, which stopped compiling
    // when the read grew its digest — and nothing noticed, because
    // `flutter analyze lib/ test/` does not look at `tool/` while the release
    // gate's bare `flutter analyze` does.
    final veilConfig = parseReadNodeConfig(read.stdout);
    if (veilConfig == null || veilConfig.contents.isEmpty) {
      throw StateError('could not parse downloaded veil config');
    }
    await run(
      'transactional veil config write',
      buildWriteNodeConfigScript(
        NodeConfigTarget.veil,
        veilConfig.contents,
        // Carried through: a smoke run that skipped it would exercise a write
        // this app never makes.
        expectedSha256: veilConfig.sha256,
      ),
    );

    await run(
      'authenticated in-place update',
      buildNodeSoftwareUpdateScript(artifacts),
    );
    await run(
      'uninstall software and preserve data',
      buildNodeUninstallScript(NodeManagedService.values.toSet()),
    );
    final afterUninstall = await run(
      'post-uninstall inventory',
      buildNodeInventoryScript(),
    );
    if (!afterUninstall.stdout.contains('BINARY_veil-cli: missing')) {
      throw StateError('uninstall left veil-cli installed');
    }

    final reinstalled = await run(
      'reinstall and preserve identity',
      buildProvisionScript(provision),
    );
    final secondNodeId = _nodeId(reinstalled.stdout);
    if (secondNodeId != firstNodeId) {
      throw StateError('node identity changed across uninstall/reinstall');
    }
    stdout.writeln('IDENTITY_PRESERVED: $firstNodeId');
  } finally {
    if (options.debootstrap && remoteWasMutated) {
      await run('bounded debootstrap', buildNodeDebootstrapScript());
      final clean = await run(
        'final clean inventory',
        buildNodeInventoryScript(),
      );
      if (!clean.stdout.contains('BINARY_veil-cli: missing')) {
        throw StateError('debootstrap did not return host to a clean state');
      }
    }
  }
}

Map<String, String> _parseManifest(List<String> lines) {
  final result = <String, String>{};
  final pattern = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$');
  for (final line in lines) {
    final match = pattern.firstMatch(line.trim());
    if (match != null) result[match.group(2)!] = match.group(1)!;
  }
  return result;
}

String? _nodeId(String output) => RegExp(
  r'NODE_ID:\s*([0-9a-fA-F]{64})',
).firstMatch(output)?.group(1)?.toLowerCase();

class _Options {
  const _Options({
    required this.host,
    required this.port,
    required this.user,
    required this.keyPath,
    required this.releaseBase,
    required this.manifestPath,
    required this.assetSuffix,
    required this.debootstrap,
    this.expectedFingerprint,
  });

  final String host;
  final int port;
  final String user;
  final String keyPath;
  final String releaseBase;
  final String manifestPath;
  final String assetSuffix;
  final bool debootstrap;
  final String? expectedFingerprint;

  static _Options parse(List<String> arguments) {
    final values = <String, String>{};
    var debootstrap = false;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--debootstrap') {
        debootstrap = true;
        continue;
      }
      if (!argument.startsWith('--') || index + 1 >= arguments.length) {
        _usage('invalid argument: $argument');
      }
      values[argument.substring(2)] = arguments[++index];
    }
    const required = [
      'host',
      'user',
      'key',
      'release-base',
      'manifest',
      'asset-suffix',
      'confirm-host',
    ];
    for (final name in required) {
      if ((values[name] ?? '').isEmpty) _usage('missing --$name');
    }
    if (values['confirm-host'] != values['host']) {
      _usage('--confirm-host must exactly match --host');
    }
    if (debootstrap && values['confirm-debootstrap-host'] != values['host']) {
      _usage('--confirm-debootstrap-host must exactly match --host');
    }
    final port = int.tryParse(values['port'] ?? '22');
    if (port == null || port < 1 || port > 65535) _usage('invalid --port');
    return _Options(
      host: values['host']!,
      port: port,
      user: values['user']!,
      keyPath: values['key']!.replaceFirst(
        '~',
        Platform.environment['HOME'] ?? '',
      ),
      releaseBase: values['release-base']!.replaceAll(RegExp(r'/+$'), ''),
      manifestPath: values['manifest']!,
      assetSuffix: values['asset-suffix']!,
      debootstrap: debootstrap,
      expectedFingerprint: values['expected-fingerprint'],
    );
  }

  static Never _usage(String message) {
    stderr.writeln(message);
    stderr.writeln(
      'See the example at the top of tool/managed_node_lifecycle_smoke.dart',
    );
    exit(2);
  }
}
