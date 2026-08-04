import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'geoip_country_routes.dart';
import 'privileged_launch_guard.dart';
import 'vpn_backend.dart';
import 'vpn_routing_policy.dart';

Map<String, Object?> buildLinuxVpnHelperRequest({
  required int hostPid,
  required String socks5Listen,
  required Map<String, dynamic> expandedPolicy,
}) {
  return <String, Object?>{
    'hostPid': hostPid,
    'socks5Listen': socks5Listen,
    // Deliberately copy only the privileged helper's closed schema. GeoIP
    // metadata, persisted `enabled`, and country selectors are GUI state, not
    // root-process input.
    'policy': <String, Object?>{
      'routeMode': expandedPolicy['routeMode'],
      'includedCidrs': expandedPolicy['includedCidrs'],
      'excludedCidrs': expandedPolicy['excludedCidrs'],
      'routeDns': expandedPolicy['routeDns'],
      'dnsServers': expandedPolicy['dnsServers'],
      'allowLan': expandedPolicy['allowLan'],
      'mtu': expandedPolicy['mtu'],
    },
  };
}

/// Linux system VPN backed by a privileged helper mode in the xVeil binary.
///
/// `pkexec` is used only to re-exec the current executable. The helper keeps
/// the TUN and every route mutation in one lifecycle-bound process; closing
/// stdin or stopping the app triggers transactional cleanup. No extra VPN
/// daemon/binary is installed.
class LinuxManagedVpnBackend implements VpnBackend {
  LinuxManagedVpnBackend({
    @visibleForTesting PrivilegedLaunchGuard? launchGuard,
    @visibleForTesting bool? isLinuxHost,
    @visibleForTesting String? executablePath,
  }) : _launchGuard = launchGuard ?? PrivilegedLaunchGuard.forHost(),
       _isLinuxHost = isLinuxHost ?? Platform.isLinux,
       _executablePath = executablePath ?? Platform.resolvedExecutable;

  Process? _helper;
  Future<int>? _exitCode;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Directory? _requestDirectory;
  VpnBackendState _state = const VpnBackendState(VpnBackendPhase.stopped);
  final StringBuffer _stderr = StringBuffer();

  final PrivilegedLaunchGuard _launchGuard;
  final bool _isLinuxHost;
  final String _executablePath;
  PrivilegedLaunchVerdict? _launchVerdict;

  static const _startupTimeout = Duration(minutes: 3);
  static const _stopTimeout = Duration(seconds: 8);
  static const _stderrLimit = 8192;

  /// `pkexec` re-execs THIS binary as root, so an unpacked tarball sitting in
  /// the user's home would hand root to whatever was dropped beside it — and
  /// the polkit prompt, which is the only thing the user sees, looks identical
  /// either way (audit X-01). Asked first, before any capability check: what is
  /// being elevated matters more than whether `nft` happens to be installed.
  Future<VpnBackendState?> _refuseWritableInstallation() async {
    final verdict = _launchVerdict ??= await _launchGuard.inspect(
      _executablePath,
    );
    if (verdict.isAllowed) return null;
    return VpnBackendState(VpnBackendPhase.unsupported, detail: verdict.detail);
  }

  @override
  Future<VpnBackendState> probe() async {
    if (!_isLinuxHost) {
      return const VpnBackendState(
        VpnBackendPhase.unsupported,
        detail: 'Linux managed VPN backend was selected on another platform',
      );
    }
    final unsafeInstallation = await _refuseWritableInstallation();
    if (unsafeInstallation != null) return unsafeInstallation;
    if (!await File('/dev/net/tun').exists()) {
      return const VpnBackendState(
        VpnBackendPhase.unsupported,
        detail: '/dev/net/tun is unavailable',
      );
    }
    final missing = await _missingTools(const ['pkexec', 'ip', 'nft']);
    if (missing.isNotEmpty) {
      return VpnBackendState(
        VpnBackendPhase.unsupported,
        detail: 'missing Linux VPN tools: ${missing.join(', ')}',
      );
    }
    return status();
  }

  @override
  Future<VpnBackendState> status() async {
    final helper = _helper;
    if (helper == null) return _state;
    final exit = _exitCode;
    if (exit != null) {
      final completed = await _completed(exit);
      if (completed != null) {
        await _releaseHelper();
        if (_state.phase != VpnBackendPhase.stopped) {
          _state = VpnBackendState(
            VpnBackendPhase.error,
            detail: _failureDetail('Linux VPN helper exited ($completed)'),
          );
        }
      }
    }
    return _state;
  }

