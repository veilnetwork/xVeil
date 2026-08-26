import 'dart:convert';

import 'arch_guard.dart';
import 'node_auto_update.dart' show kVeilUpdateLockPath;
import 'version_compare_shell.dart';
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
  sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml config get identity.node_id 2>/dev/null || \\
    sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node id 2>/dev/null || true
  sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml node show 2>/dev/null || true
  # HOW to reach this node, so it can be handed to somebody.
  #
  # A node id cannot be dialled: reaching a peer needs transport + public_key +
  # nonce, which is exactly what this URI carries. Deployment prints it and the
  # app spends it immediately — adding the node as its own entry point — and
  # then forgets it, so there was no way to share a connection to a server you
  # run. Read-only, and current: the transport can change, and a stored copy
  # would go stale without anyone noticing.
  echo -n "BOOTSTRAP_URI: "
  sudo -u veil /usr/local/bin/veil-cli -c /var/lib/veil/node.toml bootstrap invite 2>/dev/null \\
    | head -1 || echo "(unavailable)"
  # Is this server an EXIT, and who does it admit? Read from the file, because
  # `veil-cli config get proxy.exit.enabled` answers `unknown config key` —
  # measured on a live node, which is also why deployment writes these through
  # its own `set_toml_scalar` rather than `config set`.
  #
  # An app that lost its records (identity restored from a phrase, no device to
  # replicate from) learns from this whether the server it just re-attached is
  # routable at all, and whether THIS device is still on its list. Without it
  # the only way to find out was to deploy again over a working server.
  sudo awk '
    /^[[:space:]]*\\[/ {
      inexit = (\$0 ~ /^[[:space:]]*\\[[[:space:]]*proxy\\.exit[[:space:]]*\\]/); next
    }
    inexit && \$0 ~ /^[[:space:]]*enabled[[:space:]]*=/ {
      v = \$0; sub(/^[^=]*=[[:space:]]*/, "", v); en = v
    }
    inexit && \$0 ~ /^[[:space:]]*allow_all[[:space:]]*=/ {
      v = \$0; sub(/^[^=]*=[[:space:]]*/, "", v); aa = v
    }
    inexit && \$0 ~ /^[[:space:]]*allowed_node_ids[[:space:]]*=/ {
      v = \$0; sub(/^[^=]*=[[:space:]]*/, "", v)
      # A list broken across lines would read as a SHORTER list, and "admits
      # nobody" is not something to report from a half-read line.
      if (v !~ /]/) { ids = "(unread)" } else { gsub(/[][" ]/, "", v); ids = v }
    }
    END {
      printf "EXIT_ENABLED: %s\\n", (en == "" ? "false" : en)
      printf "EXIT_ALLOW_ALL: %s\\n", (aa == "" ? "false" : aa)
      printf "EXIT_ALLOWED: %s\\n", ids
    }
  ' /var/lib/veil/node.toml 2>/dev/null || true
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
/// [expectedVeilVersion] is what the node said it was running when the plan
/// was built, and [targetVeilVersion] is the tag the plan offers. Given both,
/// the install refuses unless the machine STILL runs the expected version and
/// the target is genuinely newer.
///
/// Which closes the window between Check and Apply: the timer, or another
/// administrator, can update the node in between, and a plan built before that
/// would put its older cached version back — undoing fixes and restarting the
/// service to do it (report15 X15-M12). Null skips the check, for callers that
/// have no plan to compare against.
String buildNodeSoftwareUpdateScript(
  List<NodeReleaseArtifact> artifacts, {
  String? expectedVeilVersion,
  String? targetVeilVersion,
}) {
  if (artifacts.isEmpty ||
      !artifacts.every((a) => a.isValid) ||
      artifacts.map((a) => a.component).toSet().length != artifacts.length) {
    throw ArgumentError('invalid or duplicate release artifacts');
  }

  // Staged inside a root-owned 0700 directory created at run time — see the
  // script below. The old `/tmp/xveil-update-<binary>` was predictable and
  // world-reachable, so a process running as the same SSH user could swap the
  // file between `sha256sum -c` and the `sudo install` that trusted it.
  String temp(NodeReleaseArtifact a) => '"\$stage/${a.component.binaryName}"';
  String unit(NodeReleaseArtifact a) => switch (a.component) {
    NodeComponent.veilCli => 'veil.service',
    NodeComponent.ogate => 'ogate.service',
    NodeComponent.oproxyClient => 'oproxy-client.service',
    NodeComponent.oproxyServer => 'oproxy-server.service',
  };

  final downloads = artifacts
      .map((a) {
        final t = temp(a);
        // Digest checked against the staged file by PATH, and the install below
        // reads that same path out of the same root-only directory — nothing
        // unprivileged can substitute the bytes in between.
        return '''sudo curl -fsSL '${a.releaseUrl.trim()}' -o $t
echo '${a.expectedSha256.trim().toLowerCase()}  '"$t" | sudo sha256sum -c -''';
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
        return "sudo install -o root -g root -m 0755 ${temp(a)} '/usr/local/bin/$binary'";
      })
      .join('\n');
  // The digest proves the bytes are the ones the release published. It says
  // NOTHING about whether they are for this machine — and the app offers an
  // arm64 target as readily as an x86_64 one, so the wrong choice reaches here
  // as a perfectly genuine file. A real x86_64 build installed over a working
  // aarch64 binary leaves a node that cannot start, so the machine itself
  // refuses before anything is overwritten.
  final checks = artifacts.map((a) => 'check_machine ${temp(a)}').join('\n');
  // Read on the HOST, under the lock, immediately before the install — not
  // from the plan. A version the app remembers is a statement about the past.
  final versionGuard =
      (expectedVeilVersion == null ||
          targetVeilVersion == null ||
          !artifacts.any((a) => a.component == NodeComponent.veilCli))
      ? '# no plan to compare against'
      : '''actual="\$(/usr/local/bin/veil-cli --version 2>/dev/null | awk '{print \$2}' || true)"
if [ "\$actual" != '${expectedVeilVersion.trim()}' ]; then
  echo 'XVEIL_VERSION_MOVED' >&2
  echo "the node runs \$actual, not ${expectedVeilVersion.trim()} as checked" >&2
  exit 4
fi
# And never sideways or backwards. The same comparator the unattended updater
# uses — `sort -V` reads a release candidate as newer than the stable release
# of the same number, in both directions (report16 XV-11).
if ! newer_than '${targetVeilVersion.trim()}' "\$actual"; then
  echo 'XVEIL_VERSION_NOT_NEWER' >&2
  exit 4
fi''';
  // Keep what was there. A node that updated itself into silence with nothing
  // to go back to is worse than one a version behind: whoever runs it is not
  // watching at the moment it happens, and the way back is a console.
  final backups = artifacts
      .map((a) {
        final binary = '/usr/local/bin/${a.component.binaryName}';
        // NOT `cp || true`. A copy that failed - a full disk, a read-only
        // mount - used to be swallowed, and the install then overwrote the
        // working binary with nothing to go back to. The whole point of
        // keeping a copy is that it is there.
        return '''if sudo test -e '$binary'; then
  sudo cp -a '$binary' '$binary.previous' || {
    echo 'cannot keep a copy of ${a.component.binaryName} - refusing to install over it' >&2
    exit 1
  }
else
  # Nothing to keep. Drop any copy an earlier run left, so a rollback cannot
  # restore a binary that was never the one running.
  sudo rm -f '$binary.previous'
fi''';
      })
      .join('\n');
  final restarts = artifacts
      .map((a) {
        final key = a.component.binaryName.replaceAll('-', '_');
        final binary = '/usr/local/bin/${a.component.binaryName}';
        return '''if [ "\$active_$key" = 1 ]; then
  # `restart` is NOT bare. Under `set -e` a non-zero return ended the shell
  # here, several lines above the restore it was supposed to reach - so the
  # rollback read correctly and had never once run.
  ok=1
  sudo systemctl restart '${unit(a)}' || ok=0
  if [ "\$ok" = 1 ]; then
    ok=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if sudo systemctl is-active --quiet '${unit(a)}'; then ok=1; break; fi
      sleep 2
    done
  fi
  # A unit reports active the moment it is started, and a binary built for the
  # wrong machine exits just after. Look again after a dwell rather than
  # believing the first yes.
  if [ "\$ok" = 1 ]; then
    sleep 3
    sudo systemctl is-active --quiet '${unit(a)}' || ok=0
  fi
  if [ "\$ok" = 0 ]; then
    echo "${a.component.binaryName} did not come back - restoring" >&2
    if sudo test -e '$binary.previous'; then
      sudo install -o root -g root -m 0755 '$binary.previous' '$binary'
      sudo systemctl restart '${unit(a)}' || true
    fi
    exit 1
  fi
fi''';
      })
      .join('\n');
  return '''#!/usr/bin/env bash
set -euo pipefail
stage="\$(sudo mktemp -d)"
trap 'sudo rm -rf "\$stage"' EXIT
$downloads
# Everything that TOUCHES the binary runs under one lock, shared with the
# unattended timer.
#
# Both paths install the same file and keep the same `.previous` copy beside
# it. Interleaved, one can decide its install failed and restore a binary over
# the one the other just started - a rollback of somebody else's success
# (report15 X15-M13). Downloading stays outside: network work has no business
# holding a lock.
#
# Staged as a file rather than quoted into `flock -c`, because this section
# carries its own quoting and a second layer of it is how a rollback becomes a
# syntax error.
critical="\$stage/critical.sh"
sudo tee "\$critical" >/dev/null <<'XVEIL_CRITICAL'
#!/usr/bin/env bash
set -euo pipefail
stage="\$1"
XVEIL_ARCH_GUARD
XVEIL_NEWER_THAN
$checks
$versionGuard
$snapshots
$backups
$installs
$restarts
echo "UPDATED: ${artifacts.map((a) => a.component.binaryName).join(',')}"
XVEIL_CRITICAL
sudo chmod 0755 "\$critical"
sudo mkdir -p "\$(dirname '$kVeilUpdateLockPath')"
# Waiting, not skipping: a person is looking at this screen and pressed Apply.
sudo flock -w 600 '$kVeilUpdateLockPath' "\$critical" "\$stage"
'''
      // Substituted after the template is built: the heredoc above is quoted,
      // so the shell expands nothing inside it, and the guard stays ONE shared
      // text rather than a copy that can drift from the deployment script's.
      .replaceFirst('XVEIL_ARCH_GUARD', kArchGuardShell.trim())
      .replaceFirst('XVEIL_NEWER_THAN', kNewerThanShell.trim());
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
# The digest of the bytes being handed over, so a save can tell whether the
# file it is about to replace is still the one that was read. Without it a
# second administrator's change - a revoked allowlist id, a listener, a
# hardening setting - is silently rolled back by whoever loaded first.
echo -n 'XVEIL_CONFIG_SHA256: '
sudo sha256sum '${target.path}' | cut -d' ' -f1
echo 'XVEIL_CONFIG_BEGIN'
sudo base64 -w 0 '${target.path}' 2>/dev/null || sudo base64 '${target.path}' | tr -d '\\n'
echo
echo 'XVEIL_CONFIG_END'
''';

/// A config as it stood on the server, with the digest of exactly those bytes.
class NodeConfigRead {
  const NodeConfigRead({required this.contents, required this.sha256});

  final String contents;

  /// What the file hashed to when it was read, or null for a node running a
  /// script too old to report one. Null means a save cannot check, and that is
  /// a fact to carry rather than a value to invent.
  final String? sha256;
}

/// Read the config a run reported. Null when there is none to read.
NodeConfigRead? parseReadNodeConfig(String stdout) {
  final match = RegExp(
    r'XVEIL_CONFIG_BEGIN\s*([A-Za-z0-9+/=\r\n]+?)\s*XVEIL_CONFIG_END',
  ).firstMatch(stdout);
  if (match == null) return null;
  final digest = RegExp(
    r'XVEIL_CONFIG_SHA256:\s*([0-9a-f]{64})',
  ).firstMatch(stdout);
  try {
    return NodeConfigRead(
      contents: utf8.decode(
        base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), '')),
      ),
      sha256: digest?.group(1),
    );
  } catch (_) {
    return null;
  }
}

/// The lock a config apply takes on the machine.
///
/// One per node rather than per file: the four configs this edits belong to
/// services that start each other, and two applies landing at once is the case
/// this is about however different their targets.
const String kVeilConfigLockPath = '/run/lock/xveil-veil-config.lock';

/// Transactionally replace a remote TOML file. veil and ogate have explicit
/// offline validators; oproxy is validated by starting/restarting its service.
/// A failed activation restores the exact previous file and prior enabled state.
/// [expectedSha256] is what the file hashed to when it was READ. The install
/// refuses if the file has changed since — a second administrator, an
/// automation, the node's own writer — because this replaces the whole file and
/// has no way to keep what it never saw. Null skips the check, which is what a
/// node running an older read script leaves us with; it is a narrower promise,
/// not a different one.
String buildWriteNodeConfigScript(
  NodeConfigTarget target,
  String contents, {
  String? expectedSha256,
}) {
  if (utf8.encode(contents).length > 1024 * 1024) {
    throw ArgumentError('config is larger than 1 MiB');
  }
  if (expectedSha256 != null &&
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedSha256)) {
    throw ArgumentError('expected digest is not a sha256: $expectedSha256');
  }
  final payload = base64Encode(utf8.encode(contents));
  final path = target.path;
  final unit = target.service.unit;
  // Checked HERE, against the file about to be replaced, and as late as it can
  // be: between Load and Apply somebody else can change this file, and a
  // full-file write has no way to keep a change it never saw. The comparison
  // is on the backup copy, which is the exact bytes `install` is about to
  // overwrite.
  final guard = expectedSha256 == null
      ? '# no digest was reported by the read, so nothing can be compared'
      : '''if [ "\$had_config" = 1 ]; then
  now="\$(sudo sha256sum "\$backup" | cut -d' ' -f1)"
  if [ "\$now" != '$expectedSha256' ]; then
    echo 'XVEIL_CONFIG_CHANGED' >&2
    echo "the file changed since it was read (\$now)" >&2
    exit 4
  fi
else
  # There WAS a file when this was read — that is what having a digest means —
  # and there is not one now. Somebody removed it, and writing the copy this
  # screen is holding would put a deleted config back without anybody
  # deciding to (report16 XV-19). A guard that only runs when the file is
  # still there is skipped by exactly the change it exists to catch.
  echo 'XVEIL_CONFIG_CHANGED' >&2
  echo 'the file was removed since it was read' >&2
  exit 4
fi''';
  // Whose group reaches the staging area. The validators for veil and ogate
  // run as `veil` and must READ what was staged; oproxy is validated by
  // starting its service, so nothing but root ever opens the staged file and
  // the group is root's own.
  final stageGroup = switch (target) {
    NodeConfigTarget.veil || NodeConfigTarget.ogate => 'veil',
    NodeConfigTarget.oproxyClient || NodeConfigTarget.oproxyServer => 'root',
  };
  final validate = switch (target) {
    NodeConfigTarget.veil =>
      'sudo -u veil /usr/local/bin/veil-cli -c "\$temp" config validate',
    NodeConfigTarget.ogate =>
      'sudo -u veil /usr/local/bin/ogate show --config "\$temp" >/dev/null',
    NodeConfigTarget.oproxyClient || NodeConfigTarget.oproxyServer =>
      '# oproxy validates its complete config during service activation',
  };

  final body = '''#!/usr/bin/env bash
set -euo pipefail
# Staging lives in a ROOT-OWNED, 0700, unpredictably-named directory.
#
# It used to be a fixed `/tmp/xveil-<name>.toml` plus a backup at
# `<path>.xveil-backup` — a fixed sibling in a directory the `veil` service
# user can write. A compromised `veil` could pre-place a symlink under either
# name pointing at any root-owned file; the next administrative save then had
# root follow it (`cp --preserve` writes THROUGH a destination symlink) and
# overwrite the target. `mktemp -d` run as root creates the directory
# atomically with 0700 and a name nobody can predict, so there is nothing to
# pre-place and nobody but root can reach it.
stage="\$(sudo mktemp -d)"
trap 'sudo rm -rf "\$stage"' EXIT
# Reachable by root and by the validator, and by NOBODY else.
#
# It used to be `0711` on the directory and `0644` on the file, so that the
# validators — which run as `veil` — could read what was staged. That made the
# staged file world-readable under a fixed name in a world-traversable
# directory, and for the veil target the staged file is the contents of
# `/var/lib/veil/node.toml`, which carries `[identity] private_key`. The real
# file is `0600` for exactly that reason; the copy this script made was not,
# and `/tmp` is observable, so any local account could poll for the directory
# and read the key without sudo (report16 X16-H3).
#
# Group, not world: the validator gets in through `root:$stageGroup 0710`, and
# the file through `0640`. Still not writable by it — the bytes stay root-owned
# until `install` puts them in place, so the validated content cannot be
# rewritten underneath.
sudo chown root:$stageGroup "\$stage"
sudo chmod 0710 "\$stage"
temp="\$stage/config.toml"
backup="\$stage/config.backup"
path='$path'
was_enabled=0
was_active=0
sudo systemctl is-enabled --quiet '$unit' && was_enabled=1 || true
sudo systemctl is-active --quiet '$unit' && was_active=1 || true
# Written THROUGH sudo: the staging dir is root-only, so the unprivileged
# shell cannot create the file itself.
printf '%s' '$payload' | base64 -d | sudo tee "\$temp" >/dev/null
# Readable by the validator's group and by nobody else; writable by root
# alone. `install` below sets the real owner and mode on the destination, so
# staging never has to widen this.
sudo chown root:$stageGroup "\$temp"
sudo chmod 0640 "\$temp"
$validate
# Existence, copy, compare and install under ONE lock on this config.
#
# Without it two administrators can both read the same digest, both copy the
# same bytes, both find their own backup unchanged and both install — last one
# wins, and the other's change is gone with nothing having said so. The window
# between the copy and the install is enough on its own.
#
# Staged as a file rather than quoted into `flock -c`, for the same reason the
# update path does it: this section carries its own quoting.
sudo mkdir -p "\$(dirname '$kVeilConfigLockPath')"
critical="\$stage/apply.sh"
sudo tee "\$critical" >/dev/null <<'XVEIL_APPLY'
#!/usr/bin/env bash
set -euo pipefail
stage="\$1"
path="\$2"
temp="\$stage/config.toml"
backup="\$stage/config.backup"
had_config=0
if sudo test -f "\$path"; then
  had_config=1
  sudo cp --preserve=mode,ownership,timestamps "\$path" "\$backup"
fi
XVEIL_GUARD
sudo install -o ${target.owner} -g ${target.group} -m ${target.mode} "\$temp" "\$path"
echo "\$had_config" > "\$stage/had_config"
XVEIL_APPLY
sudo chmod 0700 "\$critical"
sudo flock -w 300 '$kVeilConfigLockPath' "\$critical" "\$stage" "\$path"
had_config="\$(sudo cat "\$stage/had_config")"
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
  echo 'CONFIG_ROLLED_BACK'
  exit 1
fi
echo "CONFIG_APPLIED: $path"
echo "ACTIVE: \$(sudo systemctl is-active '$unit' 2>/dev/null || true)"
'''
      // Substituted after the template is built: the heredoc above is quoted,
      // so the shell expands nothing inside it, and the guard is the same text
      // whether or not the apply runs under the lock.
      .replaceFirst('XVEIL_GUARD', guard);
  return body;
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
