import 'dart:convert';

import 'node_provisioner.dart';

enum NodeManagedService { veil, ogate, oproxyClient, oproxyServer }

extension NodeManagedServiceInfo on NodeManagedService {
  String get unit => switch (this) {
    NodeManagedService.veil => 'veil.service',
    NodeManagedService.ogate => 'ogate.service',
    NodeManagedService.oproxyClient => 'oproxy-client.service',
    NodeManagedService.oproxyServer => 'oproxy-server.service',
  };

  String get binary => switch (this) {
    NodeManagedService.veil => 'veil-cli',
    NodeManagedService.ogate => 'ogate',
    NodeManagedService.oproxyClient => 'oproxy-client',
    NodeManagedService.oproxyServer => 'oproxy-server',
  };
}

enum NodeServiceAction { status, start, stop, restart, enable, disable }

enum NodeConfigTarget { veil, ogate, oproxyClient, oproxyServer }

extension NodeConfigTargetInfo on NodeConfigTarget {
  String get path => switch (this) {
    NodeConfigTarget.veil => '/var/lib/veil/node.toml',
    NodeConfigTarget.ogate => '/etc/ogate/ogate.toml',
    NodeConfigTarget.oproxyClient => '/etc/oproxy/client.toml',
    NodeConfigTarget.oproxyServer => '/etc/oproxy/server.toml',
  };

  NodeManagedService get service => switch (this) {
    NodeConfigTarget.veil => NodeManagedService.veil,
    NodeConfigTarget.ogate => NodeManagedService.ogate,
    NodeConfigTarget.oproxyClient => NodeManagedService.oproxyClient,
    NodeConfigTarget.oproxyServer => NodeManagedService.oproxyServer,
  };

  String get owner => 'veil';
  String get group => 'veil';
  String get mode => this == NodeConfigTarget.veil ? '0600' : '0640';
}

/// Read-only inventory used by the management overview. It never assumes a
/// component is installed and emits stable key/value lines that the UI can
/// display without scraping localized `systemctl status` prose.
String buildNodeInventoryScript() => '''#!/usr/bin/env bash
set -u
echo "HOST_OS: \$(uname -srm 2>/dev/null || true)"
for binary in veil-cli ogate oproxy-client oproxy-server; do
  if command -v "\$binary" >/dev/null 2>&1; then
    echo "BINARY_\${binary}: present"
    "\$binary" --version 2>/dev/null | head -n 1 || true
  else
    echo "BINARY_\${binary}: missing"
  fi
done
for unit in veil.service ogate.service oproxy-client.service oproxy-server.service; do
  echo "UNIT_\${unit}_ACTIVE: \$(sudo systemctl is-active "\$unit" 2>/dev/null || true)"
  echo "UNIT_\${unit}_ENABLED: \$(sudo systemctl is-enabled "\$unit" 2>/dev/null || true)"
done
if sudo test -x /usr/local/bin/veil-cli && sudo test -f /var/lib/veil/node.toml; then
  echo -n "NODE_ID: "
  sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node id 2>/dev/null || true
  sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node show 2>/dev/null || true
fi
''';

String buildNodeServiceActionScript(
  NodeManagedService service,
  NodeServiceAction action,
) {
  final unit = service.unit;
  final command = switch (action) {
    NodeServiceAction.status =>
      "sudo systemctl --no-pager --full status '$unit' || true",
    NodeServiceAction.start => "sudo systemctl start '$unit'",
    NodeServiceAction.stop => "sudo systemctl stop '$unit'",
    NodeServiceAction.restart => "sudo systemctl restart '$unit'",
    NodeServiceAction.enable => "sudo systemctl enable --now '$unit'",
    NodeServiceAction.disable => "sudo systemctl disable --now '$unit'",
  };
  return '''#!/usr/bin/env bash
set -euo pipefail
$command
echo "UNIT: $unit"
echo "ACTIVE: \$(sudo systemctl is-active '$unit' 2>/dev/null || true)"
echo "ENABLED: \$(sudo systemctl is-enabled '$unit' 2>/dev/null || true)"
''';
}

