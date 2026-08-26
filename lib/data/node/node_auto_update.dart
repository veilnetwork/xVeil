import 'veil_github_release.dart' show kMinimumVeilReleaseTag;

/// How often the node looks for a new veil release.
const String kNodeAutoUpdateSchedule = 'daily';

/// Where the self-updater and its units live on the server.
const String kAutoUpdateScriptPath = '/usr/local/sbin/xveil-node-autoupdate';
const String kAutoUpdateUnit = 'xveil-node-autoupdate';

/// Install (or remove) a self-updater on the deployed node.
///
/// Why the SERVER updates itself rather than the app updating it: every remote
/// action this app performs asks for SSH credentials at the moment it runs,
/// because it deliberately stores none. An update that must happen while
/// nobody is holding the phone therefore cannot be driven from here at all —
/// the only way to make it automatic from the app would be to keep a key or a
/// password for a root-capable account, which is a far larger decision than
/// staying current.
///
/// **What enabling this trusts.** The node will fetch a binary over the network
/// and install it as root, unattended, on a schedule. It verifies the digest
/// the release publishes — which catches a substitution in transit or at a
/// mirror, and says nothing whatever about who published the release: the
/// manifest is an asset of the same release, from the same host, under the same
/// tag. So whoever can publish a veil release can, from that moment, run code
/// as root on every node that has this switched on, without anyone looking.
/// That is the trade, and it is why this is a switch and not a fact.
///
/// What it does refuse:
///
/// * anything below [kMinimumVeilReleaseTag], so an API that can be made to
///   answer with an old release cannot walk a node backwards into a known
///   hole;
/// * a release whose digest does not match the bytes that arrived;
/// * a downgrade or a reinstall of what is already there — nothing is touched
///   unless the tag is genuinely newer.
///
/// And what it does when it goes wrong: the previous binary is kept, and if the
/// service does not come back the old one is restored and restarted. A node
/// that updated itself into silence is worse than one that is a version behind,
/// because nobody is watching at the moment it happens.
String buildNodeAutoUpdateScript({
  required bool enabled,
  String minimumTag = kMinimumVeilReleaseTag,
  String schedule = kNodeAutoUpdateSchedule,
}) {
  if (!enabled) return _disableScript;
  final floor = minimumTag.trim();
  if (!RegExp(r'^v\d{1,6}\.\d{1,6}\.\d{1,6}$').hasMatch(floor)) {
    throw ArgumentError('minimum tag must look like v1.2.3: $minimumTag');
  }
  if (!RegExp(r'^[a-z-]{3,20}$').hasMatch(schedule)) {
    throw ArgumentError('schedule must be a systemd calendar word: $schedule');
  }

  return '''#!/usr/bin/env bash
set -euo pipefail

# The updater itself. Written to a root-owned file and never sourced from
# anywhere else: everything it acts on comes from the release API and is
# checked before use.
sudo tee $kAutoUpdateScriptPath >/dev/null <<'XVEIL_UPDATER'
#!/usr/bin/env bash
set -euo pipefail

FLOOR='$floor'
API='https://api.github.com/repos/veilnetwork/veil/releases/latest'
BIN=/usr/local/bin/veil-cli
UNIT=veil.service

case "\$(uname -m)" in
  x86_64)  TRIPLE=x86_64-unknown-linux-musl ;;
  aarch64) TRIPLE=aarch64-unknown-linux-musl ;;
  *) echo "unsupported architecture: \$(uname -m)" >&2; exit 0 ;;
esac

# `sort -V` decides "is A older than B" the way a person would read it, and is
# in coreutils everywhere this runs. The comparison is deliberately one-way:
# equal is NOT newer, so a re-run installs nothing.
newer_than() { [ "\$1" != "\$2" ] && [ "\$(printf '%s\\n%s\\n' "\$1" "\$2" | sort -V | tail -1)" = "\$1" ]; }

json="\$(curl -fsSL --max-time 30 "\$API")" || { echo "release API unreachable" >&2; exit 0; }
tag="\$(printf '%s' "\$json" | grep -o '"tag_name":[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)"
[ -n "\$tag" ] || { echo "no tag in release" >&2; exit 0; }

# The floor, first: an API that can be made to answer with an old release must
# not be able to walk this node backwards.
newer_than "\$tag" "\$FLOOR" || [ "\$tag" = "\$FLOOR" ] || {
  echo "refusing \$tag: below the floor \$FLOOR" >&2; exit 0; }

have="v\$("\$BIN" --version 2>/dev/null | awk '{print \$2}')"
newer_than "\$tag" "\$have" || { echo "already at \$have"; exit 0; }

stage="\$(mktemp -d)"
trap 'rm -rf "\$stage"' EXIT
base="https://github.com/veilnetwork/veil/releases/download/\$tag"
curl -fsSL --max-time 300 -o "\$stage/veil-cli" "\$base/veil-cli-\$TRIPLE"
curl -fsSL --max-time 60  -o "\$stage/sums" "\$base/sha256-\$TRIPLE.txt"

want="\$(awk '\$2 == "veil-cli" {print \$1}' "\$stage/sums" | head -1)"
[ -n "\$want" ] || { echo "no digest for veil-cli in \$tag" >&2; exit 1; }
got="\$(sha256sum "\$stage/veil-cli" | cut -d' ' -f1)"
[ "\$want" = "\$got" ] || { echo "digest mismatch for \$tag" >&2; exit 1; }

was_active=0
systemctl is-active --quiet "\$UNIT" && was_active=1 || true

cp -a "\$BIN" "\$BIN.previous"
install -o root -g root -m 0755 "\$stage/veil-cli" "\$BIN"

if [ "\$was_active" = 1 ]; then
  systemctl restart "\$UNIT"
  # A node that updated itself into silence is worse than one a version
  # behind: nobody is watching at the moment it happens.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    systemctl is-active --quiet "\$UNIT" && break
    sleep 2
  done
  if ! systemctl is-active --quiet "\$UNIT"; then
    echo "\$tag did not come back — restoring" >&2
    install -o root -g root -m 0755 "\$BIN.previous" "\$BIN"
    systemctl restart "\$UNIT" || true
    exit 1
  fi
fi
echo "updated to \$tag"
XVEIL_UPDATER
sudo chown root:root $kAutoUpdateScriptPath
sudo chmod 0755 $kAutoUpdateScriptPath

sudo tee /etc/systemd/system/$kAutoUpdateUnit.service >/dev/null <<'XVEIL_UNIT'
[Unit]
Description=xVeil node self-update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$kAutoUpdateScriptPath
XVEIL_UNIT

sudo tee /etc/systemd/system/$kAutoUpdateUnit.timer >/dev/null <<'XVEIL_TIMER'
[Unit]
Description=xVeil node self-update schedule

[Timer]
OnCalendar=$schedule
# Spread the fleet: every node asking the API at the same instant is both a
# thundering herd and a pattern.
RandomizedDelaySec=3h
Persistent=true

[Install]
WantedBy=timers.target
XVEIL_TIMER

sudo systemctl daemon-reload
sudo systemctl enable --now $kAutoUpdateUnit.timer
echo "AUTOUPDATE: enabled schedule=$schedule floor=$floor"
''';
}

const String _disableScript =
    '''#!/usr/bin/env bash
set -euo pipefail
# Removing rather than masking: a disabled timer that stays on disk is a thing
# somebody re-enables by accident later, and this one installs binaries as root.
sudo systemctl disable --now $kAutoUpdateUnit.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/$kAutoUpdateUnit.timer \\
  /etc/systemd/system/$kAutoUpdateUnit.service $kAutoUpdateScriptPath
sudo systemctl daemon-reload
echo "AUTOUPDATE: disabled"
''';
