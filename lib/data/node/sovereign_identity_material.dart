import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xveil/core/posix_file_facts.dart' show posixChmod;
import 'package:xveil/data/storage/storage.dart';

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
///
/// See also [instanceIdFrom], which pulls THIS device's instance id back out of
/// the stored blob — the value that tells two devices of one identity apart
/// once their invites stopped doing it.

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

/// The phrase-derived node config, kept by a device that does NOT boot on it.
///
/// A restored device runs on a key of its own, so its own config cannot say who
/// the identity is. But an invite carries a public key AND its anti-sybil
/// nonce, and the address a contact writes down is the hash of that key — so a
/// device handing out its own key would have contacts addressing the DEVICE
/// while it collects mail under the IDENTITY. Nothing would ever arrive.
///
/// This is where the master's key and nonce come from. Mined alongside the
/// device's own config rather than after it: two minings in parallel cost about
/// what one costs on any machine with a spare core.
const kMasterConfigSetting = 'node.master_config.v1';

/// Container key. Versioned: a later layout change must not be read as a
/// corrupt copy of this one.
const kSovereignIdentitySetting = 'node.sovereign_identity.v1';

/// Where the identity's ENCRYPTED sovereign credential is stored.
///
/// Declared here, with the other identity material, rather than beside the
/// code that writes it: the boot reads it to decide which identity a phrase
/// names — a credential means the hybrid master, none means the classic
/// Ed25519 one — and two copies of a storage key drift into two different
/// keys, which here would mean silently provisioning the wrong identity.
const kSovereignBundleSetting = 'devices.sovereign.bundle.v1';

/// Read this device's sovereign material, wherever it lives.
///
/// It lives in the CHUNKED FILE STORE, not in a setting, and the difference is
/// not cosmetic: a single setting record holds about 2-3 KiB, and a hybrid
/// identity's material is past that — its master public key alone is 929 bytes
/// and every delegation carries a hybrid certificate. Stored as a setting it
/// throws `PayloadTooLarge` at provisioning time, the node falls back to a
/// degenerate document, and the identity quietly becomes the classic one.
///
/// This project has been bitten by that limit four times now, and every time
/// the closed-loop tests were green: the in-memory store enforces no cap, so
/// the failure only exists against a real container. It was found here by
/// running a real daemon, not by a test.
///
/// The setting is still read as a fallback, because material written by an
/// earlier build lives there and an identity must not lose its device key to
/// an upgrade.
Future<String?> readSovereignMaterial(Storage storage) async {
  try {
    final bytes = await storage.loadFile(kSovereignIdentitySetting);
    if (bytes != null && bytes.isNotEmpty) return utf8.decode(bytes);
  } catch (_) {
    // Fall through to the legacy home rather than fail: a missing or
    // unreadable file is exactly the pre-upgrade state.
  }
  return storage.getSetting(kSovereignIdentitySetting);
}

/// Write this device's sovereign material.
///
/// To the file store, always — the size that broke this is the ordinary size
/// of a hybrid identity, not an edge case. The legacy setting is cleared in
/// the same breath so there is ONE copy: two, with a reader that prefers the
/// file, is a stale record that still looks authoritative.
Future<void> writeSovereignMaterial(Storage storage, String encoded) async {
  await storage.storeFile(
    kSovereignIdentitySetting,
    Uint8List.fromList(utf8.encode(encoded)),
    name: 'sovereign-identity',
  );
  try {
    await storage.putSetting(kSovereignIdentitySetting, '');
  } catch (_) {
    // Best effort: an uncleared legacy record is dead weight, not a fault.
  }
}

