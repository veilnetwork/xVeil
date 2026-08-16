import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/log.dart';

import '../../core/clipboard_secret.dart';
import '../../core/ids.dart';
import '../../state/messaging_providers.dart';
import '../../data/veil_stack.dart';
import '../../data/transport/device_link_invite.dart';
import '../../data/node/identity_config_fields.dart';
import '../../data/node/sovereign_identity_material.dart'
    show
        decodeSovereignIdentity,
        kIdentityDocumentFile,
        kSovereignIdentitySetting;
import '../../data/transport/bootstrap_invite.dart';
import '../../domain/device_link.dart';
import '../../domain/sovereign_recovery.dart';
import '../../l10n/app_localizations.dart';
import '../../routing/back_affordance.dart';
import '../../state/app_controller.dart';
import '../../state/group_service_providers.dart';
import '../../state/providers.dart';
import '../contacts/qr_scan_screen.dart';
import '../common/relative_time.dart';
import '../../core/secure_screen.dart';

/// How long a device-group snapshot send is allowed to take before the person
/// is told something instead of nothing.
///
/// Generous on purpose. The same transfer measured 1.9–3.0 s for 200 KB and
/// 2.7 s for 5 MB over the live overlay, so a minute is not a race — it is the
/// point at which "still going" stops being a plausible reading of a spinner.
const kDeviceSnapshotSendTimeout = Duration(seconds: 60);

/// What a device-group snapshot send did.
enum DeviceSnapshotSend {
  /// Delivered to at least one other member.
  sent,

  /// The group has nobody else in it, so there was nothing to send.
  noTargets,

  /// Still unfinished when the clock ran out — almost always the other device
  /// being offline.
  timedOut,

  /// It threw.
  failed,
}

