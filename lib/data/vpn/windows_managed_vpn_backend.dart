import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'geoip_country_routes.dart';
import 'privileged_launch_guard.dart';
import 'vpn_backend.dart';
import 'vpn_routing_policy.dart';

Map<String, Object?> buildWindowsVpnHelperRequest({
  required int hostPid,
  required String token,
  required String socks5Listen,
  required Map<String, dynamic> expandedPolicy,
}) {
  return <String, Object?>{
    'hostPid': hostPid,
    'token': token,
    'socks5Listen': socks5Listen,
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

/// The SHA-256 the elevated helper is told to expect, as lowercase hex.
///
/// Over the bytes the host WRITES, which is why the caller hashes what it is
/// about to write rather than re-reading the file: a second read is another
/// moment in which the same user's processes could have replaced it, and that
/// moment is the whole defect this closes.
String windowsVpnRequestDigest(List<int> requestBytes) =>
    sha256.convert(requestBytes).toString();

/// The PowerShell that asks for elevation and starts the helper.
///
/// [digest] travels on the COMMAND LINE, and that is the point of it. The
/// request JSON has to be staged in the user's own `%TEMP%` — the host is
/// unelevated when it writes it — so any process of that user can rewrite the
/// file while the UAC prompt is on screen, and the helper's read of it is what
/// gives the contents administrator power over routes, DNS and the SOCKS
/// endpoint. A command line is fixed when the approved process is created.
/// The digest is not a secret; it is a value the attacker cannot change
/// (report5 R5-X-03).
String buildWindowsVpnElevationScript(
  String executable,
  String request,
  String digest,
) {
  // Refused here rather than passed on: a caller that has no digest must not
  // be able to produce a launch, and the helper's own check would then be the
  // only thing standing between a rewritten request and an elevated tunnel.
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw ArgumentError('windows VPN request digest must be 64 hex characters');
  }
  String quote(String value) => "'${value.replaceAll("'", "''")}'";
  return r'$exe = ' +
      quote(executable) +
      r'; $request = ' +
      quote(request) +
      r'; $digest = ' +
      quote(digest) +
      r"""; $arguments = '--xveil-vpn-helper "' + $request + '" ' + $digest; $process = Start-Process -FilePath $exe -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru; [Console]::Out.WriteLine($process.Id)""";
}

/// Windows system VPN backed by a UAC-elevated helper mode in `xveil.exe`.
///
/// The elevated copy loads the packet engine DLL beside the application and
/// owns Wintun plus all ActiveStore routes for exactly one lifecycle. Status
/// and stop control use a per-launch random-token directory because UAC does
/// not preserve anonymous pipe handles reliably across the elevation boundary.
class WindowsManagedVpnBackend implements VpnBackend {
  WindowsManagedVpnBackend({
    @visibleForTesting PrivilegedLaunchGuard? launchGuard,
    @visibleForTesting bool? isWindowsHost,
    @visibleForTesting String? executablePath,
    // Stands in for a FACT about the machine — which DLLs are beside the
    // executable — never for a decision. The sibling Linux backend has had
    // `tunDevice` and `requiredTools` for the same reason: without a seam, a
    // test that wants to reach the NEXT check can only get there by relying on
    // the host to be missing something, which makes it pass on the developer's
    // machine and fail on the platform it is named after.
    @visibleForTesting this.requiredComponents = const [
      'veil_vpn_helper.dll',
      'wintun.dll',
    ],
  }) : _launchGuard = launchGuard ?? PrivilegedLaunchGuard.forHost(),
       _isWindowsHost = isWindowsHost ?? Platform.isWindows,
       _executablePath = executablePath ?? Platform.resolvedExecutable;

  VpnBackendState _state = const VpnBackendState(VpnBackendPhase.stopped);
  Directory? _sessionDirectory;
  File? _statusFile;
  File? _stopFile;
  String? _token;
  int? _helperPid;

  final PrivilegedLaunchGuard _launchGuard;
  final bool _isWindowsHost;
  final String _executablePath;
  @visibleForTesting
  final List<String> requiredComponents;

  static const _authorizationTimeout = Duration(minutes: 3);
  static const _startupTimeout = Duration(seconds: 90);
  static const _stopTimeout = Duration(seconds: 10);
  static const _pollInterval = Duration(milliseconds: 100);

  /// Refuse before anything else: `probe()` decides whether to offer a feature
  /// whose whole job is to run this executable as Administrator. If the binary
  /// is not out of the user's reach, the answer is no regardless of what
  /// components happen to be installed beside it (audit X-01).
  ///
  /// NOT cached (audit C-01). A verdict kept for the lifetime of the backend
  /// is a statement about the installation as it was at app start; the
  /// question is about the installation as it is at the instant of elevation,
  /// so it is asked again there.
  Future<VpnBackendState?> _refuseWritableInstallation() async {
    final verdict = await _launchGuard.inspect(_executablePath);
    if (verdict.isAllowed) return null;
    return VpnBackendState(VpnBackendPhase.unsupported, detail: verdict.detail);
  }

  @override
  Future<VpnBackendState> probe() async {
    if (!_isWindowsHost) {
      return const VpnBackendState(
        VpnBackendPhase.unsupported,
        detail: 'Windows managed VPN backend was selected on another platform',
      );
    }
    final unsafeInstallation = await _refuseWritableInstallation();
    if (unsafeInstallation != null) return unsafeInstallation;
    final directory = File(_executablePath).parent;
    final missing = <String>[];
    for (final name in requiredComponents) {
      final separator = Platform.pathSeparator;
      if (!await File('${directory.path}$separator$name').exists()) {
        missing.add(name);
      }
    }
    if (missing.isNotEmpty) {
      return VpnBackendState(
        VpnBackendPhase.unsupported,
        detail: 'missing Windows VPN components: ${missing.join(', ')}',
      );
    }
    // Asked of the FILE, not of `where.exe`: the old check ran a bare
    // `where.exe` and then elevated through a bare `powershell.exe`, so the
    // answer and the thing it authorized both came from PATH (audit C-01).
    final powershell = windowsPowerShellPath();
    if (!await File(powershell).exists()) {
      return VpnBackendState(
        VpnBackendPhase.unsupported,
        detail:
            'Windows PowerShell is required for UAC elevation and is not at '
            '$powershell',
      );
    }
    return status();
  }

  @override
  Future<VpnBackendState> status() async {
    final native = await _readStatus();
    if (native != null) {
      _state = native;
      if (native.phase == VpnBackendPhase.running && !await _isHelperAlive()) {
        _state = const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'Windows VPN helper exited without restoring a final status',
        );
      }
      if (_state.phase == VpnBackendPhase.stopped ||
          _state.phase == VpnBackendPhase.error) {
        await _releaseSession();
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
        detail: 'Per-application oproxy routing is not supported by Windows',
      );
    }
    if (policy.applicationMode != VpnApplicationMode.allApplications) {
      return const VpnBackendState(
        VpnBackendPhase.error,
        detail: 'Per-application VPN is not supported by the Windows backend',
      );
    }
    final existing = await status();
    if (_sessionDirectory != null ||
        existing.phase == VpnBackendPhase.running) {
      return existing;
    }
    final available = await probe();
    if (available.phase == VpnBackendPhase.unsupported) return available;

    Map<String, dynamic> expanded;
    var elevationCompleted = false;
    try {
      expanded = await GeoIpCountryRoutes.expandPolicy(policy);
    } on Object catch (error) {
      return VpnBackendState(
        VpnBackendPhase.error,
        detail: 'GeoIP routes could not be loaded: $error',
      );
    }

    _state = const VpnBackendState(VpnBackendPhase.starting);
    final session = await Directory.systemTemp.createTemp('xveil-vpn-');
    final token = _randomToken();
    final separator = Platform.pathSeparator;
    final request = File('${session.path}${separator}request.json');
    _sessionDirectory = session;
    _statusFile = File('${session.path}${separator}status.json');
    _stopFile = File('${session.path}${separator}stop');
    _token = token;
    // The exact bytes, hashed and written from ONE value. Encoding twice — or
    // hashing a re-read of the file — would leave the gap this closes.
    final requestBytes = utf8.encode(
      jsonEncode(
        buildWindowsVpnHelperRequest(
          hostPid: pid,
          token: token,
          socks5Listen: socks5Listen,
          expandedPolicy: expanded,
        ),
      ),
    );
    final requestDigest = windowsVpnRequestDigest(requestBytes);
    await request.writeAsBytes(requestBytes, flush: true);

    try {
      // ASKED AGAIN, immediately before the UAC prompt. Everything between the
      // check at the top of `start()` and this line — GeoIP expansion, the
      // session directory, the request file — is time in which the
      // installation could have changed (audit C-01).
      final stillSafe = await _refuseWritableInstallation();
      if (stillSafe != null) {
        _state = stillSafe;
        await _releaseSession();
        return _state;
      }
      final launcher = await Process.run(
        windowsPowerShellPath(),
        <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          buildWindowsVpnElevationScript(
            _executablePath,
            request.path,
            requestDigest,
          ),
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        includeParentEnvironment: false,
        environment: windowsCleanEnvironment(),
      ).timeout(_authorizationTimeout);
      if (launcher.exitCode != 0) {
        final detail = (launcher.stderr as String).trim();
        throw StateError(
          detail.isEmpty
              ? 'UAC authorization was cancelled or failed'
              : 'UAC authorization failed: $detail',
        );
      }
      elevationCompleted = true;
      _helperPid = int.tryParse((launcher.stdout as String).trim());
      if (_helperPid == null || _helperPid! <= 0) {
        throw StateError('UAC launcher did not return the helper process id');
      }
      final result = await _waitFor(const {
        VpnBackendPhase.running,
        VpnBackendPhase.error,
      }, _startupTimeout);
      _state = result;
      if (result.phase != VpnBackendPhase.running) {
        await _requestStop();
        await _releaseSession();
      }
      return result;
    } on Object catch (error) {
      _state = VpnBackendState(
        VpnBackendPhase.error,
        detail: 'could not launch Windows VPN helper: $error',
      );
      await _requestStop();
      var safeToRelease = !elevationCompleted && error is! TimeoutException;
      if (elevationCompleted) {
        try {
          await _waitFor(const {
            VpnBackendPhase.stopped,
            VpnBackendPhase.error,
          }, _stopTimeout);
          safeToRelease = true;
        } on Object {
          safeToRelease = !await _isHelperAlive();
        }
      }
      if (safeToRelease) await _releaseSession();
      return _state;
    }
  }

  @override
  Future<VpnBackendState> stop() async {
    if (_sessionDirectory == null) {
      _state = const VpnBackendState(VpnBackendPhase.stopped);
      return _state;
    }
    _state = const VpnBackendState(VpnBackendPhase.stopping);
    try {
      await _requestStop();
      final result = await _waitFor(const {
        VpnBackendPhase.stopped,
        VpnBackendPhase.error,
      }, _stopTimeout);
      _state = result;
      if (result.phase == VpnBackendPhase.stopped ||
          result.phase == VpnBackendPhase.error) {
        await _releaseSession();
      }
      return result;
    } on Object catch (error) {
      _state = VpnBackendState(
        VpnBackendPhase.error,
        detail:
            'Windows VPN helper did not stop cleanly (PID ${_helperPid ?? 'unknown'}): $error',
      );
      return _state;
    }
  }

  Future<VpnBackendState> _waitFor(
    Set<VpnBackendPhase> phases,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final value = await _readStatus();
      if (value != null && phases.contains(value.phase)) return value;
      await Future<void>.delayed(_pollInterval);
    }
    throw TimeoutException('timed out waiting for Windows VPN helper', timeout);
  }

  Future<VpnBackendState?> _readStatus() async {
    final file = _statusFile;
    final token = _token;
    if (file == null || token == null || !await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['token'] != token) {
        return const VpnBackendState(
          VpnBackendPhase.error,
          detail: 'Windows VPN helper returned an invalid session token',
        );
      }
      return VpnBackendState.fromMap(Map<Object?, Object?>.from(decoded));
    } on FileSystemException {
      // Status replacement is atomic but Windows briefly removes the previous
      // path before rename. A later poll will observe the new complete file.
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _requestStop() async {
    final file = _stopFile;
    if (file != null) await file.writeAsString('stop', flush: true);
  }

  Future<bool> _isHelperAlive() async {
    final helperPid = _helperPid;
    if (helperPid == null) return true;
    try {
      final result = await Process.run(
        windowsSystem32Tool('tasklist.exe'),
        ['/FI', 'PID eq $helperPid', '/FO', 'CSV', '/NH'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        includeParentEnvironment: false,
        environment: windowsCleanEnvironment(),
      );
      return result.exitCode == 0 &&
          (result.stdout as String).contains('"$helperPid"');
    } on ProcessException {
      // Process probing is diagnostic. Failure must not delete a session that
      // could still own system routes.
      return true;
    }
  }

  Future<void> _releaseSession() async {
    final directory = _sessionDirectory;
    _sessionDirectory = null;
    _statusFile = null;
    _stopFile = null;
    _token = null;
    _helperPid = null;
    if (directory != null) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // The elevated helper may still be releasing its final file handle.
      }
    }
  }

  static String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }
}