  @override
  Future<VpnBackendState> start({
    required VpnRoutingPolicy policy,
    required String socks5Listen,
    required String exitNodeId,
    List<String> exitNodeIds = const [],
    Map<String, String> applicationProxyListens = const {},
    String? obfs4Psk,
  }) async {
    if (applicationProxyListens.isNotEmpty) {
      return const VpnBackendState(
        VpnBackendPhase.error,
        detail: 'Per-application oproxy routing is not supported by Linux',
      );
    }
    if (policy.applicationMode != VpnApplicationMode.allApplications) {
      return const VpnBackendState(
        VpnBackendPhase.error,
        detail: 'Per-application VPN is not supported by the Linux backend',
      );
    }
    final existing = await status();
    if (_helper != null || existing.phase == VpnBackendPhase.running) {
      return existing;
    }
    final probeState = await probe();
    if (probeState.phase == VpnBackendPhase.unsupported) return probeState;
    if (policy.routeDns) {
      final missing = await _missingTools(const ['resolvectl']);
      if (missing.isNotEmpty) {
        return const VpnBackendState(
          VpnBackendPhase.unsupported,
          detail: 'routed DNS on Linux requires systemd-resolved/resolvectl',
        );
      }
    }

    Map<String, dynamic> expanded;
    try {
      expanded = await GeoIpCountryRoutes.expandPolicy(policy);
    } on Object catch (error) {
      return VpnBackendState(
        VpnBackendPhase.error,
        detail: 'GeoIP routes could not be loaded: $error',
      );
    }

    _state = const VpnBackendState(VpnBackendPhase.starting);
    _stderr.clear();
    final requestDirectory = await Directory.systemTemp.createTemp(
      'xveil-vpn-',
    );
    _requestDirectory = requestDirectory;
    final request = File('${requestDirectory.path}/request.json');
    await request.writeAsString(
      jsonEncode(
        buildLinuxVpnHelperRequest(
          hostPid: pid,
          socks5Listen: socks5Listen,
          expandedPolicy: expanded,
        ),
      ),
      flush: true,
    );

    final startup = Completer<VpnBackendState>();
    try {
      final helper = await Process.start(
        'pkexec',
        <String>[_executablePath, '--xveil-vpn-helper', request.path],
        mode: ProcessStartMode.normal,
        runInShell: false,
      );
      _helper = helper;
      _exitCode = helper.exitCode;
      _stderrSubscription = helper.stderr
          .transform(utf8.decoder)
          .listen(_appendStderr);
      _stdoutSubscription = helper.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              final nativeState = _decodeState(line);
              if (nativeState == null) return;
              _state = nativeState;
              if (!startup.isCompleted &&
                  (nativeState.phase == VpnBackendPhase.running ||
                      nativeState.phase == VpnBackendPhase.error)) {
                startup.complete(nativeState);
              }
            },
            onError: (Object error) {
              if (!startup.isCompleted) {
                startup.complete(
                  VpnBackendState(
                    VpnBackendPhase.error,
                    detail: 'read Linux VPN helper status: $error',
                  ),
                );
              }
            },
          );
      unawaited(
        helper.exitCode.then((code) {
          if (!startup.isCompleted) {
            startup.complete(
              VpnBackendState(
                VpnBackendPhase.error,
                detail: _failureDetail('Linux VPN helper exited ($code)'),
              ),
            );
          }
        }),
      );
      final result = await startup.future.timeout(
        _startupTimeout,
        onTimeout: () => const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'timed out waiting for Linux VPN authorization/startup',
        ),
      );
      _state = result;
      await _deleteRequestDirectory();
      if (result.phase != VpnBackendPhase.running) {
        await _terminateHelper();
      }
      return result;
    } on Object catch (error) {
      _state = VpnBackendState(
        VpnBackendPhase.error,
        detail: 'could not launch Linux VPN helper: $error',
      );
      await _terminateHelper();
      return _state;
    }
  }

  @override
  Future<VpnBackendState> stop() async {
    final helper = _helper;
    if (helper == null) {
      _state = const VpnBackendState(VpnBackendPhase.stopped);
      return _state;
    }
    _state = const VpnBackendState(VpnBackendPhase.stopping);
    try {
      helper.stdin.writeln('stop');
      await helper.stdin.flush();
      await (_exitCode ?? helper.exitCode).timeout(_stopTimeout);
      await _releaseHelper();
      _state = const VpnBackendState(VpnBackendPhase.stopped);
    } on Object catch (error) {
      helper.kill(ProcessSignal.sigterm);
      final exit = _exitCode;
      if (exit != null) {
        await exit.timeout(_stopTimeout, onTimeout: () => -1);
      }
      await _releaseHelper();
      _state = VpnBackendState(
        VpnBackendPhase.error,
        detail: _failureDetail('Linux VPN helper did not stop cleanly: $error'),
      );
    }
    return _state;
  }

  Future<List<String>> _missingTools(List<String> tools) async {
    final missing = <String>[];
    for (final tool in tools) {
      try {
        final result = await Process.run('which', <String>[tool]);
        if (result.exitCode != 0) missing.add(tool);
      } on ProcessException {
        missing.add(tool);
      }
    }
    return missing;
  }

  Future<int?> _completed(Future<int> exit) async {
    try {
      return await exit.timeout(Duration.zero);
    } on TimeoutException {
      return null;
    }
  }

  VpnBackendState? _decodeState(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map
          ? VpnBackendState.fromMap(Map<Object?, Object?>.from(decoded))
          : null;
    } on FormatException {
      _appendStderr('unexpected helper output: $line\n');
      return null;
    }
  }

  void _appendStderr(String chunk) {
    final remaining = _stderrLimit - _stderr.length;
    if (remaining > 0) {
      _stderr.write(chunk.substring(0, chunk.length.clamp(0, remaining)));
    }
  }

  String _failureDetail(String fallback) {
    final detail = _stderr.toString().trim();
    return detail.isEmpty ? fallback : '$fallback: $detail';
  }

  Future<void> _terminateHelper() async {
    final helper = _helper;
    if (helper != null) {
      helper.kill(ProcessSignal.sigterm);
      final exit = _exitCode;
      if (exit != null) {
        await exit.timeout(_stopTimeout, onTimeout: () => -1);
      }
    }
    await _releaseHelper();
  }

  Future<void> _releaseHelper() async {
    final stdout = _stdoutSubscription;
    final stderr = _stderrSubscription;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _helper = null;
    _exitCode = null;
    await stdout?.cancel();
    await stderr?.cancel();
    await _deleteRequestDirectory();
  }

  Future<void> _deleteRequestDirectory() async {
    final directory = _requestDirectory;
    _requestDirectory = null;
    if (directory != null) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // The root helper normally removes the request before the GUI does.
      }
    }
  }
}