/// Send the device-group snapshot, bounded.
///
/// The linking sheet used to `await service.broadcastDeviceGroup()` with no
/// limit of any kind, and that call awaits delivery to every member in turn. A
/// device that is not reachable therefore produced a spinner that could not
/// finish and said nothing while it did not — a person pressed send and was
/// still watching it five minutes later.
///
/// The timeout stops the WAITING, not the sending: the broadcast keeps running
/// and may still land. That is deliberate — the point is to stop lying to the
/// person about what is happening, not to cancel a transfer that might yet
/// succeed.
///
/// Takes the send itself rather than the service so all four outcomes are
/// reachable from a test with no group, no transport and no second device.
Future<DeviceSnapshotSend> sendDeviceSnapshotBounded(
  Future<int> Function() broadcast, {
  Duration timeout = kDeviceSnapshotSendTimeout,
}) async {
  try {
    final count = await broadcast().timeout(timeout);
    return count < 1 ? DeviceSnapshotSend.noTargets : DeviceSnapshotSend.sent;
  } on TimeoutException {
    return DeviceSnapshotSend.timedOut;
  } catch (_) {
    return DeviceSnapshotSend.failed;
  }
}

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

  /// This device's OWN bootstrap invite — its transport key and nonce — read
  /// once with the rest of the screen's state.
  ///
  /// Not the stack's `myInvite`: that carries the IDENTITY's key, so every
  /// device of an identity produces the same string. This is what tells this
  /// device from its siblings and what makes one of them addressable.
  BootstrapInvite? _myDevice;

  /// This device's identity document, carried in the link QR beside its key.
  Uint8List? _myDocument;

  /// The auto-open has fired. Guards against re-opening the sheet on every
  /// rebuild, and against re-opening it after the user closes it.
  bool _autoJoinFired = false;

  /// A re-send is in flight. Separate from `_loading`, which is the initial
  /// member read: a re-send must not blank the list it was started from.
  bool _resending = false;

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
    final line =
        '${device.short} · ${l.devicesLastSeen(formatAgoL10n(l, away))}';
    if (away < _awayIsLong) return Text(line);
    return Text(
      '$line\n${l.devicesAwayLong}',
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    );
  }

  Future<void> _reload() async {
    try {
      await _reloadFromStore();
    } on StateError catch (e) {
      // A LOCKED STORE IS AN ANSWER, not a crash. This screen reads settings to
      // decide what to offer, and the read throws "storage is locked" when it
      // runs before or after an unlock — on the way in from a deep link, on a
      // lock that lands mid-load, and in any test that builds the screen over a
      // real provider scope. The unhandled error left the screen mid-build and
      // its frames scheduling forever.
      //
      // Nothing here is worth failing over: with no readable store there is no
      // device group, no document and no config, which is exactly the state the
      // screen already renders for a device that has not set one up.
      devLog(() => 'xVeil[devices]: store not readable yet ($e) — showing empty');
    } finally {
      // LOADING HAS TO END, whatever happened. `_loading` was cleared only at
      // the tail of a successful read, so any failure left it true — and the
      // screen renders an indeterminate LinearProgressIndicator while it is.
      // That bar then spins for as long as the screen is open, which is a
      // person watching an empty page load forever, and in a widget test it is
      // a tree that never settles because an indeterminate animation schedules
      // a frame every frame.
      //
      // Finishing empty is the honest end state: it says "there is nothing
      // here", which is true, instead of "still coming", which is not.
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadFromStore() async {
    final svc = ref.read(groupServiceProvider);
    final gidHex = await svc?.deviceGroupIdHex();
    final state = gidHex == null
        ? null
        : await svc?.stateOf(NodeId.fromHex(gidHex));
    final hasBundle = await svc?.localSovereignBundle() != null;
    final credentialKind = await svc?.sovereignCredentialKind();
    final members = [...?state?.members.values.map((m) => m.nodeId)]
      ..sort((a, b) => a.hex.compareTo(b.hex));
    final storedIdentity = await ref
        .read(storageProvider)
        .getSetting(kSovereignIdentitySetting);
    final myDocument = storedIdentity == null
        ? null
        : decodeSovereignIdentity(storedIdentity)?[kIdentityDocumentFile];
    final toml = await ref.read(storageProvider).loadNodeConfig();
    final fields = toml == null ? null : identityConfigFields(toml);
    final myDevice = fields == null
        ? null
        : BootstrapInvite(
            publicKey: fields.publicKey,
            nonce: fields.nonce,
            algo: fields.algo,
          );
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
      _myDevice = myDevice;
      _myDocument = myDocument;
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
        myDevice: _myDevice,
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
      builder: (_) => _TargetLinkSheet(
        service: svc,
        stack: stack,
        myDevice: _myDevice,
        myDocument: _myDocument,
      ),
    );
    if (changed == true) await _reload();
  }

  /// Re-send the device-group snapshot to everyone already in the group.
  ///
  /// No phrase and no token: the membership is already signed, so this is only
  /// the delivery half repeating itself. Bounded, and it says which of the
  /// three things happened.
  Future<void> _resendSnapshot() async {
    final l = AppL10n.of(context);
    final svc = ref.read(groupServiceProvider);
    if (svc == null) return;
    setState(() => _resending = true);
    final outcome = await sendDeviceSnapshotBounded(svc.broadcastDeviceGroup);
    if (!mounted) return;
    setState(() => _resending = false);
    final text = switch (outcome) {
      DeviceSnapshotSend.sent => l.devicesSetupSent,
      DeviceSnapshotSend.timedOut => l.devicesSendUnreachable,
      DeviceSnapshotSend.noTargets => l.devicesSendNoTargets,
      DeviceSnapshotSend.failed => l.devicesOperationFailed,
    };
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
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
          // THE WAY BACK TO "SEND", which did not exist.
          //
          // Linking signs the new device into the registry and THEN sends it
          // the snapshot, and those are two separate steps in one sheet. The
          // joining side persists its half — it restores the pending admission
          // and shows "waiting" for as long as it takes. This side kept the
          // whole thing in a field: close the sheet and the minted token is
          // gone, the sheet reopens at "paste an invite", and the send step is
          // unreachable.
          //
          // So the pair stranded. The other device sat waiting for a send that
          // no screen could offer any more, and the membership it was waiting
          // on had already been signed. Reported by a person in exactly that
          // position, on a phone that could not join a desktop three metres
          // away.
          //
          // Offered whenever the group has somebody else in it, because that
          // is precisely when a re-send can do something.
          if (_members.length > 1)
            ListTile(
              leading: const Icon(Icons.send_outlined),
              title: Text(l.devicesResendSetup),
              subtitle: Text(_resending ? l.devicesWaitHint : l.devicesResendHint),
              enabled: !_resending,
              onTap: _resending ? null : _resendSnapshot,
            ),
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

/// A copy control for a credential, with the clipboard's lifetime attached.
///
/// Three secrets on this screen went onto the system-wide clipboard and stayed
/// there for as long as the person did not copy something else: the recovery
/// CERTIFICATE, the recovery CODE, and the device-adoption TOKEN. The
/// certificate and the code TOGETHER are a whole recovery capability for this
/// identity — the sheet's own warning says as much — and the token adopts a
/// device into the group. That is the same credential class as the API token,
/// which was bounded first, and strictly more dangerous: the API token is
/// revocable from the same screen, a sovereign recovery capability is not.
///
/// Why the clear is UNCONDITIONAL rather than compare-then-clear is argued in
/// clipboard_secret.dart and is not repeated here: reading the clipboard back
/// on iOS 16+ raises a "pasted from xVeil" banner, so the check would announce
/// itself every time. The honest price of clearing blind is telling the person
/// the window exists before it starts — which is what [copiedMessage] is for,
/// and why it takes the number of seconds rather than hard-coding one that can
/// drift away from [kClipboardSecretLifetime].
class SecretCopyButton extends StatelessWidget {
  const SecretCopyButton({
    super.key,
    required this.label,
    required this.value,
    required this.copiedMessage,
    this.schedule = clearClipboardLater,
  });

  /// Text on the button.
  final String label;

  /// Read at TAP time, not captured at build time: these sheets rebuild around
  /// the secret as it is produced, and a stale capture would copy the value
  /// from a previous frame.
  final String Function() value;

  /// The localised "copied, cleared in N seconds" line, taking the window.
  /// The generated getter is passed directly so the number the person is told
  /// and the number the timer waits are one value.
  final String Function(int seconds) copiedMessage;

  /// Injectable so a test can watch the scheduling without waiting 45 s.
  final Future<void> Function() schedule;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value()));
        // Fire and forget, deliberately: the clear must happen even when this
        // sheet is closed a second later, which is the case where the person
        // is least likely to clear it themselves.
        unawaited(schedule());
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(copiedMessage(kClipboardSecretLifetime.inSeconds)),
          ),
        );
      },
      icon: const Icon(Icons.copy),
      label: Text(label),
    );
  }
}

