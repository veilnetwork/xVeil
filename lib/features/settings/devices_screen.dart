import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/format.dart';
import '../../core/ids.dart';
import '../../state/messaging_providers.dart';
import '../../data/veil_stack.dart';
import '../../data/transport/bootstrap_invite.dart';
import '../../domain/device_link.dart';
import '../../domain/sovereign_recovery.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart';
import '../../state/group_service_providers.dart';
import '../../state/providers.dart';
import '../contacts/qr_scan_screen.dart';

/// Whether the onboarding hand-off should open the join sheet on THIS build.
///
/// Extracted as a pure function for the same reason `redirectForPhase` was:
/// the invariant is not observable through the widget. Arriving from
/// onboarding, the node is still coming up, so [ready] is false for the first
/// frames and the sheet's two providers read null. Firing anyway burns the
/// one shot on a call that returns silently at its own null guard, and the
/// user is left on a Devices list that never opens anything — a failure with
/// no visible symptom to test against.
bool shouldOpenJoinSheet({
  required bool autoJoin,
  required bool ready,
  required bool alreadyOpened,
}) => autoJoin && ready && !alreadyOpened;

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key, this.autoJoin = false});

  /// Arrived here straight from the onboarding "link to a device you already
  /// use" path — open the join sheet as soon as the node is up, instead of
  /// making someone who just asked to link hunt for the same row by hand.
  final bool autoJoin;

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<NodeId> _members = const [];

  /// When each linked device was last heard from, authenticated. Null means
  /// never — which for a member of the device group says it has not been seen
  /// since it was linked.
  Map<String, DateTime?> _lastSeen = const {};

  /// Past this, a device is worth a nudge toward unlinking: it is long enough
  /// that a phone in a drawer over a holiday does not trip it, and short enough
  /// that a handset replaced months ago is obvious.
  static const _awayIsLong = Duration(days: 30);
  bool _loading = true;
  bool _hasSovereignBundle = false;
  bool _hasDeviceGroup = false;
  String? _credentialKind;
  /// The auto-open has fired. Guards against re-opening the sheet on every
  /// rebuild, and against re-opening it after the user closes it.
  bool _autoJoinFired = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  /// Subtitle for a linked device: how long it has been away, and a nudge when
  /// that is long enough to be worth acting on.
  ///
  /// This exists because a member list alone cannot tell "my other phone" from
  /// a handset wiped months ago that still collects every state change — on the
  /// stand one such device had 3473 undelivered frames against it.
  Widget _awayLine(BuildContext context, AppL10n l, NodeId device) {
    final seen = _lastSeen[device.hex];
    if (seen == null) {
      return Text(
        '${device.short} · ${l.devicesNeverSeen}',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      );
    }
    final away = DateTime.now().difference(seen);
    final line = '${device.short} · ${l.devicesLastSeen(formatAgo(away))}';
    if (away < _awayIsLong) return Text(line);
    return Text(
      '$line\n${l.devicesAwayLong}',
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _reload() async {
    final svc = ref.read(groupServiceProvider);
    final gidHex = await svc?.deviceGroupIdHex();
    final state = gidHex == null
        ? null
        : await svc?.stateOf(NodeId.fromHex(gidHex));
    final hasBundle = await svc?.localSovereignBundle() != null;
    final credentialKind = await svc?.sovereignCredentialKind();
    final members = [...?state?.members.values.map((m) => m.nodeId)]
      ..sort((a, b) => a.hex.compareTo(b.hex));
    final messaging = ref.read(messagingServiceProvider);
    final seen = <String, DateTime?>{};
    for (final m in members) {
      seen[m.hex] = await messaging.lastSeen(m);
    }
    if (!mounted) return;
    setState(() {
      _lastSeen = seen;
      _members = members;
      _hasSovereignBundle = hasBundle;
      _hasDeviceGroup = gidHex != null;
      _credentialKind = credentialKind;
      _loading = false;
    });
  }

  Future<void> _showSource() async {
    final svc = ref.read(groupServiceProvider);
    final stack = ref.read(realStackProvider);
    if (svc == null || stack == null) return;
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SourceLinkSheet(
        service: svc,
        stack: stack,
        credentialKind: _credentialKind,
      ),
    );
    if (changed == true) await _reload();
  }

  Future<void> _showRecoveryExport() async {
    final svc = ref.read(groupServiceProvider);
    if (svc == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          _RecoveryExportSheet(service: svc, credentialKind: _credentialKind),
    );
    await _reload();
  }

  Future<void> _showRecoveryImport() async {
    final svc = ref.read(groupServiceProvider);
    if (svc == null) return;
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _RecoveryImportSheet(service: svc),
    );
    if (changed == true) await _reload();
  }

  Future<void> _showTarget() async {
    final svc = ref.read(groupServiceProvider);
    final stack = ref.read(realStackProvider);
    if (svc == null || stack == null) return;
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _TargetLinkSheet(service: svc, stack: stack),
    );
    if (changed == true) await _reload();
  }

  Future<void> _revoke(NodeId device) async {
    final l = AppL10n.of(context);
    final phrase = TextEditingController();
    final usesCertificate = _credentialKind == 'certificate';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(l.devicesRevokeTitle(device.short)),
        content: TextField(
          controller: phrase,
          obscureText: true,
          maxLines: 1,
          decoration: InputDecoration(
            labelText: usesCertificate
                ? l.devicesRecoveryCode
                : l.devicesPhrase,
            helperText: usesCertificate
                ? l.devicesRecoveryCodeHint
                : l.devicesPhraseHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(MaterialLocalizations.of(dialog).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(l.devicesRevoke),
          ),
        ],
      ),
    );
    final words = phrase.text.trim();
    phrase.clear();
    phrase.dispose();
    if (confirmed != true || words.isEmpty || !mounted) return;
    NativeSovereignGroupSigner? signer;
    var ok = false;
    try {
      final svc = ref.read(groupServiceProvider);
      signer = await svc?.openLocalSovereign(words);
      if (svc != null && signer != null) {
        ok = await svc.revokeDevice(device, sovereign: signer);
      }
    } catch (_) {
      ok = false;
    } finally {
      signer?.close();
    }
    if (!mounted) return;
    if (ok) {
      await _reload();
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.devicesOperationFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final self = ref.watch(appControllerProvider).identity?.nodeId;
    final ready =
        ref.watch(groupServiceProvider) != null &&
        ref.watch(realStackProvider) != null;
    final phraseBacked = ref.watch(identityOriginProvider).value == 'phrase';
    final canOwn = ready && (_hasSovereignBundle || phraseBacked);
    // Driven from build, not initState: right after onboarding the node is
    // still coming up, so both providers read null for the first frames and an
    // initState call would open nothing and never retry.
    if (shouldOpenJoinSheet(
      autoJoin: widget.autoJoin,
      ready: ready,
      alreadyOpened: _autoJoinFired,
    )) {
      _autoJoinFired = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showTarget();
      });
    }
    return Scaffold(
      appBar: AppBar(
        leading: const RootedBackButton(),
        title: Text(l.settingsDevices),
      ),
      body: ListView(
        children: [
          if (_loading)
            const LinearProgressIndicator()
          else if (_members.isEmpty)
            ListTile(
              leading: const Icon(Icons.devices_outlined),
              title: Text(l.devicesNoGroup),
            )
          else
            for (final device in _members)
              ListTile(
                leading: Icon(
                  device == self ? Icons.devices : Icons.phonelink_outlined,
                ),
                title: Text(
                  device == self ? l.devicesThisDevice : device.short,
                ),
                subtitle: device == self
                    ? Text(device.short)
                    : _awayLine(context, l, device),
                trailing: device == self
                    ? const Icon(Icons.check)
                    : IconButton(
                        tooltip: l.devicesRevoke,
                        icon: const Icon(Icons.link_off),
                        onPressed: () => _revoke(device),
                      ),
              ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.add_link),
            title: Text(l.devicesLinkNew),
            subtitle: Text(l.devicesPhraseHint),
            enabled: canOwn,
            trailing: const Icon(Icons.chevron_right),
            onTap: canOwn ? _showSource : null,
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: Text(l.devicesJoinExisting),
            enabled: ready,
            trailing: const Icon(Icons.chevron_right),
            onTap: ready ? _showTarget : null,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              l.devicesRecoverySection,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(l.devicesCreateRecovery),
            subtitle: Text(l.devicesCreateRecoveryHint),
            enabled: canOwn,
            trailing: const Icon(Icons.chevron_right),
            onTap: canOwn ? _showRecoveryExport : null,
          ),
          ListTile(
            leading: const Icon(Icons.settings_backup_restore),
            title: Text(l.devicesRecover),
            subtitle: Text(l.devicesRecoverHint),
            enabled: ready && !_hasDeviceGroup && !_hasSovereignBundle,
            trailing: const Icon(Icons.chevron_right),
            onTap: ready && !_hasDeviceGroup && !_hasSovereignBundle
                ? _showRecoveryImport
                : null,
          ),
        ],
      ),
    );
  }
}

