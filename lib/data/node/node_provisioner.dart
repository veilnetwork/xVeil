import 'dart:io';

import 'managed_node.dart';

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

  static NodeComponent? fromBinaryName(String name) {
    for (final c in NodeComponent.values) {
      if (c.binaryName == name.trim()) return c;
    }
    return null;
  }
}

/// The machine-readable tail of a provisioning run — the last thing the script
/// prints, and the only channel through which a deployment tells the app what
/// it produced.
///
/// This exists because a successful deployment used to end at a snackbar: the
/// node was installed, running and reachable, and the app knew nothing about it
/// beyond an id it could not dial. Everything that should follow from a
/// deployment — the node joining the peer list, an oproxy exit joining the
/// proxy catalog — needs these three facts.
class ProvisionReport {
  const ProvisionReport({
    this.nodeId,
    this.invite,
    this.components = const <NodeComponent>{},
  });

  /// 64 hex chars, lowercased. Null when the node could not report one.
  final String? nodeId;

  /// The node's own bootstrap entry, already made routable where possible.
  /// Null when the script could not produce one — an older veil-cli, or a node
  /// with no listener.
  final String? invite;

  final Set<NodeComponent> components;

  bool get isEmpty => nodeId == null && invite == null && components.isEmpty;
}

const _unroutableHosts = {'0.0.0.0', '::', '127.0.0.1', 'localhost', '::1'};

/// Read what the deployment script reported.
///
/// [reachableHost] repairs the common case where the operator left the
/// advertise host empty: `listen add` then binds `0.0.0.0` and the node's own
/// invite carries `obfs4-tcp://0.0.0.0:5556`, which no peer can dial. The
/// address we just reached the machine on over SSH demonstrably works, so it is
/// substituted. A host the node advertised for itself is always left alone —
/// an operator who set an nginx-fronted name meant it.
ProvisionReport parseProvisionReport(String output, {String? reachableHost}) {
  String? nodeId;
  String? invite;
  var components = <NodeComponent>{};

  final id = RegExp(r'NODE_ID:\s*([0-9a-fA-F]{64})').firstMatch(output);
  if (id != null) nodeId = id.group(1)!.toLowerCase();

  final list = RegExp(r'COMPONENTS:\s*([a-z0-9,\-]+)').firstMatch(output);
  if (list != null) {
    components = list
        .group(1)!
        .split(',')
        .map(NodeComponentInfo.fromBinaryName)
        .whereType<NodeComponent>()
        .toSet();
  }

  final uri = RegExp(
    r'BOOTSTRAP_URI:\s*(veil:bootstrap\?\S+)',
  ).firstMatch(output);
  if (uri != null) {
    invite = _withReachableHost(uri.group(1)!.trim(), reachableHost);
  }
  return ProvisionReport(
    nodeId: nodeId,
    invite: invite,
    components: components,
  );
}

/// The node record to save after a read-only inventory run, or null to leave
/// the catalog untouched.
///
/// The inventory prints `NODE_ID: <64 hex>`, the app showed it and forgot it,
/// and the record kept displaying `—` — so the operator had to copy 64 hex
/// characters by hand into the field that decides what their traffic routes
/// through. Deployment persists the same value from the same line through the
/// same parser; only this path was missing.
///
/// Fills a blank and nothing else. An entry that already carries an id is
/// returned as null: adopting whatever a server currently answers would let a
/// host that was re-pointed, rebuilt or swapped silently take over an entry the
/// operator chose deliberately.
///
/// Pure, and it takes the output rather than running anything, so both the
/// "adopt" and the "leave alone" branches are reachable from a plain unit test.
ManagedNode? nodeWithAdoptedId(ManagedNode node, String inventoryOutput) {
  if (node.hasNodeId) return null;
  final id = parseProvisionReport(inventoryOutput).nodeId;
  if (id == null) return null;
  return node.copyWith(nodeId: id);
}

/// Rewrite the `t=` transport of an invite when it names an address that only
/// means something on the server itself.
String _withReachableHost(String invite, String? reachableHost) {
  final host = reachableHost?.trim();
  if (host == null || host.isEmpty) return invite;
  final marker = RegExp(r'(^|&)t=([^&]*)');
  final m = marker.firstMatch(invite);
  if (m == null) return invite;
  final transport = Uri.decodeComponent(m.group(2)!);
  final parsed = Uri.tryParse(transport);
  if (parsed == null ||
      !parsed.hasAuthority ||
      !_unroutableHosts.contains(parsed.host.toLowerCase())) {
    return invite;
  }
  final fixed = parsed.replace(host: host).toString();
  return invite.replaceRange(m.start, m.end, '${m.group(1)}t=$fixed');
}

