/// Components that can be installed on a managed server. `veilCli` is always
/// required; the others are optional applications that attach to its local IPC
/// socket.
enum NodeComponent { veilCli, ogate, oproxyClient, oproxyServer }

extension NodeComponentInfo on NodeComponent {
  String get binaryName => switch (this) {
    NodeComponent.veilCli => 'veil-cli',
    NodeComponent.ogate => 'ogate',
    NodeComponent.oproxyClient => 'oproxy-client',
    NodeComponent.oproxyServer => 'oproxy-server',
  };
}

/// Listener presets exposed by the basic UI. Operators can still edit the full
/// node TOML in Advanced settings; these cover the common public-server cases.
enum NodeListenTransport { obfs4Tcp, tcp, tls, quic, wss }

extension NodeListenTransportInfo on NodeListenTransport {
  String get scheme => switch (this) {
    NodeListenTransport.obfs4Tcp => 'obfs4-tcp',
    NodeListenTransport.tcp => 'tcp',
    NodeListenTransport.tls => 'tls',
    NodeListenTransport.quic => 'quic',
    NodeListenTransport.wss => 'wss',
  };

  int get defaultPort => switch (this) {
    NodeListenTransport.obfs4Tcp => 5556,
    NodeListenTransport.tcp => 9000,
    NodeListenTransport.tls => 9443,
    NodeListenTransport.quic => 4433,
    NodeListenTransport.wss => 443,
  };

  bool get needsTls => switch (this) {
    NodeListenTransport.tls ||
    NodeListenTransport.quic ||
    NodeListenTransport.wss => true,
    _ => false,
  };
}

/// One release asset and the independently-published digest that authenticates
/// it before the remote server ever installs or executes it.
class NodeReleaseArtifact {
  const NodeReleaseArtifact({
    required this.component,
    required this.releaseUrl,
    required this.expectedSha256,
  });

  final NodeComponent component;
  final String releaseUrl;
  final String expectedSha256;

  bool get isValid =>
      NodeProvisionConfig.isSafeHttpsUrl(releaseUrl.trim()) &&
      NodeProvisionConfig.isSha256(expectedSha256.trim());
}

/// Generates the reviewed bash deployment used by “My nodes”. Every binary is
/// downloaded and SHA-256 checked before *any* install step. This makes a plan
/// atomic with respect to authenticity: a bad optional oproxy asset cannot
/// leave a freshly-downloaded, unverified program on PATH.
class NodeProvisionConfig {
  const NodeProvisionConfig({
    required this.releaseUrl,
    required this.expectedSha256,
    required this.obfs4PskB64,
    this.listenPort = 5556,
    this.runExit = true,
    this.extraArtifacts = const [],
    this.transports = const {NodeListenTransport.obfs4Tcp},
    this.transportPorts = const {},
    this.advertiseHost,
    this.tlsCertPath,
    this.tlsKeyPath,
    this.tlsCaCertPath,
  });

  /// Backward-compatible veil-cli asset fields.
  final String releaseUrl;
  final String expectedSha256;
  final String obfs4PskB64;

  /// Backward-compatible obfs4 port; [transportPorts] can override every
  /// transport (including obfs4) in the expanded deployment UI.
  final int listenPort;
  final bool runExit;

  final List<NodeReleaseArtifact> extraArtifacts;
  final Set<NodeListenTransport> transports;
  final Map<NodeListenTransport, int> transportPorts;

  /// Optional public DNS name/IP used in `listen add --advertise`; listeners
  /// still bind `0.0.0.0`. Empty means veil's own address discovery decides.
  final String? advertiseHost;

  /// Existing remote certificate files for TLS/QUIC/WSS listeners. The deployer
  /// never uploads private-key material from the phone and never invents a
  /// self-signed certificate behind the operator's back.
  final String? tlsCertPath;
  final String? tlsKeyPath;
  final String? tlsCaCertPath;