/// Upgrade any selected set of release assets. Authentication is all-or-none:
/// every download passes its expected digest before the first installed binary
/// is replaced. Only services that were active before the upgrade are restarted.
String buildNodeSoftwareUpdateScript(List<NodeReleaseArtifact> artifacts) {
  if (artifacts.isEmpty ||
      !artifacts.every((a) => a.isValid) ||
      artifacts.map((a) => a.component).toSet().length != artifacts.length) {
    throw ArgumentError('invalid or duplicate release artifacts');
  }

  String temp(NodeReleaseArtifact a) =>
      '/tmp/xveil-update-${a.component.binaryName}';
  String unit(NodeReleaseArtifact a) => switch (a.component) {
    NodeComponent.veilCli => 'veil.service',
    NodeComponent.ogate => 'ogate.service',
    NodeComponent.oproxyClient => 'oproxy-client.service',
    NodeComponent.oproxyServer => 'oproxy-server.service',
  };

  final downloads = artifacts
      .map((a) {
        final t = temp(a);
        return '''curl -fsSL '${a.releaseUrl.trim()}' -o '$t'
echo '${a.expectedSha256.trim().toLowerCase()}  $t' | sha256sum -c -''';
      })
      .join('\n');
  final snapshots = artifacts
      .map((a) {
        final key = a.component.binaryName.replaceAll('-', '_');
        return "active_$key=0; sudo systemctl is-active --quiet '${unit(a)}' && active_$key=1 || true";
      })
      .join('\n');
  final installs = artifacts
      .map((a) {
        final binary = a.component.binaryName;
        return "sudo install -o root -g root -m 0755 '${temp(a)}' '/usr/local/bin/$binary'";
      })
      .join('\n');
  final restarts = artifacts
      .map((a) {
        final key = a.component.binaryName.replaceAll('-', '_');
        return "if [ \"\$active_$key\" = 1 ]; then sudo systemctl restart '${unit(a)}'; fi";
      })
      .join('\n');
  final cleanup = artifacts.map(temp).join(' ');

  return '''#!/usr/bin/env bash
set -euo pipefail
trap 'rm -f $cleanup' EXIT
$downloads
$snapshots
$installs
$restarts
echo "UPDATED: ${artifacts.map((a) => a.component.binaryName).join(',')}"
''';
}

/// Fetch one exact remote config as base64 between markers. Base64 keeps
/// arbitrary TOML, comments and newlines out of SSH's shell/output framing.
String buildReadNodeConfigScript(NodeConfigTarget target) =>
    '''#!/usr/bin/env bash
set -euo pipefail
if ! sudo test -f '${target.path}'; then
  echo 'XVEIL_CONFIG_MISSING'
  exit 3
fi
echo 'XVEIL_CONFIG_BEGIN'
sudo base64 -w 0 '${target.path}' 2>/dev/null || sudo base64 '${target.path}' | tr -d '\\n'
echo
echo 'XVEIL_CONFIG_END'
''';

String? parseReadNodeConfig(String stdout) {
  final match = RegExp(
    r'XVEIL_CONFIG_BEGIN\s*([A-Za-z0-9+/=\r\n]+?)\s*XVEIL_CONFIG_END',
  ).firstMatch(stdout);
  if (match == null) return null;
  try {
    return utf8.decode(
      base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')),
    );
  } catch (_) {
    return null;
  }
}