/// Listener presets exposed by the basic UI. Operators can still edit the full
/// node TOML in Advanced settings; these cover the common public-server cases.
/// veil also implements `webtunnel-wss`, which is deliberately absent: it
/// refuses to start without `webtunnel_secret_path`, a shared secret file that
/// this script does not deploy, so offering it here would produce a node that
/// fails at startup for a reason the operator never saw.
enum NodeListenTransport { obfs4Tcp, tcp, tls, quic, ws, wss }

enum NodeTlsCertificateMode { existingFiles, automatic, selfSigned }

extension NodeListenTransportInfo on NodeListenTransport {
  String get scheme => switch (this) {
    NodeListenTransport.obfs4Tcp => 'obfs4-tcp',
    NodeListenTransport.tcp => 'tcp',
    NodeListenTransport.tls => 'tls',
    NodeListenTransport.quic => 'quic',
    NodeListenTransport.ws => 'ws',
    NodeListenTransport.wss => 'wss',
  };

  int get defaultPort => switch (this) {
    NodeListenTransport.obfs4Tcp => 5556,
    NodeListenTransport.tcp => 9000,
    NodeListenTransport.tls => 9443,
    NodeListenTransport.quic => 4433,
    NodeListenTransport.ws => 8080,
    NodeListenTransport.wss => 443,
  };

  bool get needsTls => switch (this) {
    NodeListenTransport.tls ||
    NodeListenTransport.quic ||
    NodeListenTransport.wss => true,
    _ => false,
  };
}