/// A credential put on screen, and put there ONLY — the copy control beside it
/// is the single route off it.
///
/// The three secrets on this screen were displayed in [SelectableText], which
/// is an `EditableText` in read-only clothes. Long-press → Copy on a phone and
/// Ctrl/Cmd-C on a desktop both land in `Clipboard.setData` inside the
/// framework: no timer, no snackbar, no bound. So beside the [SecretCopyButton]
/// that schedules the clear and states the window, each of the certificate, the
/// code and the adoption token also had a second, unbounded route onto a
/// clipboard every app can read — on the one sheet the app wraps in
/// [SecureScreenGuard] precisely because a capture of it reconstructs the
/// signer.
///
/// Hiding the toolbar item was NOT the fix: `copySelection` is reached by the
/// keyboard shortcut with no toolbar ever built, so a `contextMenuBuilder` that
/// drops "Copy" is a lid laid over the hole. The text has to stop being
/// selectable.
///
/// [SelectionContainer.disabled] is not redundant with plain [Text]. There is
/// no ancestor `SelectionArea` on this screen today, and this is what stops
/// that from being a fact somebody has to keep remembering: wrap a sheet in one
/// tomorrow and every other line becomes selectable while these three do not.
class SecretText extends StatelessWidget {
  const SecretText(this.secret, {super.key, this.maxLines, this.fontSize});

  /// The credential itself.
  final String secret;

  /// Clipped past this many lines, as the certificate was before.
  final int? maxLines;

