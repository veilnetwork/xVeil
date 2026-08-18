/// A LOCAL ISLAND of real `veil-cli` nodes on loopback: the network the
/// app-level devices talk over.
///
/// ## Why real relays and not a loopback transport
///
/// The cases this harness exists for are about what happens when a device is
/// OFFLINE — a message deposited for a device that is not running, drained
/// later. That path is the mailbox, and the mailbox lives on a relay. A
/// loopback transport has no mailbox, no rendezvous and no onion, so a suite
/// built on one would be green on exactly the mechanism the campaign spent a
/// week fixing. (This project has a name for that shape: the fake was green
/// while the live node was dead.)
///
/// ## Why the island is sealed
///
/// Every node here is written with `builtin_seed_policy = "never"` and joins
/// only its siblings. A test must never dial the production or testnet seed
/// list: it would put test traffic on an operator's network and make the
/// suite's result depend on somebody else's uptime. `never` is enforced in
/// [_writeIslandConfig] and asserted in [assertSealed] — a policy nothing
/// checks is a comment.
///
/// The binary should also be built with `--features allow-empty-seeds`, so a
/// node with no compiled-in seeds is a legal configuration rather than a
/// startup error. See test/e2e/README.md.
///
/// ## Topology
///
/// Mirrors `scripts/dev-mailbox-onion.sh`, which is the proven local
/// arrangement for the mailbox path:
///
///   * `mailbox` — hosts the mailbox (stores + serves FETCH) and is
///     receive-anonymous, so it can be the rendezvous target;
///   * `mid1`, `mid2` — `relay_capable`, the rendezvous + onion middle hops.
///     TWO of them, because `select_onion_relay_path` forces `hop_count >= 2`
///     and excludes the rendezvous relay from the middle-hop pool. One relay
///     is not "a smaller island", it is an island where no circuit can be
///     built at all.
///
/// All nodes are pairwise peered.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xveil/data/node/embedded_node.dart' show BootstrapPeerCfg;
import 'package:xveil/data/transport/bootstrap_invite.dart';

import 'e2e_env.dart';

/// One relay process.
class RelayNode {
  RelayNode._({
    required this.label,
    required this.dir,
    required this.configPath,
    required this.listenPort,
    required this.socketPath,
    required this.roles,
  });

  final String label;
  final Directory dir;
  final String configPath;
  final int listenPort;

  /// The node's IPC socket — what a `VeilClient.connect` in a lower-level live
  /// test would attach to. Not used by this suite (the app devices run their
  /// own embedded nodes) but exposed because it costs nothing and the existing
  /// `*_xnode_local_test.dart` files are driven exactly this way.
  final String socketPath;

  final Set<String> roles;

  Process? _process;
  RandomAccessFile? _log;
  String? _inviteUri;
  String? _nodeIdHex;

  String get logPath => '${dir.path}/node.log';
  String? get nodeIdHex => _nodeIdHex;
  bool get running => _process != null;

  /// This relay as a bootstrap peer an app node can be pointed at.
  BootstrapPeerCfg get asBootstrapPeer {
    final invite = BootstrapInvite.parse(_inviteUri!);
    return BootstrapPeerCfg(
      transport: invite.transport!,
      publicKey: base64.encode(invite.publicKey),
      nonce: base64.encode(invite.nonce),
      algo: invite.algo,
    );
  }

  String get inviteUri => _inviteUri!;

  /// The tail of this relay's log, for a failure message. A live-run failure
  /// that says only "did not converge" costs a re-run to find out which node
  /// was unhappy; this puts the answer in the first report.
  String logTail({int lines = 25}) {
    try {
      final all = File(logPath).readAsLinesSync();
      final tail = all.length <= lines ? all : all.sublist(all.length - lines);
      return '--- $label (${_nodeIdHex?.substring(0, 8) ?? "?"}) ---\n'
          '${tail.join("\n")}';
    } catch (error) {
      return '--- $label --- (log unreadable: $error)';
    }
  }
}

class RelayCluster {
  RelayCluster._(this._cli, this.root, this.nodes);

  final String _cli;
  final Directory root;
  final List<RelayNode> nodes;

  RelayNode get mailbox => nodes.firstWhere((n) => n.roles.contains('mailbox'));