/// One release asset and the digest the deployment checks it against before the
/// remote server ever installs or executes it.
///
/// The digest is NOT an independent attestation, and saying so here mattered
/// more than anywhere else: this is the class that feeds a root install on
/// someone else's box. It comes from the SAME release as the binary — the
/// GitHub asset digest, or the release's own `sha256-<triple>.txt` — from the
/// same host, under the same tag. Whoever can publish or alter that release
/// publishes both. A comment here called it "independently-published", which
/// read like a second opinion and was not one (audit X-05; the twin on
/// `VeilGithubReleaseResolver` was corrected and this copy was missed).
///
/// What it does buy: the bytes that arrive are the bytes the release names, so
/// a substitution in transit or at a mirror is caught before the script installs
/// the file as root. What it does not buy: any statement about who published the
/// release. A signed manifest (TUF/Sigstore) is the fix for that, and it lives
/// in veil's release process rather than here.
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
    this.tlsCertificateMode = NodeTlsCertificateMode.existingFiles,
    this.tlsDomain,
    this.tlsEmail,
    this.tlsAgreeToTerms = false,
    this.selfSignedName,
    this.selfSignedDays = 365,
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

  /// How TLS material is supplied. Generated private keys never leave the
  /// managed server; listeners use root-owned, group-readable copies.
  final NodeTlsCertificateMode tlsCertificateMode;
  final String? tlsDomain;
  final String? tlsEmail;
  final bool tlsAgreeToTerms;
  final String? selfSignedName;
  final int selfSignedDays;

  static final _sha256Re = RegExp(r'^[0-9a-fA-F]{64}$');
  static final _safeUrlRe = RegExp(r'^https://[A-Za-z0-9._~:/?#@%=+,-]+$');
  static final _b64Re = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');
  static final _safeHostRe = RegExp(r'^[A-Za-z0-9.:[\]-]+$');
  static final _safePathRe = RegExp(r'^/[A-Za-z0-9._/-]+$');
  static final _safeEmailRe = RegExp(
    r'^[A-Za-z0-9._+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$',
  );
  static final _dnsNameRe = RegExp(
    r'^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
  );

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

  String? get effectiveTlsCertPath => switch (tlsCertificateMode) {
    NodeTlsCertificateMode.existingFiles => tlsCertPath?.trim(),
    NodeTlsCertificateMode.automatic =>
      automaticUsesLetsEncrypt
          ? '/etc/veil/tls/letsencrypt-fullchain.pem'
          : '/etc/veil/tls/selfsigned-cert.pem',
    NodeTlsCertificateMode.selfSigned => '/etc/veil/tls/selfsigned-cert.pem',
  };

  String? get effectiveTlsKeyPath => switch (tlsCertificateMode) {
    NodeTlsCertificateMode.existingFiles => tlsKeyPath?.trim(),
    NodeTlsCertificateMode.automatic =>
      automaticUsesLetsEncrypt
          ? '/etc/veil/tls/letsencrypt-privkey.pem'
          : '/etc/veil/tls/selfsigned-key.pem',
    NodeTlsCertificateMode.selfSigned => '/etc/veil/tls/selfsigned-key.pem',
  };

  String? get effectiveTlsCaCertPath =>
      tlsCertificateMode == NodeTlsCertificateMode.existingFiles
      ? tlsCaCertPath?.trim()
      : null;

  static bool isIpAddress(String value) =>
      InternetAddress.tryParse(value) != null;

  // A dotted IPv4 address also matches the syntactic DNS-label regexp. Check
  // IP first so automatic mode never attempts ACME for a numeric address.
  static bool isDnsName(String value) =>
      !isIpAddress(value) && _dnsNameRe.hasMatch(value);

  bool get automaticUsesLetsEncrypt =>
      tlsCertificateMode == NodeTlsCertificateMode.automatic &&
      isDnsName(tlsDomain?.trim() ?? '');

  String? get generatedCertificateName =>
      tlsCertificateMode == NodeTlsCertificateMode.automatic
      ? tlsDomain?.trim()
      : selfSignedName?.trim();

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
      switch (tlsCertificateMode) {
        case NodeTlsCertificateMode.existingFiles:
          final cert = tlsCertPath?.trim() ?? '';
          final key = tlsKeyPath?.trim() ?? '';
          if (!_safePathRe.hasMatch(cert) || !_safePathRe.hasMatch(key)) {
            return false;
          }
          final ca = tlsCaCertPath?.trim() ?? '';
          if (ca.isNotEmpty && !_safePathRe.hasMatch(ca)) return false;
          break;
        case NodeTlsCertificateMode.automatic:
          final name = tlsDomain?.trim() ?? '';
          if (!isDnsName(name) && !isIpAddress(name)) return false;
          if (isDnsName(name) &&
              (!_safeEmailRe.hasMatch(tlsEmail?.trim() ?? '') ||
                  !tlsAgreeToTerms)) {
            return false;
          }
          if (isIpAddress(name) &&
              (selfSignedDays < 1 || selfSignedDays > 3650)) {
            return false;
          }
          break;
        case NodeTlsCertificateMode.selfSigned:
          final name = selfSignedName?.trim() ?? '';
          if ((!isDnsName(name) && !isIpAddress(name)) ||
              selfSignedDays < 1 ||
              selfSignedDays > 3650) {
            return false;
          }
          break;
      }
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

// veil v0.3.1 intentionally exposes only a bounded subset of fields through
// `config set`. Deployment-only fields still need an idempotent TOML edit, but
// doing that with a section-aware helper avoids brittle line-number/sed edits
// and remains compatible with newer CLI releases.
const _tomlScalarHelper = r'''
set_toml_scalar() {
  local section="$1" key="$2" value="$3" file="$4"
  local temp="${file}.xveil.$$" owner group mode
  owner="$(sudo stat -c %u "$file")"
  group="$(sudo stat -c %g "$file")"
  mode="$(sudo stat -c %a "$file")"
  rm -f "$temp"
  sudo awk -v section="$section" -v key="$key" -v value="$value" '
    BEGIN { in_section = 0; section_seen = 0; key_written = 0 }
    $0 == "[" section "]" {
      in_section = 1
      section_seen = 1
      print
      next
    }
    /^\[/ {
      if (in_section && !key_written) {
        print key " = " value
        key_written = 1
      }
      in_section = 0
    }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      if (!key_written) print key " = " value
      key_written = 1
      next
    }
    { print }
    END {
      if (in_section && !key_written) print key " = " value
      if (!section_seen) {
        print ""
        print "[" section "]"
        print key " = " value
      }
    }
  ' "$file" > "$temp"
  sudo install -o "$owner" -g "$group" -m "$mode" "$temp" "$file"
  rm -f "$temp"
}
''';