  /// Null keeps the surrounding text size; the long values ask for 10.
  final double? fontSize;

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: Text(
      secret,
      maxLines: maxLines,
      style: TextStyle(fontFamily: 'monospace', fontSize: fontSize),
    ),
  );
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
    // The one screen in the app that shows a sovereign recovery capability:
    // the certificate AND the code that unlocks it, at the same time. A
    // screenshot, a screen recording or a shoulder is enough to reconstruct
    // the signer and mint new device-group state as this identity — a
    // long-lived capability, not a session secret.
    //
    // The lock overlay was the only place that asked for this protection.
    // Nothing here did, so the most dangerous sheet in the app was the one
    // screen a recorder could keep.
    return SecureScreenGuard(
      child: SingleChildScrollView(
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
            SecretText(_certificate!, maxLines: 5, fontSize: 10),
            SecretCopyButton(
              label: l.devicesCopyCertificate,
              value: () => _certificate!,
              copiedMessage: l.devicesCertificateCopiedClears,
            ),
            const SizedBox(height: 8),
            SecretText(_code!),
            SecretCopyButton(
              label: l.devicesCopyCode,
              value: () => _code!,
              copiedMessage: l.devicesCodeCopiedClears,
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

  /// Why the last attempt failed, ready to show — not merely THAT it did.
  ///
  /// `gid == null` is a specific and fixable answer: this registry already
  /// holds devices, and recovery wants a fresh one. It used to be thrown as a
  /// StateError into a `catch (_)` that reported "Could not complete device
  /// linking" — generic, and about the wrong operation, since the reader was
  /// recovering rather than linking. The string that says the real thing sat
  /// unused in both ARBs.
  String? _failure;

  @override
  void dispose() {
    _certificate.dispose();
    _code.clear();
    _code.dispose();
    super.dispose();
  }

  Future<void> _recover() async {
    final l = AppL10n.of(context);
    final code = _code.text.trim();
    _code.clear();
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final certificate = SovereignRecoveryCertificate.parse(_certificate.text);
      final gid = await widget.service.recoverDeviceGroupFromCertificate(
        certificate.bytes,
        code,
      );
      if (gid == null) {
        // Not an exception: it is the one outcome here the reader can act on,
        // and throwing it into the catch below is what turned it into "could
        // not complete device linking" — generic, and about the wrong
        // operation.
        if (mounted) setState(() => _failure = l.devicesFreshRegistryRequired);
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.devicesRecovered)));
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _failure = l.devicesOperationFailed);
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
          if (_failure != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _failure!,
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
    required this.myDevice,
  });
  final GroupService service;
  final RealVeilStack stack;
  final String? credentialKind;

  /// This device's own invite. Both devices of an identity hand out the same
  /// CONTACT invite, so "is the scanned invite me?" can only be answered by
  /// the device's own key. Null when the config cannot be read — the check
  /// then falls back to identity ids and refuses a sibling, as before.
  final BootstrapInvite? myDevice;

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
      final link = DeviceLinkInvite.parse(_targetInvite.text);
      final target = link.device;
      if (link.isSelf(
        myDeviceNodeId: widget.myDevice?.nodeId ?? widget.service.selfId,
        myIdentityId: widget.service.selfId,
      )) {
        throw const FormatException('self device');
      }
      // MERGE FIRST. Until this device's document names the one being linked,
      // the registry it publishes lists a single instance and everything sent
      // afterwards is sealed for nobody.
      final theirDoc = link.document;
      if (theirDoc != null && theirDoc.isNotEmpty) {
        final merged = await RealVeilStack.adoptSovereignDocument(
          widget.service.storage,
          document: theirDoc,
          stagingBase: Directory.systemTemp.path,
        );
        // Hand it to the running node, or the registry it publishes still
        // names one instance and nothing can be sealed for the new device.
        if (merged) {
          await widget.stack.refreshSovereignIdentity(widget.service.storage);
        }
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
      // THE DOCUMENT HALF of the same admission. The group membership above
      // is what the identity's own devices see; the DOCUMENT is what the
      // registry publishes, what mailbox envelopes fan to, and what any
      // THIRD device verifies the new subkey against. Linking without it
      // left the document frozen and every row the new device signed
      // unverifiable elsewhere.
      final delegated = await RealVeilStack.delegateDeviceIntoDocument(
        widget.service.storage,
        phrase: words,
        devicePubkey: target.publicKey,
        stagingBase: Directory.systemTemp.path,
      );
      if (delegated) {
        await widget.stack.refreshSovereignIdentity(widget.service.storage);
      }
      // The MERGED document — read after the merge above, so it names both
      // devices. The return leg of the exchange the invite opened: without it
      // the other device finishes the ceremony still holding a document that
      // names only itself, and can seal nothing back to this one.
      final token = await widget.service.createDeviceLinkToken(
        sourceDevice: widget.myDevice?.nodeId,
        document: await RealVeilStack.storedSovereignDocument(
          widget.service.storage,
        ),
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
    final outcome = await sendDeviceSnapshotBounded(
      widget.service.broadcastDeviceGroup,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    switch (outcome) {
      case DeviceSnapshotSend.sent:
        // MEMBERSHIP FIRST, THEN THE HISTORY. The broadcast above says who the
        // devices are and nothing about what the identity has ever said, so a
        // device linked without the seed adopts the group correctly and opens
        // to an empty app. Not awaited: the snapshots are already on their way
        // and the person is done here — the sheet closes, and a seed that takes
        // its time does not hold it open.
        unawaited(_seedHistory());
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.devicesSetupSent)));
        Navigator.of(context).pop(true);
      // Each of these used to be the same "could not complete device linking",
      // and one of them used to be no message at all, forever.
      case DeviceSnapshotSend.timedOut:
        setState(() => _error = l.devicesSendUnreachable);
      case DeviceSnapshotSend.noTargets:
        setState(() => _error = l.devicesSendNoTargets);
      case DeviceSnapshotSend.failed:
        setState(() => _error = l.devicesOperationFailed);
    }
  }

  /// Ship the identity's existing groups to every OTHER device of it.
  ///
  /// Best-effort and deliberately silent: the link itself has already
  /// succeeded, and a history that arrives late still arrives — the next link,
  /// nudge or reconnect re-sends whatever is missing. Failing the ceremony over
  /// it would be the wrong trade.
  Future<void> _seedHistory() async {
    try {
      for (final device in await widget.service.otherDeviceIds()) {
        await widget.service.seedDevice(device);
      }
    } catch (_) {
      // Nothing to tell the person: the devices are linked either way.
    }
  }


  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final usesCertificate = widget.credentialKind == 'certificate';
    // The recovery export sheet was guarded and this one was not, on the
    // reasoning that a QR is a picture. It is not: `QrImageView` is handed the
    // adoption token verbatim, so a photograph of the code IS the token — the
    // same capability, in a form any camera in the room can lift from across a
    // desk, and one the token's own text is printed beside anyway. The sheet
    // also takes the recovery code or phrase in the branch above.
    return SecureScreenGuard(
      child: SingleChildScrollView(
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
            SecretText(_token!, fontSize: 10),
            SecretCopyButton(
              label: l.actionCopy,
              value: () => _token!,
              copiedMessage: l.devicesTokenCopiedClears,
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
      ),
    );
  }
}