/// Transactionally replace a remote TOML file. veil and ogate have explicit
/// offline validators; oproxy is validated by starting/restarting its service.
/// A failed activation restores the exact previous file and prior enabled state.
String buildWriteNodeConfigScript(NodeConfigTarget target, String contents) {
  if (utf8.encode(contents).length > 1024 * 1024) {
    throw ArgumentError('config is larger than 1 MiB');
  }
  final payload = base64Encode(utf8.encode(contents));
  final path = target.path;
  final unit = target.service.unit;
  final temp = '/tmp/xveil-${target.name}.toml';
  final backup = '$path.xveil-backup';
  final validate = switch (target) {
    NodeConfigTarget.veil =>
      "sudo -u veil /usr/local/bin/veil-cli -c '$temp' config validate",
    NodeConfigTarget.ogate =>
      "sudo -u veil /usr/local/bin/ogate show --config '$temp' >/dev/null",
    NodeConfigTarget.oproxyClient || NodeConfigTarget.oproxyServer =>
      '# oproxy validates its complete config during service activation',
  };

  return '''#!/usr/bin/env bash
set -euo pipefail
temp='$temp'
path='$path'
backup='$backup'
was_enabled=0
was_active=0
sudo systemctl is-enabled --quiet '$unit' && was_enabled=1 || true
sudo systemctl is-active --quiet '$unit' && was_active=1 || true
sudo rm -f "\$temp"
printf '%s' '$payload' | base64 -d > "\$temp"
chmod ${target.mode} "\$temp"
sudo chown ${target.owner}:${target.group} "\$temp"
$validate
had_config=0
if sudo test -f "\$path"; then
  had_config=1
  sudo cp --preserve=mode,ownership,timestamps "\$path" "\$backup"
fi
sudo install -o ${target.owner} -g ${target.group} -m ${target.mode} "\$temp" "\$path"
activation_ok=1
sudo systemctl enable --now '$unit' || activation_ok=0
sleep 1
sudo systemctl is-active --quiet '$unit' || activation_ok=0
if [ "\$activation_ok" = 0 ]; then
  if [ "\$had_config" = 1 ]; then
    sudo mv "\$backup" "\$path"
  else
    sudo rm -f "\$path"
  fi
  if [ "\$was_enabled" = 0 ]; then sudo systemctl disable '$unit' >/dev/null 2>&1 || true; fi
  if [ "\$was_active" = 1 ]; then sudo systemctl restart '$unit' >/dev/null 2>&1 || true; fi
  sudo rm -f "\$temp"
  echo 'CONFIG_ROLLED_BACK'
  exit 1
fi
sudo rm -f "\$backup"
sudo rm -f "\$temp"
echo "CONFIG_APPLIED: $path"
echo "ACTIVE: \$(sudo systemctl is-active '$unit' 2>/dev/null || true)"
''';
}

/// Remove selected programs/units while preserving identity and configs. This
/// is the reversible “uninstall software” half of lifecycle management.
String buildNodeUninstallScript(Set<NodeManagedService> services) {
  if (services.isEmpty) throw ArgumentError('no services selected');
  final stop = services
      .map(
        (s) =>
            "sudo systemctl disable --now '${s.unit}' >/dev/null 2>&1 || true",
      )
      .join('\n');
  final units = services
      .map((s) => "sudo rm -f '/etc/systemd/system/${s.unit}'")
      .join('\n');
  final binaries = services
      .map((s) => "sudo rm -f '/usr/local/bin/${s.binary}'")
      .join('\n');
  return '''#!/usr/bin/env bash
set -euo pipefail
$stop
$units
$binaries
sudo systemctl daemon-reload
echo 'SOFTWARE_REMOVED'
echo 'DATA_PRESERVED: /var/lib/veil /etc/ogate /etc/oproxy'
''';
}

/// Irreversible “debootstrap”: exact, bounded paths only. Removes every managed
/// component, node identity/state, application configs and the dedicated user.
String buildNodeDebootstrapScript() => '''#!/usr/bin/env bash
set -euo pipefail
for unit in ogate.service oproxy-client.service oproxy-server.service veil.service; do
  sudo systemctl disable --now "\$unit" >/dev/null 2>&1 || true
  sudo rm -f "/etc/systemd/system/\$unit"
done
sudo rm -f /usr/local/bin/veil-cli /usr/local/bin/ogate \\
  /usr/local/bin/oproxy-client /usr/local/bin/oproxy-server
sudo rm -rf -- /var/lib/veil /var/log/veil /etc/ogate /etc/oproxy
sudo userdel veil >/dev/null 2>&1 || true
sudo systemctl daemon-reload
echo 'NODE_DEBOOTSTRAPPED'
''';