class _RecoveryExportSheet extends StatefulWidget {
  const _RecoveryExportSheet({
    required this.service,
    required this.credentialKind,
  });

  final GroupService service;
  final String? credentialKind;

  @override
  State<_RecoveryExportSheet> createState() => _RecoveryExportSheetState();
}

class _RecoveryExportSheetState extends State<_RecoveryExportSheet> {
  final _secret = TextEditingController();
  String? _certificate;
  String? _code;
  NodeId? _nodeId;
  bool _busy = false;
  bool _failed = false;

  @override
  void dispose() {
    _secret.clear();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final secret = _secret.text.trim();
    _secret.clear();
    if (secret.isEmpty) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final exported = await widget.service.exportRecoveryCertificate(secret);
      if (exported == null) throw StateError('credential unavailable');
      final certificate = SovereignRecoveryCertificate.fromBytes(
        exported.certificate,
      );
      if (certificate.nodeId != exported.nodeId) {
        throw StateError('node id mismatch');
      }
      if (!mounted) return;
      setState(() {
        _certificate = certificate.toText();
        _code = exported.code;
        _nodeId = exported.nodeId;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final usesCertificate = widget.credentialKind == 'certificate';
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _certificate == null
                ? l.devicesCreateRecovery
                : l.devicesCertificateReady,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (_certificate == null) ...[
            TextField(
              controller: _secret,
              obscureText: true,
              decoration: InputDecoration(
                labelText: usesCertificate
                    ? l.devicesRecoveryCode
                    : l.devicesPhrase,
                helperText: usesCertificate
                    ? l.devicesRecoveryCodeHint
                    : l.devicesPhraseHint,
              ),
              onSubmitted: _busy ? null : (_) => _create(),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.key_outlined),
              label: Text(l.devicesCreateRecovery),
            ),
          ] else ...[
            Text(
              l.devicesCertificateWarning,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 12),
            Text('${l.nodeIdLabel}: ${_nodeId!.hex}'),
            const SizedBox(height: 12),
            SelectableText(
              _certificate!,
              maxLines: 5,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
            TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: _certificate!)),
              icon: const Icon(Icons.copy),
              label: Text(l.devicesCopyCertificate),
            ),
            const SizedBox(height: 8),
            SelectableText(
              _code!,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: _code!)),
              icon: const Icon(Icons.copy),
              label: Text(l.devicesCopyCode),
            ),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                l.devicesOperationFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _RecoveryImportSheet extends StatefulWidget {
  const _RecoveryImportSheet({required this.service});
  final GroupService service;

  @override
  State<_RecoveryImportSheet> createState() => _RecoveryImportSheetState();
}