class _TargetLinkSheet extends StatefulWidget {
  const _TargetLinkSheet({
    required this.service,
    required this.stack,
    required this.myDevice,
    required this.myDocument,
  });
  final GroupService service;
  final RealVeilStack stack;

  /// Goes into the QR the source scans — this device's own key, the thing that
  /// tells it from its siblings and makes it addressable. Never in the contact
  /// invite.
  final BootstrapInvite? myDevice;

  /// Travels with it: until the source's document names this device, nothing
  /// it sends can be sealed for us. See [DeviceLinkInvite.document].
  final Uint8List? myDocument;

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
      // The mirror of what the other device did with our invite's document.
      // Both have to end up holding the document naming both, or the link is
      // one-directional: this device would publish a registry of itself alone
      // and have nowhere to send a sync.
      final theirDoc = token.document;
      if (theirDoc != null && theirDoc.isNotEmpty) {
        final merged = await RealVeilStack.adoptSovereignDocument(
          widget.service.storage,
          document: theirDoc,
          stagingBase: Directory.systemTemp.path,
        );
        if (merged) {
          await widget.stack.refreshSovereignIdentity(widget.service.storage);
        }
      }
      if (!await widget.service.prepareDeviceAdoption(
        token,
        myDevice: widget.myDevice?.nodeId,
      )) {
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
    // The device's own invite when it is readable; the identity one only as a
    // last resort, which an older build's QR already is.
    final myInvite = widget.myDevice == null
        ? widget.stack.myInvite.toUri()
        : DeviceLinkInvite(
            device: widget.myDevice!,
            document: widget.myDocument,
          ).toUri();
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