  /// What an app-level device should be given as its bootstrap peer list.
  List<BootstrapPeerCfg> get bootstrapPeers =>
      [for (final node in nodes) node.asBootstrapPeer];

  /// Bring the island up.
  ///
  /// [identityFixtures] is where minted relay identities are cached. Minting is
  /// ~45 wall-seconds and ~12 CPU-minutes PER NODE at veil's canonical PoW
  /// difficulty (24), and the node refuses to start below it — there is no
  /// low-difficulty shortcut for a running node, only for a config that will
  /// then fail validation with "identity.nonce: must produce at least 24
  /// leading zero bits". So identities are minted once and committed; a run
  /// that finds them missing mints and caches them, and says so loudly.
  static Future<RelayCluster> start({
    required String veilCliPath,
    required Directory root,
    Directory? identityFixtures,
    Duration readyTimeout = const Duration(seconds: 120),
  }) async {
    final fixtures =
        identityFixtures ?? Directory('test/e2e/fixtures');
    final specs = <(String, Set<String>)>[
      ('mailbox', {'mailbox', 'receive_anonymous', 'onion_service'}),
      ('mid1', {'relay_capable'}),
      ('mid2', {'relay_capable'}),
    ];

    final nodes = <RelayNode>[];
    final cluster = RelayCluster._(veilCliPath, root, nodes);
    try {
      for (var index = 0; index < specs.length; index++) {
        final (label, roles) = specs[index];
        final dir = Directory('${root.path}/$label');
        await dir.create(recursive: true);
        if (!Platform.isWindows) {
          await Process.run('chmod', ['700', dir.path]);
        }
        final node = RelayNode._(
          label: label,
          dir: dir,
          configPath: '${dir.path}/config.toml',
          listenPort: await freePort(),
          socketPath: '${dir.path}/app.sock',
          roles: roles,
        );
        await E2eLog.step('relay $label: config', () async {
          await cluster._writeIslandConfig(
            node,
            identityToml: await cluster._identityBlock(fixtures, index),
          );
        });
        nodes.add(node);
      }

      // Invites are read BEFORE anything starts: `bootstrap invite` reads the
      // config file, and doing it up front means the peering loop below never
      // races a node that is mid-boot.
      for (final node in nodes) {
        node._inviteUri = await cluster._invite(node);
      }
      await E2eLog.step('relay island: pairwise peering', () async {
        for (final a in nodes) {
          for (final b in nodes) {
            if (identical(a, b)) continue;
            await cluster._run(['-c', a.configPath, 'bootstrap', 'join',
                '--uri', b._inviteUri!]);
          }
        }
      });

      for (final node in nodes) {
        await cluster._spawn(node);
      }
      await cluster._awaitReady(readyTimeout);
      cluster.assertSealed();
      return cluster;
    } catch (_) {
      // A half-built island still has processes in it. Nothing else will ever
      // come back for them, and a leaked relay holding a port poisons the NEXT
      // run — which then fails for a reason that has nothing to do with its
      // own code.
      await cluster.dispose();
      rethrow;
    }
  }

  /// Every relay's log tail, for a failure message.
  String diagnostics() => nodes.map((n) => n.logTail()).join('\n');

  /// Fail loudly if any node in this island could reach a real seed.
  ///
  /// The check is on the FILE, not on our intent to have written it: this is
  /// the one property whose violation is invisible from inside the test (the
  /// suite would simply pass, on somebody else's network).
  void assertSealed() {
    for (final node in nodes) {
      final toml = File(node.configPath).readAsStringSync();
      if (!RegExp(
        r'^[ \t]*builtin_seed_policy[ \t]*=[ \t]*"never"',
        multiLine: true,
      ).hasMatch(toml)) {
        throw StateError(
          'relay ${node.label} is not sealed: builtin_seed_policy is not '
          '"never", so this test could dial the production seed list',
        );
      }
    }
  }

  /// Stop everything, in an order that cannot leave a process behind.
  Future<void> dispose({bool removeFiles = true}) async {
    await teardownLegs('relay-cluster', [
      for (final node in nodes)
        ('kill ${node.label}', () => _kill(node)),
      if (removeFiles)
        ('remove $root', () async {
          if (await root.exists()) await root.delete(recursive: true);
        }),
    ]);
  }

  // --- internals ------------------------------------------------------------