String _downloadAndVerify(NodeReleaseArtifact a) {
  final temp = _artifactTempPath(a.component);
  // The staging path is DOUBLE-quoted: it contains `$XVEIL_TMP`, and a shell
  // does not expand a variable inside single quotes. Single-quoted, `curl -o`
  // wrote to a literal file called `$XVEIL_TMP/veil-cli` under whatever the
  // login cwd happened to be, which normally does not exist — so curl failed
  // and `set -e` aborted provisioning before the hash, the install, the config
  // and the service. The URL and the digest stay single-quoted: those are data
  // and must not be expanded at all.
  //
  // `printf` rather than `echo` for the digest line, so the two fields are
  // joined without a quoting seam.
  return '''curl -fsSL '${a.releaseUrl.trim()}' -o "$temp"
printf '%s  %s\\n' '${a.expectedSha256.trim().toLowerCase()}' "$temp" | sha256sum -c -''';
}

String _installArtifact(NodeReleaseArtifact a) {
  final binary = a.component.binaryName;
  final temp = _artifactTempPath(a.component);
  return 'sudo install -o root -g root -m 0755 "$temp" '
      "'/usr/local/bin/$binary'";
}

String _artifactTempPath(NodeComponent component) =>
    component == NodeComponent.veilCli
    ? '\$XVEIL_TMP/veil-cli'
    : '\$XVEIL_TMP/xveil-${component.binaryName}';

String _listenerCommand(NodeProvisionConfig c, NodeListenTransport t) {
  final port = c.portFor(t);
  final path = t == NodeListenTransport.wss ? '/veil' : '';
  final uri = '${t.scheme}://0.0.0.0:$port$path';
  final host = c.advertiseHost?.trim();
  final advertise = host == null || host.isEmpty
      ? ''
      : " --advertise '${t.scheme}://$host:$port$path'";
  final tls = t.needsTls
      ? " --tls-cert '${c.effectiveTlsCertPath}' --tls-key '${c.effectiveTlsKeyPath}'"
      : '';
  final ca =
      t.needsTls && (c.effectiveTlsCaCertPath?.trim().isNotEmpty ?? false)
      ? " --tls-ca-cert '${c.effectiveTlsCaCertPath}'"
      : '';
  return "sudo -u veil /usr/local/bin/veil-cli -c \$XVEIL_TMP/cfg/xveil-node.toml listen add '$uri'$advertise$tls$ca";
}

String _ensureServerCommand(String command, String package) =>
    '''
if ! command -v $command >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y $package
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y $package
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y $package
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add $package
  else
    echo 'Cannot install $package: unsupported package manager' >&2
    exit 1
  fi
fi''';

String _letsEncryptSetup(NodeProvisionConfig c, String domain) {
  final email = c.tlsEmail!.trim();
  return '''${_ensureServerCommand('certbot', 'certbot')}
sudo install -d -o root -g veil -m 0750 /etc/veil/tls

# The standalone ACME challenge needs inbound TCP/80. Restore an existing veil
# service if issuance fails instead of leaving a working node stopped.
veil_was_active=false
if sudo systemctl is-active --quiet veil.service; then
  veil_was_active=true
  sudo systemctl stop veil.service
fi
if ! sudo certbot certonly --standalone --non-interactive --agree-tos \\
    --no-eff-email --keep-until-expiring --email '$email' -d '$domain'; then
  if [ "\$veil_was_active" = true ]; then sudo systemctl start veil.service || true; fi
  echo "Let's Encrypt issuance failed. Check DNS and inbound TCP port 80." >&2
  exit 1
fi

# Certbot's source key stays root-only. The deploy hook updates a stable copy
# readable by the veil group after every automatic renewal.
cat > \$XVEIL_TMP/xveil-certbot-deploy-hook <<'HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail
install -d -o root -g veil -m 0750 /etc/veil/tls
install -o root -g veil -m 0644 '/etc/letsencrypt/live/$domain/fullchain.pem' '/etc/veil/tls/letsencrypt-fullchain.pem'
install -o root -g veil -m 0640 '/etc/letsencrypt/live/$domain/privkey.pem' '/etc/veil/tls/letsencrypt-privkey.pem'
systemctl try-restart veil.service || true
HOOK_EOF
sudo install -o root -g root -m 0755 \$XVEIL_TMP/xveil-certbot-deploy-hook \\
  /etc/letsencrypt/renewal-hooks/deploy/xveil-veil
sudo /etc/letsencrypt/renewal-hooks/deploy/xveil-veil
sudo systemctl enable --now certbot.timer >/dev/null 2>&1 || true
sudo -u veil test -r '${c.effectiveTlsCertPath}'
sudo -u veil test -r '${c.effectiveTlsKeyPath}'
''';
}