  static final _sha256Re = RegExp(r'^[0-9a-fA-F]{64}$');
  static final _safeUrlRe = RegExp(r'^https://[A-Za-z0-9._~:/?#@%=+,-]+$');
  static final _b64Re = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
  static final _safeHostRe = RegExp(r'^[A-Za-z0-9.:[\]-]+$');
  static final _safePathRe = RegExp(r'^/[A-Za-z0-9._/-]+$');

  static bool isSafeHttpsUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null &&
        u.scheme == 'https' &&
        u.host.isNotEmpty &&
        _safeUrlRe.hasMatch(s);
  }

  static bool isSha256(String s) => _sha256Re.hasMatch(s);

  static bool _isBase64(String s) =>
      s.isNotEmpty && s.length % 4 == 0 && _b64Re.hasMatch(s);

  int portFor(NodeListenTransport transport) =>
      transportPorts[transport] ??
      (transport == NodeListenTransport.obfs4Tcp
          ? listenPort
          : transport.defaultPort);

  List<NodeReleaseArtifact> get artifacts => [
    NodeReleaseArtifact(
      component: NodeComponent.veilCli,
      releaseUrl: releaseUrl,
      expectedSha256: expectedSha256,
    ),
    ...extraArtifacts,
  ];

  bool get usesTls => transports.any((t) => t.needsTls);

  bool get isValid {
    if (transports.isEmpty || !_isBase64(obfs4PskB64.trim())) return false;
    if (!artifacts.every((a) => a.isValid)) return false;
    if (artifacts.map((a) => a.component).toSet().length != artifacts.length) {
      return false;
    }
    if (transports.any((t) {
      final port = portFor(t);
      return port < 1 || port > 65535;
    })) {
      return false;
    }
    final host = advertiseHost?.trim();
    if (host != null && host.isNotEmpty && !_safeHostRe.hasMatch(host)) {
      return false;
    }
    if (usesTls) {
      final cert = tlsCertPath?.trim() ?? '';
      final key = tlsKeyPath?.trim() ?? '';
      if (!_safePathRe.hasMatch(cert) || !_safePathRe.hasMatch(key)) {
        return false;
      }
      final ca = tlsCaCertPath?.trim() ?? '';
      if (ca.isNotEmpty && !_safePathRe.hasMatch(ca)) return false;
    }
    return true;
  }
}

const _veilService = '''[Unit]
Description=Veil node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=veil
Group=veil
RuntimeDirectory=veil
RuntimeDirectoryMode=0750
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
ReadWritePaths=/var/lib/veil /var/log/veil /run/veil
ProtectHome=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target''';

const _ogateService = '''[Unit]
Description=Veil ogate TUN bridge
After=veil.service
Requires=veil.service

[Service]
Type=simple
User=veil
Group=veil
ExecStart=/usr/local/bin/ogate up --config /etc/ogate/ogate.toml
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN
NoNewPrivileges=true
Restart=on-failure
RestartSec=5
ProtectSystem=strict
ReadWritePaths=/run/veil
ProtectHome=true

[Install]
WantedBy=multi-user.target''';

const _oproxyClientService = '''[Unit]
Description=Veil oproxy client
After=veil.service
Requires=veil.service

[Service]
Type=simple
User=veil
Group=veil
ExecStart=/usr/local/bin/oproxy-client --config /etc/oproxy/client.toml
NoNewPrivileges=true
Restart=on-failure
RestartSec=5
ProtectSystem=strict
ReadWritePaths=/run/veil
ProtectHome=true

[Install]
WantedBy=multi-user.target''';

const _oproxyServerService = '''[Unit]
Description=Veil oproxy exit server
After=veil.service
Requires=veil.service

[Service]
Type=simple
User=veil
Group=veil
ExecStart=/usr/local/bin/oproxy-server --config /etc/oproxy/server.toml
NoNewPrivileges=true
Restart=on-failure
RestartSec=5
ProtectSystem=strict
ReadWritePaths=/run/veil
ProtectHome=true

[Install]
WantedBy=multi-user.target''';