  Future<void> _kill(RelayNode node) async {
    final process = node._process;
    if (process == null) {
      _closeLog(node);
      return;
    }
    node._process = null;
    process.kill(ProcessSignal.sigterm);
    try {
      // Short, because a relay routinely ignores SIGTERM here (measured: mid1
      // and mid2 every run) and every second of grace is paid three times per
      // fleet, once per case. Nothing in a throwaway island needs a graceful
      // shutdown — what matters is that the process is GONE before the next
      // run asks for a port.
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      E2eLog.line('relay ${node.label} ignored SIGTERM — SIGKILL');
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 8), onTimeout: () {
        E2eLog.line('relay ${node.label} did not reap after SIGKILL');
        return -1;
      });
    }
    _closeLog(node);
  }

  void _closeLog(RelayNode node) {
    final log = node._log;
    node._log = null;
    try {
      log?.closeSync();
    } catch (_) {
      // Already closed.
    }
  }

  Future<void> _spawn(RelayNode node) async {
    // A RandomAccessFile, not an IOSink: the readiness wait below reads this
    // same file through a SECOND handle while the node is still writing, and a
    // buffered sink shows it an empty log. The first version of this used
    // `stdout.pipe(sink)` plus `stderr.listen(sink.add)`, which is also a
    // double-bind on one sink — the node ran perfectly and the harness sat for
    // two minutes waiting for a log line that was never going to be written.
    final log = File(node.logPath).openSync(mode: FileMode.write);
    node._log = log;
    final process = await Process.start(
      _cli,
      ['-c', node.configPath, 'node', 'run', '--foreground'],
      environment: {
        ...Platform.environment,
        'RUST_LOG': Platform.environment['XVEIL_E2E_RUST_LOG'] ??
            'info,veil_node_runtime=debug,veil_mailbox=debug',
      },
    );
    node._process = process;
    void write(List<int> data) {
      try {
        log.writeFromSync(data);
      } catch (_) {
        // The file is closed during teardown while the process is still
        // draining. Losing the last few bytes of a log we are about to delete
        // is not a failure worth propagating out of a stream callback.
      }
    }

    process.stdout.listen(write);
    process.stderr.listen(write);
    // A process that dies at once (bad config, port taken) must not be waited
    // on for two minutes as though it were slow.
    unawaited(process.exitCode.then((code) {
      if (node._process != null) {
        E2eLog.line('relay ${node.label} EXITED with $code — '
            'the island is now short a node');
        node._process = null;
      }
    }));
    E2eLog.line('relay ${node.label} spawned pid=${process.pid} '
        'port=${node.listenPort}');
  }

  Future<void> _awaitReady(Duration timeout) async {
    for (final node in nodes) {
      await waitUntil(
        () async {
          if (node._process == null) {
            throw StateError(
              'relay ${node.label} exited before it was ready:\n'
              '${node.logTail()}',
            );
          }
          final id = _nodeIdFromLog(node);
          if (id == null) return false;
          node._nodeIdHex = id;
          return portAnswers(node.listenPort);
        },
        what: 'relay ${node.label} to answer on 127.0.0.1:${node.listenPort} '
            'and print its node id',
        describe: () async =>
            'process=${node._process == null ? "DEAD" : "alive"} '
            'nodeId=${node._nodeIdHex ?? "not printed yet"} '
            'port=${await portAnswers(node.listenPort) ? "open" : "closed"}\n'
            '${node.logTail(lines: 12)}',
        timeout: timeout,
      );
      E2eLog.line('relay ${node.label} ready '
          '(${node._nodeIdHex!.substring(0, 8)})');
    }
  }

  static final _nodeIdPattern = RegExp(r'node_id[=: ]+([0-9a-f]{64})');

  String? _nodeIdFromLog(RelayNode node) {
    try {
      final match = _nodeIdPattern.firstMatch(File(node.logPath).readAsStringSync());
      return match?.group(1);
    } catch (_) {
      return null;
    }
  }

  /// The `[Identity]` block for relay [index], minting and caching it when the
  /// fixture is absent.
  Future<String> _identityBlock(Directory fixtures, int index) async {
    final fixture = File('${fixtures.path}/relay_identity_$index.toml');
    if (await fixture.exists()) return fixture.readAsString();

    E2eLog.line(
      'no cached identity for relay $index — MINTING at PoW difficulty 24. '
      'This takes ~45s and saturates every core; it happens once and is '
      'cached at ${fixture.path}.',
    );
    final staging = Directory('${root.path}/.mint');
    await staging.create(recursive: true);
    final path = '${staging.path}/relay_$index.toml';
    await _run(['config', 'init', '-f', '-d', '24', path]);
    final block = _identitySection(await File(path).readAsString());
    await fixture.parent.create(recursive: true);
    await fixture.writeAsString(
      '# TEST-ONLY relay identity for the local end-to-end island\n'
      '# (test/e2e/relay_cluster.dart). The private key is intentionally\n'
      '# public and must NEVER be used outside an isolated loopback test.\n'
      '$block',
    );
    return fixture.readAsString();
  }

  /// Write a node config for the island: a fast skeleton with the CACHED
  /// identity spliced in, the seed policy sealed, and the role tables appended.
  ///
  /// The skeleton is minted at difficulty 1 (instant) purely for its shape —
  /// listener table, transport defaults, admin socket path — and its identity
  /// is then replaced wholesale. A difficulty-1 identity would be rejected at
  /// `node run`; the one that survives here is the cached difficulty-24 one.
  Future<void> _writeIslandConfig(
    RelayNode node, {
    required String identityToml,
  }) async {
    await _run(['config', 'init', '-f', '-d', '1', node.configPath]);
    var toml = await File(node.configPath).readAsString();
    toml = toml.replaceFirst(
      RegExp(r'\[Identity\][\s\S]*?(?=\n\[|$)'),
      _identitySection(identityToml).trimRight(),
    );
    // Sealed island. Mirrors `EmbeddedNode.withBuiltinSeedPolicy`, which is
    // what the app does for the same reason on the other side of the wire.
    final policy = RegExp(
      r'^[ \t]*builtin_seed_policy[ \t]*=.*$',
      multiLine: true,
    );
    toml = policy.hasMatch(toml)
        ? toml.replaceAll(policy, 'builtin_seed_policy = "never"')
        : toml.replaceFirst('[global]\n', '[global]\nbuiltin_seed_policy = "never"\n');
    await File(node.configPath).writeAsString(toml);

    await _run(['-c', node.configPath, 'listen', 'add',
        'tcp://127.0.0.1:${node.listenPort}']);
    await _run(['-c', node.configPath, 'config', 'set', 'ipc.enabled', 'true']);
    await _run(['-c', node.configPath, 'config', 'set', 'ipc.socket_uri',
        'unix://${node.socketPath}']);

    final anonymity = <String>[
      if (node.roles.contains('receive_anonymous')) 'receive_anonymous = true',
      if (node.roles.contains('onion_service')) 'onion_service = true',
      if (node.roles.contains('relay_capable')) 'relay_capable = true',
    ];
    final extra = StringBuffer();
    if (anonymity.isNotEmpty) {
      extra.writeln('\n[anonymity]\n${anonymity.join("\n")}');
    }
    if (node.roles.contains('mailbox')) {
      extra.writeln(
        '\n[mailbox]\nenabled = true\nrequire_capability_token = false',
      );
    }
    if (extra.isNotEmpty) {
      await File(node.configPath)
          .writeAsString(extra.toString(), mode: FileMode.append);
    }
  }

  static String _identitySection(String toml) {
    final match = RegExp(r'\[Identity\][\s\S]*?(?=\n\[|$)').firstMatch(toml);
    if (match == null) {
      throw StateError('no [Identity] section in the minted config');
    }
    return '${match.group(0)!.trimRight()}\n';
  }

  Future<String> _invite(RelayNode node) async {
    final out = await _run(['-c', node.configPath, 'bootstrap', 'invite']);
    final match = RegExp(r'veil:bootstrap\S+').firstMatch(out);
    if (match == null) {
      throw StateError('relay ${node.label} produced no invite:\n$out');
    }
    return match.group(0)!;
  }

  Future<String> _run(List<String> args) async {
    final result = await Process.run(_cli, args);
    if (result.exitCode != 0) {
      throw StateError(
        'veil-cli ${args.join(" ")} failed (${result.exitCode})\n'
        'stdout: ${result.stdout}\nstderr: ${result.stderr}',
      );
    }
    return '${result.stdout}\n${result.stderr}';
  }
}