String _selfSignedSetup(NodeProvisionConfig c, String name) {
  final sanKind = NodeProvisionConfig.isIpAddress(name) ? 'IP.1' : 'DNS.1';
  final certificateSpec = '$name|${c.selfSignedDays}';
  return '''${_ensureServerCommand('openssl', 'openssl')}
sudo install -d -o root -g veil -m 0750 /etc/veil/tls
selfsigned_regenerate=false
if ! sudo test -s '${c.effectiveTlsCertPath}' || ! sudo test -s '${c.effectiveTlsKeyPath}'; then
  selfsigned_regenerate=true
elif [ "\$(sudo cat /etc/veil/tls/selfsigned-spec 2>/dev/null || true)" != '$certificateSpec' ]; then
  selfsigned_regenerate=true
elif ! sudo openssl x509 -checkend 86400 -noout -in '${c.effectiveTlsCertPath}' >/dev/null 2>&1; then
  selfsigned_regenerate=true
fi
if [ "\$selfsigned_regenerate" = true ]; then
    cat > \$XVEIL_TMP/xveil-openssl.cnf <<'OPENSSL_EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $name
[v3]
subjectAltName = @alt_names
[alt_names]
$sanKind = $name
OPENSSL_EOF
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 \\
    -days ${c.selfSignedDays} -config \$XVEIL_TMP/xveil-openssl.cnf \\
    -keyout \$XVEIL_TMP/xveil-selfsigned-key.pem \\
    -out \$XVEIL_TMP/xveil-selfsigned-cert.pem
  printf '%s' '$certificateSpec' > \$XVEIL_TMP/xveil-selfsigned-spec
  sudo install -o root -g veil -m 0644 \$XVEIL_TMP/xveil-selfsigned-cert.pem '${c.effectiveTlsCertPath}'
  sudo install -o root -g veil -m 0640 \$XVEIL_TMP/xveil-selfsigned-key.pem '${c.effectiveTlsKeyPath}'
  sudo install -o root -g veil -m 0644 \$XVEIL_TMP/xveil-selfsigned-spec /etc/veil/tls/selfsigned-spec
fi
sudo -u veil test -r '${c.effectiveTlsCertPath}'
sudo -u veil test -r '${c.effectiveTlsKeyPath}'
''';
}

String _tlsCertificateSetup(NodeProvisionConfig c) {
  if (!c.usesTls) return '# TLS is not selected';
  switch (c.tlsCertificateMode) {
    case NodeTlsCertificateMode.existingFiles:
      final ca = c.effectiveTlsCaCertPath;
      final caCheck = ca?.isNotEmpty ?? false
          ? "\nsudo -u veil test -r '$ca'"
          : '';
      return '''# Verify the unprivileged veil service can read supplied files.
sudo -u veil test -r '${c.effectiveTlsCertPath}'
sudo -u veil test -r '${c.effectiveTlsKeyPath}'$caCheck''';
    case NodeTlsCertificateMode.automatic:
      final name = c.generatedCertificateName!;
      return c.automaticUsesLetsEncrypt
          ? _letsEncryptSetup(c, name)
          : _selfSignedSetup(c, name);
    case NodeTlsCertificateMode.selfSigned:
      return _selfSignedSetup(c, c.generatedCertificateName!);
  }
}