String _downloadAndVerify(NodeReleaseArtifact a) {
  final temp = _artifactTempPath(a.component);
  return '''curl -fsSL '${a.releaseUrl.trim()}' -o '$temp'
echo '${a.expectedSha256.trim().toLowerCase()}  $temp' | sha256sum -c -''';
}

String _installArtifact(NodeReleaseArtifact a) {
  final binary = a.component.binaryName;
  final temp = _artifactTempPath(a.component);
  return "sudo install -o root -g root -m 0755 '$temp' '/usr/local/bin/$binary'";
}

String _artifactTempPath(NodeComponent component) =>
    component == NodeComponent.veilCli
    ? '/tmp/veil-cli'
    : '/tmp/xveil-${component.binaryName}';

String _listenerCommand(NodeProvisionConfig c, NodeListenTransport t) {
  final port = c.portFor(t);
  final path = t == NodeListenTransport.wss ? '/veil' : '';
  final uri = '${t.scheme}://0.0.0.0:$port$path';
  final host = c.advertiseHost?.trim();
  final advertise = host == null || host.isEmpty
      ? ''
      : " --advertise '${t.scheme}://$host:$port$path'";
  final tls = t.needsTls
      ? " --tls-cert '${c.tlsCertPath!.trim()}' --tls-key '${c.tlsKeyPath!.trim()}'"
      : '';
  final ca = t.needsTls && (c.tlsCaCertPath?.trim().isNotEmpty ?? false)
      ? " --tls-ca-cert '${c.tlsCaCertPath!.trim()}'"
      : '';
  return "sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml listen add '$uri'$advertise$tls$ca";
}

String _optionalComponentSetup(Set<NodeComponent> components) {
  final out = StringBuffer();
  if (components.contains(NodeComponent.ogate)) {
    out.writeln("sudo mkdir -p /etc/ogate");
    out.writeln(
      '''if ! sudo test -f /etc/ogate/ogate.toml; then
  sudo -u veil /usr/local/bin/ogate gen-config -o /tmp/xveil-ogate.toml
  sudo install -o veil -g veil -m 0640 /tmp/xveil-ogate.toml /etc/ogate/ogate.toml
fi
cat > /tmp/xveil-ogate.service <<'UNIT_EOF'
$_ogateService
UNIT_EOF
sudo install -m 0644 /tmp/xveil-ogate.service /etc/systemd/system/ogate.service''',
    );
  }
  if (components.contains(NodeComponent.oproxyClient)) {
    out.writeln(
      '''sudo mkdir -p /etc/oproxy
if ! sudo test -f /etc/oproxy/client.toml; then
  sudo -u veil /usr/local/bin/oproxy-client --gen-config > /tmp/xveil-oproxy-client.toml
  sudo install -o veil -g veil -m 0640 /tmp/xveil-oproxy-client.toml /etc/oproxy/client.toml
fi
cat > /tmp/xveil-oproxy-client.service <<'UNIT_EOF'
$_oproxyClientService
UNIT_EOF
sudo install -m 0644 /tmp/xveil-oproxy-client.service /etc/systemd/system/oproxy-client.service''',
    );
  }
  if (components.contains(NodeComponent.oproxyServer)) {
    out.writeln(
      '''sudo mkdir -p /etc/oproxy
if ! sudo test -f /etc/oproxy/server.toml; then
  sudo -u veil /usr/local/bin/oproxy-server --gen-config > /tmp/xveil-oproxy-server.toml
  sudo install -o veil -g veil -m 0640 /tmp/xveil-oproxy-server.toml /etc/oproxy/server.toml
fi
cat > /tmp/xveil-oproxy-server.service <<'UNIT_EOF'
$_oproxyServerService
UNIT_EOF
sudo install -m 0644 /tmp/xveil-oproxy-server.service /etc/systemd/system/oproxy-server.service''',
    );
  }
  return out.toString();
}

