import '../../data/vpn/vpn_backend.dart';
import '../../l10n/app_localizations.dart';

/// What to SHOW when the VPN is in its error phase.
///
/// The engine's own refusal comes back as a named [VpnStartFailure]; a raw
/// [VpnBackendState.detail] is a log line, in English, written for whoever
/// wrote the engine. Showing it verbatim is how a Russian screen ends up
/// saying "could not start packet tunnel" — which also happens to name
/// nothing a person can act on.
String vpnStartFailureText(AppL10n l, VpnBackendState backend) =>
    switch (backend.failure) {
      VpnStartFailure.alreadyRunning => l.vpnStartAlreadyRunning,
      VpnStartFailure.invalidArgument => l.vpnStartInvalidArgument,
      VpnStartFailure.closed => l.vpnStartClosed,
      VpnStartFailure.refused => l.vpnStartRefused,
      VpnStartFailure.workersStranded => l.vpnStartWorkersStranded,
      // The engine's own account of a death after start is the most specific
      // thing there is, so it wins over the named floor when it left one.
      VpnStartFailure.stoppedDuringStartup =>
        backend.detail ?? l.vpnStartStoppedDuringStartup,
      VpnStartFailure.selectorMissing => l.vpnStartSelectorMissing,
      VpnStartFailure.engineMissing => l.vpnStartEngineMissing,
      // No named reason. There still may be words from the engine or the
      // platform — the tunnel that DIED after starting records why, and that
      // slot is readable because its object still exists. Naming the reason
      // was meant to add to what a person is told, not to replace a real
      // message with a generic one.
      null => backend.detail ?? l.vpnStatusError,
    };