String _optionalComponentSetup(Set<NodeComponent> components) {
  final out = StringBuffer();
  if (components.contains(NodeComponent.ogate)) {
    out.writeln("sudo mkdir -p /etc/ogate");
    out.writeln(
      '''if ! sudo test -f /etc/ogate/ogate.toml; then
  sudo -u veil /usr/local/bin/ogate gen-config -o \$XVEIL_TMP/cfg/xveil-ogate.toml
  sudo install -o veil -g veil -m 0640 \$XVEIL_TMP/cfg/xveil-ogate.toml /etc/ogate/ogate.toml
fi
cat > \$XVEIL_TMP/xveil-ogate.service <<'UNIT_EOF'
$_ogateService
UNIT_EOF
sudo install -m 0644 \$XVEIL_TMP/xveil-ogate.service /etc/systemd/system/ogate.service''',
    );
  }
  if (components.contains(NodeComponent.oproxyClient)) {
    out.writeln(
      '''sudo mkdir -p /etc/oproxy
if ! sudo test -f /etc/oproxy/client.toml; then
  sudo -u veil /usr/local/bin/oproxy-client --gen-config > \$XVEIL_TMP/xveil-oproxy-client.toml
  sudo install -o veil -g veil -m 0640 \$XVEIL_TMP/xveil-oproxy-client.toml /etc/oproxy/client.toml
fi
cat > \$XVEIL_TMP/xveil-oproxy-client.service <<'UNIT_EOF'
$_oproxyClientService
UNIT_EOF
sudo install -m 0644 \$XVEIL_TMP/xveil-oproxy-client.service /etc/systemd/system/oproxy-client.service''',
    );
  }
  if (components.contains(NodeComponent.oproxyServer)) {
    out.writeln(
      '''sudo mkdir -p /etc/oproxy
if ! sudo test -f /etc/oproxy/server.toml; then
  sudo -u veil /usr/local/bin/oproxy-server --gen-config > \$XVEIL_TMP/xveil-oproxy-server.toml
  sudo install -o veil -g veil -m 0640 \$XVEIL_TMP/xveil-oproxy-server.toml /etc/oproxy/server.toml
fi
cat > \$XVEIL_TMP/xveil-oproxy-server.service <<'UNIT_EOF'
$_oproxyServerService
UNIT_EOF
sudo install -m 0644 \$XVEIL_TMP/xveil-oproxy-server.service /etc/systemd/system/oproxy-server.service''',
    );
  }
  return out.toString();
}