/// Build an idempotent Linux/systemd deployment. Existing node identity is
/// preserved while listeners and operational settings are reconciled to the
/// selected plan on every run.
String buildProvisionScript(NodeProvisionConfig c) {
  final artifacts = c.artifacts;
  final components = artifacts.map((a) => a.component).toSet();
  final downloads = artifacts.map(_downloadAndVerify).join('\n');
  final installs = artifacts.map(_installArtifact).join('\n');
  final listeners = c.transports.map((t) => _listenerCommand(c, t)).join('\n');
  final exitValue = c.runExit ? 'true' : 'false';
  final exitComment = c.runExit
      ? '# built-in exit proxy enabled'
      : '# exit proxy disabled';
  final cleanup = artifacts
      .map((a) => _artifactTempPath(a.component))
      .join(' ');

  return '''#!/usr/bin/env bash
set -euo pipefail

# 0. dedicated account + state directories
id veil >/dev/null 2>&1 || sudo useradd -r -s /usr/sbin/nologin -d /var/lib/veil veil
sudo mkdir -p /var/lib/veil /var/log/veil
sudo chown veil:veil /var/lib/veil /var/log/veil

# 1. download and authenticate EVERY selected release asset first
$downloads

# 2. only verified programs are installed
$installs

# 3. deployment obfs4 PSK
cat > /tmp/xveil-obfs4-psk.b64 <<'PSK_EOF'
${c.obfs4PskB64.trim()}
PSK_EOF
sudo install -o veil -g veil -m 0600 /tmp/xveil-obfs4-psk.b64 /var/lib/veil/obfs4_psk.b64

# 4. veil service + stable local IPC used by ogate/oproxy
cat > /tmp/xveil-veil.service <<'UNIT_EOF'
$_veilService
UNIT_EOF
sudo install -m 0644 /tmp/xveil-veil.service /etc/systemd/system/veil.service

# 5. preserve identity, but reconcile listeners and service configuration
if ! sudo test -f /var/lib/veil/node.toml || ! sudo grep -qE '^\\[Identity\\]' /var/lib/veil/node.toml; then
  sudo -u veil /usr/local/bin/veil-cli config init -d 24 -f /tmp/xveil-node.toml
else
  sudo install -o veil -g veil -m 0600 /var/lib/veil/node.toml /tmp/xveil-node.toml
fi
while read -r listen_id; do
  sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml listen del "\$listen_id"
done < <(sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml listen list | awk 'NR > 1 && \$1 ~ /^[0-9]+\$/ {print \$1}')
$listeners
sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml config set transport.obfs4_psk_file /var/lib/veil/obfs4_psk.b64
sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml config set ipc.enabled true
sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml config set ipc.socket_uri unix:///run/veil/app.sock
$exitComment
sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml config set proxy.exit.enabled $exitValue
sudo -u veil /usr/local/bin/veil-cli -c /tmp/xveil-node.toml config validate
sudo install -o veil -g veil -m 0600 /tmp/xveil-node.toml /var/lib/veil/node.toml

# 6. optional applications: install complete templates + units, but do not
# enable them until the operator replaces their fail-closed placeholders.
${_optionalComponentSetup(components)}

# 7. start the node. Optional services stay disabled until configured.
sudo systemctl daemon-reload
sudo systemctl enable veil >/dev/null 2>&1 || true
sudo systemctl restart veil

# 8. report machine-readable facts back to xVeil
sleep 2
echo "STATUS: \$(sudo systemctl is-active veil)"
echo -n "NODE_ID: "
sudo -u veil /usr/local/bin/veil-cli --config /var/lib/veil/node.toml node id 2>/dev/null || echo "(unavailable)"
echo "COMPONENTS: ${components.map((c) => c.binaryName).join(',')}"

rm -f $cleanup /tmp/xveil-obfs4-psk.b64 /tmp/xveil-veil.service \\
  /tmp/xveil-ogate.service /tmp/xveil-oproxy-client.service \\
  /tmp/xveil-oproxy-server.service /tmp/xveil-ogate.toml \\
  /tmp/xveil-oproxy-client.toml /tmp/xveil-oproxy-server.toml \\
  /tmp/xveil-node.toml
''';
}