/// The identity's encrypted sovereign credential, wherever it lives.
///
/// ONE reader, because the two that existed did not agree. The credential's
/// PRESENCE is what decides which identity a phrase names — hybrid with one,
/// classic without — so a reader that misses a copy does not fail, it
/// provisions a DIFFERENT identity under a different address, silently.
///
/// It lives in the chunked file store for the same reason the material does:
/// the hybrid blob is ~3.1 KiB base64 and a single settings record holds about
/// 4 KiB, so the settings path threw `PayloadTooLarge` on every store (found
/// live 2026-07-25, on the first real link ceremony). The legacy settings key
/// is still read, base64-decoded, so a store that DID persist a credential
/// there keeps opening it.
///
/// `corrupt` is not `bundle == null`: an unreadable or absurdly sized
/// credential must never be taken for "this identity has none".
Future<({Uint8List? bundle, bool corrupt})> readSovereignCredential(
  Storage storage,
) async {
  Uint8List? file;
  try {
    file = await storage.loadFile(kSovereignBundleSetting);
  } catch (_) {
    return (bundle: null, corrupt: true);
  }
  if (file != null) {
    if (file.isEmpty || file.length > kMaxSovereignCredentialBytes) {
      return (bundle: null, corrupt: true);
    }
    return (bundle: Uint8List.fromList(file), corrupt: false);
  }
  final raw = await storage.getSetting(kSovereignBundleSetting);
  if (raw == null || raw.isEmpty) return (bundle: null, corrupt: false);
  try {
    final value = Uint8List.fromList(base64Decode(raw));
    if (value.isEmpty || value.length > kMaxSovereignCredentialBytes) {
      return (bundle: null, corrupt: true);
    }
    return (bundle: value, corrupt: false);
  } catch (_) {
    return (bundle: null, corrupt: true);
  }
}

/// A sovereign credential past this is not one. A hybrid bundle is ~2.3 KiB
/// raw; the margin is for a format that grows, not for a file that is really
/// something else.
const int kMaxSovereignCredentialBytes = 16 * 1024;

/// Set once this identity's recovery certificate has been written to a file.
///
/// Not a convenience flag: the identity is named by a master whose Falcon half
/// exists only inside the credential, so until this is set the identity is one
/// device failure away from being gone. What reads it is the standing reminder
/// — the point is that the app knows the difference between "backed up" and
/// "not yet", and says so instead of assuming.
const kRecoveryCertificateSavedSetting = 'identity.recovery_certificate.saved.v1';

/// Whether [files] belong to the identity whose material is ALREADY laid out
/// in [dir].
///
/// The instance id is what tells one identity's device from another's: it is
/// this device's id WITHIN one identity, stable across document merges and
/// different for every identity the device holds. A running node's directory
/// already has its own copy, put there by the boot that materialised it.
///
/// True when nothing is laid out yet — a fresh runtime directory is what the
/// boot materialises into, and it has no identity to contradict.
///
/// This exists because a re-read takes a Storage and writes into a directory,
/// and the two arguments used to come from different places: an all-online
/// switch between them meant one identity's document — secret device key
/// included — was written into another identity's private runtime directory
/// (report17 XV17-M13).
bool sovereignMaterialBelongsHere(String dir, Map<String, Uint8List> files) {
  final here = File('$dir/$kInstanceIdFile');
  if (!here.existsSync()) return true;
  final mine = here.readAsBytesSync();
  final incoming = files[kInstanceIdFile];
  if (incoming == null || incoming.isEmpty) return false;
  if (mine.length != incoming.length) return false;
  for (var i = 0; i < mine.length; i++) {
    if (mine[i] != incoming[i]) return false;
  }
  return true;
}

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

/// THIS device's instance id, out of the stored sovereign blob.
///
/// The value that tells two devices of one identity apart. Their invites no
/// longer can: an invite names the identity, deliberately, so every device of
/// it hands out the same string. Null when the blob is absent or carries no
/// instance — an identity with no sovereign material has one device by
/// definition, and the caller falls back to comparing node ids.
///
/// Takes the stored STRING rather than a Storage: the decoding is the whole
/// job, and a pure function of it can be tested without a container.
Uint8List? instanceIdFrom(String? encoded) {
  if (encoded == null || encoded.isEmpty) return null;
  final files = decodeSovereignIdentity(encoded);
  final id = files?[kInstanceIdFile];
  return (id == null || id.isEmpty) ? null : id;
}