/// Build an idempotent Linux/systemd deployment. Existing node identity is
/// preserved while listeners and operational settings are reconciled to the
/// selected plan on every run.
/// Refuses a config [NodeProvisionConfig.isValid] rejects.
///
/// This function's output is executed AS ROOT on the operator's server, and it
/// interpolates operator-supplied values — the advertise host, TLS paths, an
/// ACME e-mail, a certificate name — into single-quoted shell words. A value
/// carrying an apostrophe closes that word and everything after it is a new
/// command: `--advertise 'obfs4-tcp://x'; touch /tmp/pwned; echo ':5556'` is
/// what the generator produced for such a host.
///
/// Every one of those fields IS validated — `isValid` checks the host against
/// a host pattern, the paths against a path pattern, the e-mail, the domain,
/// the ports and each artifact's URL and digest. The check simply lived one
/// layer away: the deploy screen consulted it and this function did not, so
/// the guarantee held only for as long as the single existing caller kept
/// asking. A second caller — another screen, a headless path, a helper that
/// graduates into production — got a root shell script built out of whatever
/// it passed.
///
/// So the refusal belongs at the boundary that runs as root rather than at the
/// screen in front of it, which is also what `buildWriteNodeConfigScript` does
/// with its size limit.
String buildProvisionScript(NodeProvisionConfig c) {
  if (!c.isValid) {
    throw ArgumentError(
      'refusing to build a root-privileged script from a config that '
      'NodeProvisionConfig.isValid rejects',
    );
  }
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
  final tlsSetup = _tlsCertificateSetup(c);

  return '''#!/usr/bin/env bash
set -euo pipefail

# Private scratch directory, owner-only, removed on EVERY exit path.
#
# This script writes the deployment obfs4 PSK, the systemd unit, a TLS private
# key and the node's own config, and then hands each to `sudo install`. Those
# staging files used to live at fixed /tmp/xveil-* names under the login
# umask, which on a shared server is three separate problems: another local
# account could read the PSK and the TLS key in the window before install
# moved them; it could pre-create or symlink any of those names and have a
# root-privileged install follow it; and cleanup only ran on the success path,
# so a failed run left the secrets sitting there.
#
# `umask 077` covers the files, `mktemp -d` makes the name unguessable and the
# directory owner-only, and the trap fires on error and signal as well as on
# success.
umask 077
XVEIL_TMP="\$(mktemp -d)" || { echo 'cannot create a private temp dir' >&2; exit 1; }
trap 'rm -rf -- "\$XVEIL_TMP"' EXIT INT TERM

$_tomlScalarHelper

# 0. dedicated account + state directories
id veil >/dev/null 2>&1 || sudo useradd -r -s /usr/sbin/nologin -d /var/lib/veil veil
sudo mkdir -p /var/lib/veil /var/log/veil
sudo chown veil:veil /var/lib/veil /var/log/veil

# 0b. one writable corner for `veil`, and nothing more.
#
# `mktemp -d` above makes the staging directory 0700 root:root, which is right
# for the secrets in it and wrong for the config steps below: those run through
# `sudo -u veil`, and that account has to reach its config AND create files
# beside it (`config get/set` rewrites atomically — a temp file plus a rename,
# which needs the DIRECTORY). Locked out entirely, `veil-cli` cannot tell "not
# there" from "not allowed to look" and reports the staged config as MISSING,
# so a deployment failed after installing the binaries and left the server
# with no running node.
#
# Split rather than opened: the staging root becomes traversable-but-not-
# listable and stays unwritable, and one sub-directory is handed to the `veil`
# GROUP. The deployment PSK, the TLS private key and the unit files stay in
# the root-only part, where a compromised `veil` cannot read them and — the
# reason for the split rather than a 0770 on the whole thing — cannot unlink
# and REPLACE them in the window before root installs them. Same posture, and
# the same reasoning, as the remote config editor in `node_lifecycle.dart`.
#
# After the account exists, which is why this is here and not beside `mktemp`.
sudo chmod 711 "\$XVEIL_TMP"
sudo mkdir -p "\$XVEIL_TMP/cfg"
sudo chown root:veil "\$XVEIL_TMP/cfg"
sudo chmod 0770 "\$XVEIL_TMP/cfg"

# 1. download and authenticate EVERY selected release asset first
$downloads

# 2. only verified programs are installed
$installs

# 3. deployment obfs4 PSK
cat > \$XVEIL_TMP/xveil-obfs4-psk.b64 <<'PSK_EOF'
${c.obfs4PskB64.trim()}
PSK_EOF
sudo install -o veil -g veil -m 0600 \$XVEIL_TMP/xveil-obfs4-psk.b64 /var/lib/veil/obfs4_psk.b64

# 4. veil service + stable local IPC used by ogate/oproxy
cat > \$XVEIL_TMP/xveil-veil.service <<'UNIT_EOF'
$_veilService
UNIT_EOF
sudo install -m 0644 \$XVEIL_TMP/xveil-veil.service /etc/systemd/system/veil.service

# 5. prepare TLS material before changing any listener configuration
$tlsSetup

# 6. preserve identity, but reconcile listeners and service configuration
#
# BOTH spellings, and whitespace-tolerant. veil renames the section to
# `Identity`, but it also ACCEPTS and deliberately preserves a lowercase
# `[identity]` — `veil-cfg` has a test named for exactly that, promising such a
# document never gains an uppercase duplicate. A guard that only knew the
# uppercase form read a perfectly good config as "no identity here" and took
# the branch below, which MINTS A NEW ONE: an update would have replaced the
# node's id and every relationship hanging off it, silently, on a server the
# operator asked to update.
#
# Erring toward "identity present" is the safe direction: a file that has none
# then fails loudly on the next veil-cli call instead of being overwritten.
if ! sudo test -f /var/lib/veil/node.toml || ! sudo grep -qE '^[[:space:]]*\\[[[:space:]]*[Ii]dentity[[:space:]]*\\]' /var/lib/veil/node.toml; then
  sudo -u veil /usr/local/bin/veil-cli config init -d 24 -f \$XVEIL_TMP/cfg/xveil-node.toml
else
  sudo install -o veil -g veil -m 0600 /var/lib/veil/node.toml \$XVEIL_TMP/cfg/xveil-node.toml
fi
# `listen list` prints ids in hex — `0x00000001`, not `1` — so a decimal-only
# filter matches nothing and this loop deletes nothing. Redeploying a server
# then APPENDS listeners instead of reconciling them: a second run leaves two
# obfs4 listeners on the same port, and any listener from an earlier
# deployment (a plain `tcp://0.0.0.0:9000` from the old default) survives
# every subsequent run despite this step existing to remove exactly that.
while read -r listen_id; do
  sudo -u veil /usr/local/bin/veil-cli -c \$XVEIL_TMP/cfg/xveil-node.toml listen del "\$listen_id"
done < <(sudo -u veil /usr/local/bin/veil-cli -c \$XVEIL_TMP/cfg/xveil-node.toml listen list | awk 'NR > 1 && \$1 ~ /^0x[0-9a-fA-F]+\$/ {print \$1}')
$listeners
set_toml_scalar transport obfs4_psk_file '"/var/lib/veil/obfs4_psk.b64"' \$XVEIL_TMP/cfg/xveil-node.toml
sudo -u veil /usr/local/bin/veil-cli -c \$XVEIL_TMP/cfg/xveil-node.toml config set ipc.enabled true
sudo -u veil /usr/local/bin/veil-cli -c \$XVEIL_TMP/cfg/xveil-node.toml config set ipc.socket_uri unix:///run/veil/app.sock
$exitComment
set_toml_scalar proxy.exit enabled '$exitValue' \$XVEIL_TMP/cfg/xveil-node.toml
sudo -u veil /usr/local/bin/veil-cli -c \$XVEIL_TMP/cfg/xveil-node.toml config validate
sudo install -o veil -g veil -m 0600 \$XVEIL_TMP/cfg/xveil-node.toml /var/lib/veil/node.toml

# 7. optional applications: install complete templates + units, but do not
# enable them until the operator replaces their fail-closed placeholders.
${_optionalComponentSetup(components)}

# 8. start the node. Optional services stay disabled until configured.
sudo systemctl daemon-reload
sudo systemctl enable veil >/dev/null 2>&1 || true
sudo systemctl restart veil

# 9. report machine-readable facts back to xVeil
veil_status='activating'
for _ in {1..30}; do
  veil_status="\$(sudo systemctl is-active veil 2>/dev/null || true)"
  if [ "\$veil_status" = active ]; then break; fi
  if [ "\$veil_status" = failed ] || [ "\$veil_status" = inactive ]; then break; fi
  sleep 1
done
echo "STATUS: \$veil_status"
if [ "\$veil_status" != active ]; then
  sudo systemctl --no-pager --full status veil >&2 || true
  exit 1
fi
echo -n "NODE_ID: "
sudo -u veil /usr/local/bin/veil-cli --config /var/lib/veil/node.toml config get identity.node_id 2>/dev/null || \\
  sudo -u veil /usr/local/bin/veil-cli --config /var/lib/veil/node.toml node id 2>/dev/null || \\
  echo "(unavailable)"
echo "COMPONENTS: ${components.map((c) => c.binaryName).join(',')}"
# The node's own bootstrap entry. A node id alone cannot be dialled: reaching a
# peer needs transport + public_key + nonce, which is exactly what this URI
# carries. Without it the app had no way to turn a freshly deployed server into
# a peer, so deployment succeeded and the node stayed invisible.
echo -n "BOOTSTRAP_URI: "
sudo -u veil /usr/local/bin/veil-cli --config /var/lib/veil/node.toml bootstrap invite 2>/dev/null \\
  | head -1 || echo "(unavailable)"

rm -f $cleanup \$XVEIL_TMP/xveil-obfs4-psk.b64 \$XVEIL_TMP/xveil-veil.service \\
  \$XVEIL_TMP/xveil-ogate.service \$XVEIL_TMP/xveil-oproxy-client.service \\
  \$XVEIL_TMP/xveil-oproxy-server.service \$XVEIL_TMP/cfg/xveil-ogate.toml \\
  \$XVEIL_TMP/xveil-oproxy-client.toml \$XVEIL_TMP/xveil-oproxy-server.toml \\
  \$XVEIL_TMP/cfg/xveil-node.toml \$XVEIL_TMP/xveil-certbot-deploy-hook \\
  \$XVEIL_TMP/xveil-openssl.cnf \$XVEIL_TMP/xveil-selfsigned-cert.pem \\
  \$XVEIL_TMP/xveil-selfsigned-key.pem \$XVEIL_TMP/xveil-selfsigned-spec
''';
}
