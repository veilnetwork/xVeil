/// Generates the bash install script that provisions a veil node on a remote
/// server over SSH — the automation behind "Мои узлы → provision". It mirrors
/// the proven `prod-seeds/deploy.sh` steps, but pulls the `veil-cli` binary from
/// a GitHub release ([releaseUrl]) instead of scp'ing a local build, and embeds
/// the deployment obfs4 PSK the app already bundles.
///
/// The script is shown to the user for REVIEW before it runs (it executes as
/// root via sudo), so this is a transparent template, not a hidden action.
class NodeProvisionConfig {
  const NodeProvisionConfig({
    required this.releaseUrl,
    required this.expectedSha256,
    required this.obfs4PskB64,
    this.listenPort = 5556,
    this.runExit = true,
  });

  /// Direct URL to a `veil-cli` binary for the server's arch (a GitHub release
  /// asset, e.g. `…/veil-cli-x86_64-unknown-linux-musl`).
  final String releaseUrl;

  /// REQUIRED SHA-256 (64 hex) of the exact binary at [releaseUrl]. The script
  /// verifies the download against it BEFORE installing + running it as root, so
  /// a tampered release asset, a hijacked URL, or a TLS-stripping proxy cannot
  /// turn provisioning into root RCE on the user's server. Published alongside
  /// the release; the user pastes it in.
  final String expectedSha256;

  /// The deployment-wide obfs4 PSK (base64) the node needs to join the network —
  /// the same value the app bundles at `assets/prod/obfs4_psk.b64`.
  final String obfs4PskB64;

  /// obfs4 listener port the node advertises.
  final int listenPort;

  /// Enable the exit proxy so you can route your traffic through this node.
  final bool runExit;

  static final _sha256Re = RegExp(r'^[0-9a-fA-F]{64}$');
  // Conservative URL allowlist: the release URL is interpolated into a shell
  // command that runs as root via sudo, so it must NOT contain a single quote
  // (quote-breakout) or any shell metacharacter. A real GitHub-release asset URL
  // uses only this set. The checksum gate protects the binary's CONTENTS but not
  // the URL string, so this is what closes the inject-via-URL root-RCE.
  static final _safeUrlRe = RegExp(r'^https://[A-Za-z0-9._~:/?#@%=+,-]+$');
  // obfs4 PSK is written into a `<<'PSK_EOF'` heredoc; valid base64 has no
  // newline and (crucially) no underscore, so it can neither break the heredoc
  // delimiter nor inject lines.
  static final _b64Re = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

  static bool _isSafeHttpsUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null && u.scheme == 'https' && u.host.isNotEmpty &&
        _safeUrlRe.hasMatch(s);
  }

  static bool _isBase64(String s) =>
      s.isNotEmpty && s.length % 4 == 0 && _b64Re.hasMatch(s);

  bool get isValid =>
      _isSafeHttpsUrl(releaseUrl.trim()) &&
      _sha256Re.hasMatch(expectedSha256.trim()) &&
      _isBase64(obfs4PskB64.trim()) &&
      listenPort >= 1 &&
      listenPort <= 65535;
}

/// The systemd unit (mirrors prod-seeds/veil.service).
const _veilService = '''[Unit]
Description=Veil node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=veil
Group=veil
ExecStart=/usr/local/bin/veil-cli --config /var/lib/veil/node.toml node run --foreground
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
LimitMEMLOCK=infinity
StandardOutput=append:/var/log/veil/veil.log
StandardError=append:/var/log/veil/veil.log
WorkingDirectory=/var/lib/veil
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/var/lib/veil /var/log/veil
ProtectHome=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target''';

/// Build the provisioning script. Idempotent on the server: it re-installs the
/// binary/unit/PSK each run but only MINES a fresh identity when none exists, so
/// re-running never rotates the node's id.
String buildProvisionScript(NodeProvisionConfig c) {
  final psk = c.obfs4PskB64.trim();
  final sha = c.expectedSha256.trim().toLowerCase();
  final exitLine = c.runExit
      ? "sudo /usr/local/bin/veil-cli -c /tmp/node.toml config set proxy.exit.enabled true"
      : "# exit proxy disabled";
  return '''#!/usr/bin/env bash
set -euo pipefail

# 0. user + dirs
id veil >/dev/null 2>&1 || sudo useradd -r -s /usr/sbin/nologin -d /var/lib/veil veil
sudo mkdir -p /var/lib/veil /var/log/veil
sudo chown veil:veil /var/lib/veil /var/log/veil

# 1. veil-cli from the GitHub release — VERIFY checksum before trusting it
curl -fsSL '${c.releaseUrl}' -o /tmp/veil-cli
# Fail closed: if the downloaded binary does not match the published SHA-256,
# sha256sum -c exits non-zero and `set -e` aborts BEFORE we install/run it as
# root. This is what stops a tampered release / hijacked URL from becoming RCE.
echo '$sha  /tmp/veil-cli' | sha256sum -c -
sudo install -o root -g root -m 0755 /tmp/veil-cli /usr/local/bin/veil-cli

# 2. deployment obfs4 PSK
cat > /tmp/obfs4_psk.b64 <<'PSK_EOF'
$psk
PSK_EOF
sudo install -o veil -g veil -m 0600 /tmp/obfs4_psk.b64 /var/lib/veil/obfs4_psk.b64

# 3. systemd unit
cat > /tmp/veil.service <<'UNIT_EOF'
$_veilService
UNIT_EOF
sudo install -m 0644 /tmp/veil.service /etc/systemd/system/veil.service

# 4. config — mine an identity ONLY on first run (never rotate on re-provision)
if ! sudo test -f /var/lib/veil/node.toml || ! sudo grep -qE '^\\[Identity\\]' /var/lib/veil/node.toml; then
  sudo /usr/local/bin/veil-cli config init -d 24 -f /tmp/node.toml
  sudo /usr/local/bin/veil-cli -c /tmp/node.toml listen add 'obfs4-tcp://0.0.0.0:${c.listenPort}'
  $exitLine
  sudo install -o veil -g veil -m 0600 /tmp/node.toml /var/lib/veil/node.toml
fi
sudo /usr/local/bin/veil-cli --config /var/lib/veil/node.toml config validate

# 5. start
sudo systemctl daemon-reload
sudo systemctl enable veil >/dev/null 2>&1 || true
sudo systemctl restart veil

# 6. report status + node id (use this id as your routing exit)
sleep 2
echo "STATUS: \$(sudo systemctl is-active veil)"
echo -n "NODE_ID: "
sudo /usr/local/bin/veil-cli --config /var/lib/veil/node.toml node id 2>/dev/null || echo "(run 'veil-cli node id' to read it)"

# cleanup tmp
rm -f /tmp/veil-cli /tmp/obfs4_psk.b64 /tmp/veil.service /tmp/node.toml
''';
}
