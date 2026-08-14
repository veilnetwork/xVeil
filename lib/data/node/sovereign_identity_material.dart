import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xveil/core/posix_file_facts.dart' show posixChmod;

/// The per-device sovereign identity material: what `identity restore` writes
/// into a node directory, and what has to survive a restart.
///
/// WHY THIS IS PERSISTED AT ALL.
///
/// The node reads its identity from `veil_dir`. Ours is the RUNTIME directory
/// — created fresh under a random name on every boot and deleted on the way
/// down, because it holds sockets and other identity-free ephemera. Anything
/// written there is gone by the next launch. The identity document and the
/// device key are the opposite of ephemeral: the document is published under
/// this identity's `node_id` and names this device's key, so re-minting it
/// each boot would orphan every peer's copy and change the device's
/// `instance_id` under it.
///
/// So the material is provisioned ONCE, stored in the deniable container
/// alongside the node config (same settings namespace, same deniability — the
/// device key is secret exactly like the routing key already there), and
/// materialised into the runtime directory before each boot.
///
/// WHY THE NODE NEEDS IT. Without `identity_document.bin` the runtime builds a
/// DEGENERATE document in which master == device: `node_id == device_id`. That
/// is correct for one device and fatal for two — restoring the same phrase on
/// a second device produces the same node, not a second device of one
/// identity, which is why linking answers "self device".

/// The document that names this identity and its device keys. Public.
const kIdentityDocumentFile = 'identity_document.bin';

/// This device's own signing key under the master. SECRET — a 32-byte seed.
const kDeviceIdentitySkFile = 'device_identity_sk.bin';

/// This device's stable instance id.
const kInstanceIdFile = 'instance_id';

/// Which of the document's device keys is ours. Absent while this device is
/// the only one (index 0 is the default); written once a delegation adds
/// another device ahead of, or alongside, this one.
const kDeviceSigKeyIdxFile = 'device_sig_key_idx.bin';

/// Everything a provisioned device directory may contain, in the order the
/// files are written back out.
const kSovereignIdentityFiles = <String>[
  kIdentityDocumentFile,
  kDeviceIdentitySkFile,
  kInstanceIdFile,
  kDeviceSigKeyIdxFile,
];

/// Without these three the node cannot load a sovereign identity and falls
/// back to the degenerate document — silently, which is the failure this
/// whole mechanism exists to prevent.
const kRequiredSovereignIdentityFiles = <String>[
  kIdentityDocumentFile,
  kDeviceIdentitySkFile,
  kInstanceIdFile,
];

/// The master signing key, base64, kept apart from the node config.
///
/// Today the config carries it: a phrase-provisioned config key IS the master.
/// That stops being true the moment a device gets a transport key of its own,
/// and admitting a further device still needs the master — days later, from a
/// Devices screen, with the phrase long gone. Storing it here changes no
/// exposure: the same 32 bytes already live in the same container, inside the
/// config, and the container is what protects them either way.
const kMasterKeySetting = 'node.master_key.v1';

/// Container key. Versioned: a later layout change must not be read as a
/// corrupt copy of this one.
const kSovereignIdentitySetting = 'node.sovereign_identity.v1';

/// The names required but not present in [files].
///
/// Pure, so the "is this material usable" decision is testable without a
/// filesystem — and so the boot can state WHICH file is missing instead of
/// falling back to a degenerate identity without saying why.
List<String> missingSovereignIdentityFiles(Map<String, Uint8List> files) => [
  for (final name in kRequiredSovereignIdentityFiles)
    if (!files.containsKey(name) || files[name]!.isEmpty) name,
];

/// Encode for the container: a JSON object of name → base64.
///
/// Deliberately not a tar or a concatenation with lengths — the set is four
/// small files, and a self-describing map is what lets an added file be read
/// by an older build (it ignores names it does not know) instead of shifting
/// every offset after it.
String encodeSovereignIdentity(Map<String, Uint8List> files) {
  final sorted = files.keys.toList()..sort();
  return jsonEncode({for (final k in sorted) k: base64.encode(files[k]!)});
}

/// Inverse of [encodeSovereignIdentity]. Returns null when the stored value is
/// not a map of base64 strings — a corrupt entry must not be handed to the
/// node as a half-populated directory.
Map<String, Uint8List>? decodeSovereignIdentity(String encoded) {
  final Object? raw;
  try {
    raw = jsonDecode(encoded);
  } on FormatException {
    return null;
  }
  if (raw is! Map) return null;
  final out = <String, Uint8List>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || value is! String) return null;
    try {
      out[key] = base64.decode(value);
    } on FormatException {
      return null;
    }
  }
  return out;
}

/// Read whatever a freshly provisioned directory holds.
///
/// Reads only the names we know: a provisioning run leaves nothing else there
/// today, but the runtime directory this may later be pointed at holds sockets
/// and a PSK, and none of that belongs in the container.
Future<Map<String, Uint8List>> collectSovereignIdentity(String dir) async {
  final out = <String, Uint8List>{};
  for (final name in kSovereignIdentityFiles) {
    final file = File('$dir/$name');
    if (!await file.exists()) continue;
    out[name] = await file.readAsBytes();
  }
  return out;
}

/// Write the material into a node directory ahead of a boot.
///
/// The device key is a secret, so it is written 0600 rather than inheriting
/// the umask. The directory itself is already private (the runtime lease
/// creates it 0700), which is what protects the rest.
///
/// The mode goes on through libc, never `Process.run('chmod', …)`: a bare
/// command name is resolved through PATH, and on iOS a subprocess does not run
/// at all. Best-effort by design — a host whose libc cannot answer still gets
/// the key, inside a directory that is already 0700.
Future<void> materialiseSovereignIdentity(
  String dir,
  Map<String, Uint8List> files,
) async {
  await Directory(dir).create(recursive: true);
  for (final name in kSovereignIdentityFiles) {
    final bytes = files[name];
    if (bytes == null) continue;
    final path = '$dir/$name';
    await File(path).writeAsBytes(bytes, flush: true);
    if (name == kDeviceIdentitySkFile && !Platform.isWindows) {
      posixChmod(path, 0x180); // 0600
    }
  }
}