class _RecoveryImportSheetState extends State<_RecoveryImportSheet> {
  final _certificate = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _failed = false;

  @override
  void dispose() {
    _certificate.dispose();
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    final code = _code.text.trim();
    _code.clear();
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final certificate = SovereignRecoveryCertificate.parse(_certificate.text);
      final gid = await widget.service.recoverDeviceGroupFromCertificate(
        certificate.bytes,
        code,
      );
      if (gid == null) throw StateError('fresh registry required');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).devicesRecovered)),
      );
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.devicesRecover, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(l.devicesRecoverHint),
          const SizedBox(height: 16),
          TextField(
            controller: _certificate,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: l.devicesCertificate,
              helperText: l.devicesCertificateHint,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            obscureText: true,
            decoration: InputDecoration(
              labelText: l.devicesRecoveryCode,
              helperText: l.devicesRecoveryCodeHint,
            ),
            onSubmitted: _busy ? null : (_) => _recover(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _recover,
            icon: const Icon(Icons.settings_backup_restore),
            label: Text(l.devicesRecover),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                l.devicesOperationFailed,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _SourceLinkSheet extends StatefulWidget {
  const _SourceLinkSheet({
    required this.service,
    required this.stack,
    required this.credentialKind,
  });
  final GroupService service;
  final RealVeilStack stack;
  final String? credentialKind;

  @override
  State<_SourceLinkSheet> createState() => _SourceLinkSheetState();
}

class _SourceLinkSheetState extends State<_SourceLinkSheet> {
  final _phrase = TextEditingController();
  final _targetInvite = TextEditingController();
  String? _token;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phrase.clear();
    _phrase.dispose();
    _targetInvite.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw != null && mounted) _targetInvite.text = raw;
  }

  Future<void> _prepare() async {
    final l = AppL10n.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    NativeSovereignGroupSigner? signer;
    try {
      final target = BootstrapInvite.parse(_targetInvite.text);
      if (target.nodeId == widget.service.selfId) {
        throw const FormatException('self device');
      }
      final words = _phrase.text.trim();
      _phrase.clear();
      await widget.stack.addContact(target);
      signer = await widget.service.openLocalSovereign(words);
      final linked = await widget.service.linkDevice(
        target.nodeId,
        sovereign: signer,
        broadcastSnapshot: false,
      );
      if (!linked) throw StateError('membership rejected');
      final token = await widget.service.createDeviceLinkToken(
        widget.stack.myInvite,
      );
      if (token == null) throw StateError('token unavailable');
      if (!mounted) return;
      setState(() => _token = token.toUri());
    } catch (_) {
      if (mounted) setState(() => _error = l.devicesOperationFailed);
    } finally {
      signer?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final l = AppL10n.of(context);
    setState(() => _busy = true);
    try {
      final count = await widget.service.broadcastDeviceGroup();
      if (count < 1) throw StateError('no target');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.devicesSetupSent)));
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = l.devicesOperationFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final usesCertificate = widget.credentialKind == 'certificate';
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.devicesLinkNew, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          if (_token == null) ...[
            TextField(
              controller: _targetInvite,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l.devicesTargetInvite,
                helperText: l.devicesTargetInviteHint,
                suffixIcon: IconButton(
                  // The field says what to paste; the icon said nothing at all
                  // — no hover hint, and nothing for a screen reader to read.
                  tooltip: l.inviteScanTooltip,
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _busy ? null : _scan,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phrase,
              obscureText: true,
              decoration: InputDecoration(
                labelText: usesCertificate
                    ? l.devicesRecoveryCode
                    : l.devicesPhrase,
                helperText: usesCertificate
                    ? l.devicesRecoveryCodeHint
                    : l.devicesPhraseHint,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _busy ? null : _prepare,
              icon: const Icon(Icons.lock_outline),
              label: Text(l.devicesPrepare),
            ),
          ] else ...[
            Text(
              l.devicesAdoptionQrTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(l.devicesAdoptionQrHint),
            const SizedBox(height: 16),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(12),
                child: QrImageView(data: _token!, size: 220),
              ),
            ),
            SelectableText(
              _token!,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
            ),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: _token!)),
              icon: const Icon(Icons.copy),
              label: Text(l.actionCopy),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _send,
              icon: const Icon(Icons.send),
              label: Text(l.devicesSendSetup),
            ),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _TargetLinkSheet extends StatefulWidget {
  const _TargetLinkSheet({required this.service, required this.stack});
  final GroupService service;
  final RealVeilStack stack;

  @override
  State<_TargetLinkSheet> createState() => _TargetLinkSheetState();
}

class _TargetLinkSheetState extends State<_TargetLinkSheet> {
  final _token = TextEditingController();
  Timer? _poll;
  DeviceLinkToken? _pending;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _restorePending();
  }

  Future<void> _restorePending() async {
    final pending = await widget.service.pendingDeviceAdoption();
    if (pending == null || !mounted) return;
    setState(() => _pending = pending);
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _checkDone());
    await _checkDone();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _token.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final raw = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanScreen()));
    if (raw == null || !mounted) return;
    _token.text = raw;
    await _prepare();
  }

  Future<void> _prepare() async {
    final l = AppL10n.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final token = DeviceLinkToken.parse(_token.text);
      if (token.isExpired(DateTime.now().millisecondsSinceEpoch)) {
        throw const FormatException('expired');
      }
      await widget.stack.addContact(token.sourceInvite);
      if (!await widget.service.prepareDeviceAdoption(token)) {
        throw StateError('admission rejected');
      }
      _token.clear();
      if (!mounted) return;
      setState(() => _pending = token);
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _checkDone());
      await _checkDone();
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e.message == 'expired'
            ? l.devicesExpiredToken
            : l.devicesInvalidToken,
      );
    } catch (_) {
      if (mounted) setState(() => _error = l.devicesOperationFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkDone() async {
    final pending = _pending;
    if (pending == null) return;
    if (await widget.service.deviceGroupIdHex() != pending.groupId.hex) return;
    _poll?.cancel();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(AppL10n.of(context).devicesJoined)));
    Navigator.of(context).pop(true);
  }

  Future<void> _cancel() async {
    await widget.service.cancelPendingDeviceAdoption();
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final myInvite = widget.stack.myInvite.toUri();
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.devicesJoinExisting,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (_pending == null) ...[
            Text(l.devicesShowMyInvite),
            const SizedBox(height: 8),
            Center(
              child: Container(
                color: Colors.white,
                padding: const EdgeInsets.all(10),
                child: QrImageView(data: myInvite, size: 170),
              ),
            ),
            TextButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: myInvite)),
              icon: const Icon(Icons.copy),
              label: Text(l.actionCopy),
            ),
            const Divider(height: 28),
            TextField(
              controller: _token,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: l.devicesJoinToken,
                helperText: l.devicesJoinTokenHint,
                suffixIcon: IconButton(
                  tooltip: l.inviteScanTooltip,
                  icon: const Icon(Icons.qr_code_scanner),
                  onPressed: _busy ? null : _scan,
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _prepare,
              child: Text(l.devicesPrepare),
            ),
          ] else ...[
            const Icon(Icons.phonelink_lock_outlined, size: 52),
            const SizedBox(height: 12),
            Text(
              l.devicesWaitTitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(l.devicesWaitHint, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            TextButton(onPressed: _cancel, child: Text(l.devicesCancelPending)),
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
