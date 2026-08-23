import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/log.dart';
import '../../core/secret_wipe.dart';
import '../native_libs.dart' show processLibFor;
import 'node_controller.dart';
import 'veil_library.dart' show verifiedVeilLibrary;
import 'proxy_routing.dart';
import 'veil_node.dart' show veilSocketProbe;

/// The handle the embedded-node symbols resolve against. On Android they live
/// in the dlopen'd `libveilclient_ffi.so` (not the global scope), so we must
/// use that handle; on iOS/desktop they are process-global. See
/// [processLibFor].
/// Refused unless it is the library these bindings describe — see
/// [verifiedVeilLibrary]. `lookupFunction` matches a name, not a signature, so
/// a library of another revision resolves and then corrupts memory on the
/// first call; the node is started through this handle before anything else in
/// the app would have checked.
DynamicLibrary _veilLib() => verifiedVeilLibrary();

/// One `[[bootstrap_peers]]` entry — a known node the embedded node dials at
/// boot to join a network (seed set / testnet). Fields mirror veil's
/// `BootstrapPeer` (veil-types): [transport] e.g. `obfs4-tcp://host:port`,
/// [publicKey]/[nonce] base64, [algo] signature algorithm.
///
/// NOTE: these point the node at a specific network — treat them as
/// configuration, NOT secrets, but a testnet set is environment-specific and
/// must not be hardcoded into committed source (load from a local, gitignored
/// file via [BootstrapPeerCfg.listFromJson]).
class BootstrapPeerCfg {
  const BootstrapPeerCfg({
    required this.transport,
    required this.publicKey,
    required this.nonce,
    this.algo = 'ed25519',
  });

  final String transport;
  final String publicKey;
  final String nonce;
  final String algo;

  /// Parse a JSON array of `{transport, public_key, nonce, algo?}` objects
  /// (the shape mirrors the ansible inventory's `veil_bootstrap_peers`).
  static List<BootstrapPeerCfg> listFromJson(List<dynamic> json) => [
    for (final e in json)
      BootstrapPeerCfg(
        transport: (e as Map)['transport'] as String,
        publicKey: e['public_key'] as String,
        nonce: e['nonce'] as String,
        algo: (e['algo'] as String?) ?? 'ed25519',
      ),
  ];
}

/// Combine two bootstrap-peer sources into one candidate list, `primary`
/// first, dropping any entry whose `public_key` already appeared.
///
/// Exists because the two sources used to be either/or: an operator-supplied
/// list REPLACED the bundled production seeds, so naming a single alternative
/// entry point silently dropped every seed. A node that wants a way in when
/// the seeds are blocked needs both sets at once, not a choice between them.
/// Deduplication is by public key, not transport: the same node reached over
/// two transports is still one dial target, and dialing it twice doubles the
/// DPI-visible handshake traffic for nothing.
///
/// Pure (no FFI, no assets) so it is unit-testable.
List<BootstrapPeerCfg> mergeBootstrapPeers(
  List<BootstrapPeerCfg> primary,
  List<BootstrapPeerCfg> fallback,
) {
  final seen = <String>{};
  return [
    for (final p in [...primary, ...fallback])
      if (seen.add(p.publicKey)) p,
  ];
}

// C ABI from veilclient-ffi (node-embedded feature):
//   char     *veil_config_init(uint32_t difficulty, char** err_out);
//   VeilNode *veil_node_start(const uint8_t*, size_t, char** err_out);
//   VeilNode *veil_node_start_deferred(const uint8_t*, size_t, bool anonymous, char** err_out);
//   int       veil_node_apply_config(const VeilNode*, const uint8_t*, size_t, char** err_out);
//   void      veil_node_stop(VeilNode*);
//   void      veil_free_string(char*);
typedef _StartNative =
    Pointer<Void> Function(Pointer<Uint8>, IntPtr, Pointer<Pointer<Utf8>>);
typedef _StartDart =
    Pointer<Void> Function(Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);
// Deferred boot carries an extra `bool anonymous` (arms onion at boot).
typedef _StartDeferredNative =
    Pointer<Void> Function(
      Pointer<Uint8>,
      IntPtr,
      Bool,
      Pointer<Pointer<Utf8>>,
    );
typedef _StartDeferredDart =
    Pointer<Void> Function(Pointer<Uint8>, int, bool, Pointer<Pointer<Utf8>>);
typedef _StopNative = Void Function(Pointer<Void>);
typedef _StopDart = void Function(Pointer<Void>);
// int veil_node_stop_timeout(VeilNode*, uint64_t ms):
//   0 the node's thread finished, 1 the budget passed and it was detached.
typedef _StopTimeoutNative = Int32 Function(Pointer<Void>, Uint64);
typedef _StopTimeoutDart = int Function(Pointer<Void>, int);
typedef _FreeStrNative = Void Function(Pointer<Utf8>);
typedef _FreeStrDart = void Function(Pointer<Utf8>);
// int veil_restore_identity_from_phrase_zeroize(
//     phrase*, phrase_len, veil_dir*, veil_dir_len,
//     instance_label*, instance_label_len, err_out**):
//   0 on success. The phrase buffer is WRITABLE — the native side wipes it in
//   place before returning, on every path.
typedef _RestoreIdentityWithKeyNative =
    Int32 Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Pointer<Utf8>>,
    );
typedef _RestoreIdentityWithKeyDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );
typedef _RestoreIdentityNative =
    Int32 Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Pointer<Utf8>>,
    );
typedef _RestoreIdentityDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );
// int veil_delegate_device_from_phrase_zeroize(
//     phrase*, phrase_len, veil_dir*, veil_dir_len,
//     device_pubkey* /* NULL = this device's own */, device_pubkey_len,
//     err_out**): 0 on success. The phrase buffer is wiped in place.
typedef _DelegateDeviceNative =
    Int32 Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Pointer<Utf8>>,
    );
typedef _DelegateDeviceDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );
// int veil_adopt_identity_document_from_config_zeroize(
//     config_toml*, len, veil_dir*, len, document*, len,
//     key_idx_out*, err_out**): 0 on success. The config is wiped in place.
typedef _AdoptDocNative =
    Int32 Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint16>,
      Pointer<Pointer<Utf8>>,
    );
typedef _AdoptDocDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint16>,
      Pointer<Pointer<Utf8>>,
    );
// int veil_identity_document_node_id(document*, len, out_node_id*, err_out**):
//   0 on success, writing 32 bytes to out_node_id.
typedef _DocNodeIdNative =
    Int32 Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      Pointer<Pointer<Utf8>>,
    );
typedef _DocNodeIdDart =
    int Function(Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Pointer<Utf8>>);
// int veil_master_signing_key_from_phrase_zeroize(phrase*, len, out32*, err**)
typedef _MasterKeyNative =
    Int32 Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      Pointer<Pointer<Utf8>>,
    );
typedef _MasterKeyDart =
    int Function(Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Pointer<Utf8>>);
// int veil_adopt_identity_document_from_master_zeroize(
//     master_sk*, veil_dir*, len, document*, len, key_idx_out*, err**)
typedef _AdoptFromMasterNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint16>,
      Pointer<Pointer<Utf8>>,
    );
typedef _AdoptFromMasterDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint16>,
      Pointer<Pointer<Utf8>>,
    );
typedef _ConfigInitNative =
    Pointer<Utf8> Function(Uint32, Pointer<Pointer<Utf8>>);
typedef _ConfigInitDart = Pointer<Utf8> Function(int, Pointer<Pointer<Utf8>>);
typedef _ComposeNative =
    Pointer<Utf8> Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Pointer<Utf8>>,
    );
typedef _ComposeDart =
    Pointer<Utf8> Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );
typedef _ApplyConfigNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Pointer<Utf8>>,
    );
typedef _ApplyConfigDart =
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Pointer<Utf8>>);
//   int veil_node_reload_identity(const VeilNode*, char** err_out);
typedef _ReloadIdentityNative =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
typedef _ReloadIdentityDart =
    int Function(Pointer<Void>, Pointer<Pointer<Utf8>>);
// Opt-in message-signature FFI (stateless; no VeilNode handle):
//   int veil_identity_sign(const uint8_t* toml, size_t, const uint8_t* msg,
//                          size_t, uint8_t out_sig[64], uint8_t out_pk[32],
//                          char** err_out);
//   int veil_identity_verify(const uint8_t node_id[32], const uint8_t pk[32],
//                            const uint8_t* msg, size_t, const uint8_t sig[64]);
typedef _SignNative =
    Int32 Function(
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Pointer<Utf8>>,
    );
typedef _SignDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Pointer<Utf8>>,
    );
//   int veil_identity_document_authorizes(const uint8_t* doc, size_t,
//                                          const uint8_t node_id[32],
//                                          const uint8_t pubkey[32]);
typedef _DocAuthorizesNative =
    Int32 Function(Pointer<Uint8>, IntPtr, Pointer<Uint8>, Pointer<Uint8>);
typedef _DocAuthorizesDart =
    int Function(Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>);
typedef _VerifyNative =
    Int32 Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      IntPtr,
      Pointer<Uint8>,
    );
typedef _VerifyDart =
    int Function(
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
    );

/// True when the loaded veil dylib exposes the embedded-node FFI (i.e. it was
/// built `--features node-embedded`). Lets the app pick the in-process deniable
/// boot path only when the symbols are actually present.
bool embeddedNodeAvailable({DynamicLibrary? lib}) {
  final dl = lib ?? _veilLib();
  try {
    dl.lookup<NativeFunction<_ConfigInitNative>>('veil_config_init');
    return true;
  } catch (_) {
    return false;
  }
}

/// A veil node running IN-PROCESS via the embedded-node FFI (no subprocess).
/// Requires a dylib built with `--features node-embedded` to be loaded.
class EmbeddedNode {
  EmbeddedNode._(this._handle, this._dl);

  final Pointer<Void> _handle;
  final DynamicLibrary _dl;
  bool _stopped = false;

  /// Provision a fresh node identity IN-PROCESS (generate keypair + mine the
  /// PoW nonce) and return its config as TOML — **nothing is written to disk**.
  /// Store the result inside the deniable container (see Storage.saveNodeConfig)
  /// and later boot from it via [startDeferred] + [applyConfig].
  ///
  /// [difficulty] is the PoW difficulty in leading zero bits (0 = canonical
  /// default). Mining can take a while — run it off the UI isolate.
  ///
  /// ⚠️ The returned TOML contains the node's PRIVATE KEY and it is a `String`,
  /// which Dart cannot overwrite (audit XV-22 — see lib/core/secret_wipe.dart).
  /// Every buffer this key is COPIED into on its way to the native side is
  /// wiped; the string itself lives until the collector reclaims it, and
  /// closing that would mean changing this signature to hand back bytes and
  /// teaching every caller to release them. Not done: the same key is in the
  /// space on disk and in the node's own memory for the life of the process, so
  /// the string is not the exposure that decides anything.
  static String mineConfig(int difficulty, {DynamicLibrary? lib}) {
    final dl = lib ?? _veilLib();
    final initFn = dl.lookupFunction<_ConfigInitNative, _ConfigInitDart>(
      'veil_config_init',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final out = initFn(difficulty, errOut);
      if (out == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_config_init failed: $msg');
      }
      final toml = out.toDartString();
      freeStr(out);
      return toml;
    } finally {
      calloc.free(errOut);
    }
  }

  /// Provision the node identity FROM A MASTER PHRASE (onboarding-phrase epic
  /// P2): phrase → master seed → the same Ed25519 derivation the sovereign
  /// restore uses, with only the anti-sybil nonce mined. Deterministic in the
  /// phrase — a later restore from the same phrase lands on the SAME node_id.
  /// The native side zeroizes the phrase buffer in place; nothing touches
  /// disk (persist via Storage.saveNodeConfig like [mineConfig]'s output).
  static String configFromPhrase(
    String phrase, {
    int difficulty = 0,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final initFn = dl
        .lookupFunction<
          Pointer<Utf8> Function(
            Pointer<Uint8>,
            IntPtr,
            Uint32,
            Pointer<Pointer<Utf8>>,
          ),
          Pointer<Utf8> Function(
            Pointer<Uint8>,
            int,
            int,
            Pointer<Pointer<Utf8>>,
          )
        >('veil_config_init_from_phrase_zeroize');
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final phraseC = phrase.toNativeUtf8();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final out = initFn(
        phraseC.cast<Uint8>(),
        phraseC.length,
        difficulty,
        errOut,
      );
      if (out == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_config_init_from_phrase failed: $msg');
      }
      final toml = out.toDartString();
      freeStr(out);
      return toml;
    } finally {
      // The native side zeroizes the phrase in place — but only once it has
      // read it. An argument that is rejected before that (a bad length, a
      // failed allocation) returns with the words still in the buffer, so wipe
      // it here too rather than trusting the happy path (audit XV-22).
      wipeNativeSecret(phraseC.cast<Uint8>(), phraseC.length);
      calloc.free(phraseC);
      calloc.free(errOut);
    }
  }

  /// Provision THIS DEVICE's sovereign identity from the master phrase,
  /// writing `identity_document.bin`, `device_identity_sk.bin` and
  /// `instance_id` into [veilDir].
  ///
  /// Not the same thing as [configFromPhrase], and the two answer different
  /// questions. [configFromPhrase] derives the node's ROUTING keypair — who
  /// this process is on the wire. This derives the MASTER from the same phrase
  /// and mints a SEPARATE per-device key under it, so that one identity can
  /// have several devices: `node_id` stays BLAKE3(master_pk) — the value the
  /// app already publishes — while each device holds its own key and its own
  /// `instance_id`. Without a document on disk the node builds a DEGENERATE
  /// one where master == device, which is why two devices restored from one
  /// phrase currently collide into a single node.
  ///
  /// CALL THIS ONCE PER DEVICE AND KEEP WHAT IT WRITES. It is idempotent in
  /// `instance_id` (that file is loaded when present) but NOT in the device
  /// key: every call mints a fresh one, which would orphan the document
  /// already published for this identity. Provision, persist, then materialise
  /// the stored bytes on each boot — never re-provision.
  /// Provision this device's sovereign material from [phrase].
  ///
  /// [nodeConfigToml] is THE KEY THIS DEVICE ALREADY RUNS ON, and passing it is
  /// what keeps a device to one key. Without it the restore mints a fresh
  /// random subkey and names that in the document, while the node goes on
  /// signing and handshaking with its own — so every signature the device makes
  /// fails its own author binding, silently: the message is stored, filtered
  /// out of every read, and skipped by every send. Measured on a two-device
  /// stand as posts that were invisible on the device that wrote them.
  ///
  /// Null only where there is no node config yet, which is the first-run path
  /// that derives its key from the phrase and therefore has nothing to reconcile.
  static void provisionSovereignIdentity(
    String phrase, {
    required String veilDir,
    required String instanceLabel,
    String? nodeConfigToml,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final withNodeKey = nodeConfigToml != null && nodeConfigToml.isNotEmpty;
    final restoreFn = withNodeKey
        ? null
        : dl.lookupFunction<_RestoreIdentityNative, _RestoreIdentityDart>(
            'veil_restore_identity_from_phrase_zeroize',
          );
    final restoreWithKeyFn = withNodeKey
        ? dl.lookupFunction<
            _RestoreIdentityWithKeyNative,
            _RestoreIdentityWithKeyDart
          >('veil_restore_identity_from_phrase_zeroize_with_node_key')
        : null;
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final phraseC = phrase.toNativeUtf8();
    final dirC = veilDir.toNativeUtf8();
    final labelC = instanceLabel.toNativeUtf8();
    final tomlC = withNodeKey ? nodeConfigToml.toNativeUtf8() : null;
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final rc = tomlC != null
          ? restoreWithKeyFn!(
              phraseC.cast<Uint8>(),
              phraseC.length,
              dirC.cast<Uint8>(),
              dirC.length,
              labelC.cast<Uint8>(),
              labelC.length,
              tomlC.cast<Uint8>(),
              tomlC.length,
              errOut,
            )
          : restoreFn!(
              phraseC.cast<Uint8>(),
              phraseC.length,
              dirC.cast<Uint8>(),
              dirC.length,
              labelC.cast<Uint8>(),
              labelC.length,
              errOut,
            );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_restore_identity_from_phrase failed: $msg');
      }
    } finally {
      // Same reasoning as [configFromPhrase]: the native side wipes the phrase
      // in place, but only once it has got far enough to read it. An argument
      // rejected before that (over-length, bad UTF-8) returns with the words
      // still in the buffer (audit XV-22). The directory and the label are not
      // secret.
      wipeNativeSecret(phraseC.cast<Uint8>(), phraseC.length);
      calloc.free(phraseC);
      calloc.free(dirC);
      calloc.free(labelC);
      calloc.free(errOut);
    }
  }

  /// Admit a device to this identity: append its key to the signed document
  /// in [veilDir], under the master derived from [phrase].
  ///
  /// What makes one identity hold several devices, and the alternative is not
  /// "a document each". `node_id` is BLAKE3 of the master key, so two devices
  /// restored from one phrase publish two single-key documents under the SAME
  /// id; the later publisher displaces the earlier and the displaced device
  /// stays online believing it is reachable.
  ///
  /// [devicePubkey] null means THIS device's own key, read natively from
  /// `device_identity_sk.bin` — the app never loads or carries key material.
  /// That is the merge call: a device restored from the phrase receives the
  /// other device's document, drops it into [veilDir], and adds itself. The
  /// previous signer's secret is on the other machine, so the document is
  /// re-signed by the newly delegated key; every subkey is master-signed, so a
  /// verifier accepts either.
  ///
  /// Refuses, rather than guesses, when the phrase belongs to a different
  /// identity than the document does.
  static void delegateDeviceFromPhrase(
    String phrase, {
    required String veilDir,
    Uint8List? devicePubkey,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final delegateFn = dl
        .lookupFunction<_DelegateDeviceNative, _DelegateDeviceDart>(
          'veil_delegate_device_from_phrase_zeroize',
        );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final phraseC = phrase.toNativeUtf8();
    final dirC = veilDir.toNativeUtf8();
    final pkPtr = devicePubkey == null
        ? nullptr
        : calloc<Uint8>(devicePubkey.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      if (devicePubkey != null) {
        pkPtr
            .cast<Uint8>()
            .asTypedList(devicePubkey.length)
            .setAll(0, devicePubkey);
      }
      final rc = delegateFn(
        phraseC.cast<Uint8>(),
        phraseC.length,
        dirC.cast<Uint8>(),
        dirC.length,
        pkPtr.cast<Uint8>(),
        devicePubkey?.length ?? 0,
        errOut,
      );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_delegate_device_from_phrase failed: $msg');
      }
    } finally {
      // Same reasoning as the other phrase entry points: the native side wipes
      // the buffer, but only once it has read it (audit XV-22). The public key
      // and the directory are not secret.
      wipeNativeSecret(phraseC.cast<Uint8>(), phraseC.length);
      calloc.free(phraseC);
      calloc.free(dirC);
      if (pkPtr != nullptr) calloc.free(pkPtr);
      calloc.free(errOut);
    }
  }

  /// Retire [deviceId]'s key from the identity document in [veilDir],
  /// permanently, with the master derived from [phrase].
  ///
  /// The cryptographic half of revocation: the group stops listing the
  /// device elsewhere, and THIS removes the document's vouching for its key
  /// — plus a master-signed tombstone the document merge can never
  /// resurrect. Returns true when the document changed, false when the
  /// device was already tombstoned.
  static bool revokeIdentityDeviceFromPhrase(
    String phrase, {
    required String veilDir,
    required Uint8List deviceId,
    DynamicLibrary? lib,
  }) {
    if (deviceId.length != 32) {
      throw ArgumentError('deviceId must be 32 bytes, got ${deviceId.length}');
    }
    final dl = lib ?? _veilLib();
    final revokeFn = dl
        .lookupFunction<
          Int32 Function(
            Pointer<Uint8>,
            UintPtr,
            Pointer<Uint8>,
            UintPtr,
            Pointer<Uint8>,
            Pointer<Uint8>,
            Pointer<Pointer<Utf8>>,
          ),
          int Function(
            Pointer<Uint8>,
            int,
            Pointer<Uint8>,
            int,
            Pointer<Uint8>,
            Pointer<Uint8>,
            Pointer<Pointer<Utf8>>,
          )
        >('veil_revoke_identity_device_from_phrase_zeroize');
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final phraseC = phrase.toNativeUtf8();
    final dirC = veilDir.toNativeUtf8();
    final idPtr = calloc<Uint8>(32);
    final changedOut = calloc<Uint8>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      idPtr.asTypedList(32).setAll(0, deviceId);
      final rc = revokeFn(
        phraseC.cast<Uint8>(),
        phraseC.length,
        dirC.cast<Uint8>(),
        dirC.length,
        idPtr,
        changedOut,
        errOut,
      );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_revoke_identity_device failed: $msg');
      }
      return changedOut.value != 0;
    } finally {
      wipeNativeSecret(phraseC.cast<Uint8>(), phraseC.length);
      calloc.free(phraseC);
      calloc.free(dirC);
      calloc.free(idPtr);
      calloc.free(changedOut);
      calloc.free(errOut);
    }
  }

  /// Admit a device using the master secret this app already holds: the
  /// `[identity]` keypair of its own stored node config.
  ///
  /// THIS is the call the live path makes, and [delegateDeviceFromPhrase] is
  /// not. The phrase is consumed at setup and never stored, so by the time a
  /// second device is linked — possibly days later — there is no phrase to work
  /// from and nothing to prompt for. What the app does have is the node config,
  /// and for a phrase-provisioned identity that config's private key IS the
  /// master secret: the native side writes `derive_master_sk_ed25519(seed)`
  /// into it. The same authority, in a shape the app kept.
  ///
  /// [identityToml] carries that key, so the native copy is wiped on every
  /// path. [devicePubkey] null means THIS device's own key.
  static void delegateDeviceFromConfig(
    String identityToml, {
    required String veilDir,
    Uint8List? devicePubkey,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final delegateFn = dl
        .lookupFunction<_DelegateDeviceNative, _DelegateDeviceDart>(
          'veil_delegate_device_from_config_zeroize',
        );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final tomlBytes = utf8.encode(identityToml);
    final tomlPtr = calloc<Uint8>(tomlBytes.length);
    final dirC = veilDir.toNativeUtf8();
    final pkPtr = devicePubkey == null
        ? nullptr
        : calloc<Uint8>(devicePubkey.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      tomlPtr.asTypedList(tomlBytes.length).setAll(0, tomlBytes);
      if (devicePubkey != null) {
        pkPtr
            .cast<Uint8>()
            .asTypedList(devicePubkey.length)
            .setAll(0, devicePubkey);
      }
      final rc = delegateFn(
        tomlPtr,
        tomlBytes.length,
        dirC.cast<Uint8>(),
        dirC.length,
        pkPtr.cast<Uint8>(),
        devicePubkey?.length ?? 0,
        errOut,
      );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_delegate_device_from_config failed: $msg');
      }
    } finally {
      // The config holds the master private key — both the native copy and the
      // Dart bytes it was built from go down zeroed (audit XV-22).
      wipeNativeSecret(tomlPtr, tomlBytes.length);
      wipeSecretBytes(tomlBytes);
      calloc.free(tomlPtr);
      calloc.free(dirC);
      if (pkPtr != nullptr) calloc.free(pkPtr);
      calloc.free(errOut);
    }
  }

  /// Merge a document received from ANOTHER device of this identity into
  /// [veilDir], and return which subkey index this device ends up as.
  ///
  /// One call for both directions, because they are not symmetric. The device
  /// that merges first receives a document naming only the other and appends
  /// itself; the device that merges second receives one that already names it.
  /// Either way the native side records this device's own subkey index — the
  /// document's own `sig_key_idx` names whichever device signed it, and a
  /// device that stores that without recording its own index signs with a key
  /// it does not have and comes up with no identity at all.
  ///
  /// Refuses, writing nothing, a document that does not decode, does not
  /// verify, or belongs to a different identity.
  static int adoptIdentityDocument(
    String identityToml, {
    required String veilDir,
    required Uint8List document,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final adoptFn = dl.lookupFunction<_AdoptDocNative, _AdoptDocDart>(
      'veil_adopt_identity_document_from_config_zeroize',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final tomlBytes = utf8.encode(identityToml);
    final tomlPtr = calloc<Uint8>(tomlBytes.length);
    final dirC = veilDir.toNativeUtf8();
    // from_raw_parts needs a non-null pointer even for length 0.
    final docPtr = calloc<Uint8>(document.isEmpty ? 1 : document.length);
    final idxOut = calloc<Uint16>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      tomlPtr.asTypedList(tomlBytes.length).setAll(0, tomlBytes);
      if (document.isNotEmpty) {
        docPtr.asTypedList(document.length).setAll(0, document);
      }
      final rc = adoptFn(
        tomlPtr,
        tomlBytes.length,
        dirC.cast<Uint8>(),
        dirC.length,
        docPtr,
        document.length,
        idxOut,
        errOut,
      );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_adopt_identity_document failed: $msg');
      }
      return idxOut.value;
    } finally {
      // The config holds the master private key (audit XV-22). The document is
      // public.
      wipeNativeSecret(tomlPtr, tomlBytes.length);
      wipeSecretBytes(tomlBytes);
      calloc.free(tomlPtr);
      calloc.free(dirC);
      calloc.free(docPtr);
      calloc.free(idxOut);
      calloc.free(errOut);
    }
  }

  /// Adopt a document that already NAMES this device, with no master at all.
  ///
  /// The one caller the other two adopt entry points fail: a freshly linked
  /// device whose config holds only its own device key — not the master
  /// (from_config demands that), and the phrase left with the ceremony
  /// (from_master needs it). The master's authority arrives INSIDE the
  /// document: every subkey in it is master-signed, including ours. A
  /// document that does not name this config's key is refused with nothing
  /// written.
  static int adoptIdentityDocumentNamed(
    String identityToml, {
    required String veilDir,
    required Uint8List document,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final adoptFn = dl.lookupFunction<_AdoptDocNative, _AdoptDocDart>(
      'veil_adopt_identity_document_named_zeroize',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final tomlBytes = utf8.encode(identityToml);
    final tomlPtr = calloc<Uint8>(tomlBytes.length);
    final dirC = veilDir.toNativeUtf8();
    // from_raw_parts needs a non-null pointer even for length 0.
    final docPtr = calloc<Uint8>(document.isEmpty ? 1 : document.length);
    final idxOut = calloc<Uint16>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      tomlPtr.asTypedList(tomlBytes.length).setAll(0, tomlBytes);
      if (document.isNotEmpty) {
        docPtr.asTypedList(document.length).setAll(0, document);
      }
      final rc = adoptFn(
        tomlPtr,
        tomlBytes.length,
        dirC.cast<Uint8>(),
        dirC.length,
        docPtr,
        document.length,
        idxOut,
        errOut,
      );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_adopt_identity_document_named failed: $msg');
      }
      return idxOut.value;
    } finally {
      // The config holds this device's private key. The document is public.
      wipeNativeSecret(tomlPtr, tomlBytes.length);
      wipeSecretBytes(tomlBytes);
      calloc.free(tomlPtr);
      calloc.free(dirC);
      calloc.free(docPtr);
      calloc.free(idxOut);
      calloc.free(errOut);
    }
  }

  /// The identity address a signed document names — BLAKE3 of the master key.
  ///
  /// The address this identity RECEIVES under, which is not always the address
  /// its node speaks under. They are the same 32 bytes for every identity in
  /// the field: a mined one is its own master, and a phrase-provisioned one
  /// derives its config key from the same master the document names. They part
  /// company once a device is given a transport key of its own — and a device
  /// still listening under its transport id would then be waiting where nobody
  /// sends, looking perfectly reachable from every angle.
  static Uint8List identityDocumentNodeId(
    Uint8List document, {
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final fn = dl.lookupFunction<_DocNodeIdNative, _DocNodeIdDart>(
      'veil_identity_document_node_id',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    // from_raw_parts needs a non-null pointer even for length 0.
    final docPtr = calloc<Uint8>(document.isEmpty ? 1 : document.length);
    final out = calloc<Uint8>(32);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      if (document.isNotEmpty) {
        docPtr.asTypedList(document.length).setAll(0, document);
      }
      final rc = fn(docPtr, document.length, out, errOut);
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_identity_document_node_id failed: $msg');
      }
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      calloc.free(docPtr);
      calloc.free(out);
      calloc.free(errOut);
    }
  }

  /// The master signing key behind a phrase — 32 bytes, no mining, no disk.
  ///
  /// What an app keeps once its node config stops being the master. Admitting a
  /// further device needs the master, at a moment when the phrase is long gone;
  /// this is the same 32 bytes the config used to carry, at the same exposure.
  static Uint8List masterKeyFromPhrase(String phrase, {DynamicLibrary? lib}) {
    final dl = lib ?? _veilLib();
    final fn = dl.lookupFunction<_MasterKeyNative, _MasterKeyDart>(
      'veil_master_signing_key_from_phrase_zeroize',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final phraseC = phrase.toNativeUtf8();
    final out = calloc<Uint8>(32);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final rc = fn(phraseC.cast<Uint8>(), phraseC.length, out, errOut);
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_master_signing_key_from_phrase failed: $msg');
      }
      return Uint8List.fromList(out.asTypedList(32));
    } finally {
      wipeNativeSecret(phraseC.cast<Uint8>(), phraseC.length);
      wipeNativeSecret(out, 32);
      calloc.free(phraseC);
      calloc.free(out);
      calloc.free(errOut);
    }
  }

  /// Merge a received document, authorising with the master key rather than
  /// with a node config — the only form that still works once the config is a
  /// per-device transport key instead of the master.
  static int adoptIdentityDocumentWithMaster(
    Uint8List masterKey, {
    required String veilDir,
    required Uint8List document,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final fn = dl.lookupFunction<_AdoptFromMasterNative, _AdoptFromMasterDart>(
      'veil_adopt_identity_document_from_master_zeroize',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final keyPtr = calloc<Uint8>(32);
    final dirC = veilDir.toNativeUtf8();
    final docPtr = calloc<Uint8>(document.isEmpty ? 1 : document.length);
    final idxOut = calloc<Uint16>();
    final errOut = calloc<Pointer<Utf8>>();
    try {
      keyPtr.asTypedList(32).setAll(0, masterKey);
      if (document.isNotEmpty) {
        docPtr.asTypedList(document.length).setAll(0, document);
      }
      final rc = fn(
        keyPtr,
        dirC.cast<Uint8>(),
        dirC.length,
        docPtr,
        document.length,
        idxOut,
        errOut,
      );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_adopt_identity_document_from_master: $msg');
      }
      return idxOut.value;
    } finally {
      wipeNativeSecret(keyPtr, 32);
      calloc.free(keyPtr);
      calloc.free(dirC);
      calloc.free(docPtr);
      calloc.free(idxOut);
      calloc.free(errOut);
    }
  }

  /// Compose a full, bootable node config from a stored identity (from
  /// [mineConfig], loaded out of the deniable container) plus EPHEMERAL,
  /// per-launch runtime endpoints — a [listenTransport] (e.g.
  /// `tcp://127.0.0.1:9931`), an [ipcSocket], and an [adminSocket] (filesystem
  /// paths). None of these are identity-bearing, so they are never stored.
  static String composeConfig({
    required String identityToml,
    required String listenTransport,
    required String ipcSocket,
    required String adminSocket,
    DynamicLibrary? lib,
    bool anonymous = false,
    bool lazyMining = false,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    List<String> udpReflectors = const [],
    String? obfs4PskFile,
    ProxyRouting proxy = ProxyRouting.disabled,
    // False when this identity declined the shared seed nodes. See
    // [withBuiltinSeedPolicy] for why an empty [bootstrapPeers] does not
    // already mean that.
    bool useBundledSeeds = true,
    // Where this device's sovereign identity material was laid out. Null on a
    // node that has none — see [withIdentityDir] for why the node cannot find
    // it otherwise.
    String? identityDir,
    // Whether this node serves the DHT for others. Null means "decide by
    // platform" — see [withDhtParticipation].
    bool? serveDht,
  }) {
    return _composeConfigImpl(
      identityToml: identityToml,
      listenTransport: listenTransport,
      ipcSocket: ipcSocket,
      adminSocket: adminSocket,
      lib: lib,
      anonymous: anonymous,
      lazyMining: lazyMining,
      bootstrapPeers: bootstrapPeers,
      udpReflectors: udpReflectors,
      obfs4PskFile: obfs4PskFile,
      proxy: proxy,
      useBundledSeeds: useBundledSeeds,
      identityDir: identityDir,
      serveDht: serveDht,
    );
  }

  /// Append a `[transport]` table pointing at a file holding the deployment-wide
  /// obfs4 pre-shared key. Networks that pin a shared obfs4 PSK (anti-probe)
  /// require dialers to present the SAME key — without it the obfs4 handshake
  /// fails with `obfs4-tcp transport requires obfs4_psk set in TransportContext`.
  /// Pure helper (no FFI), so it is unit-testable. [pskFilePath] must already
  /// exist and contain the base64 PSK.
  static String withObfs4PskFile(String toml, String? pskFilePath) {
    if (pskFilePath == null || pskFilePath.isEmpty) return toml;
    if (toml.contains('obfs4_psk_file')) return toml; // already set
    final line = 'obfs4_psk_file = "$pskFilePath"';
    // veil_config_compose serializes a full Config, so a `[transport]` table
    // may already exist; insert the key right under its header (a key-value
    // before any sub-table is valid TOML). Otherwise append a new table.
    const marker = '[transport]\n';
    final idx = toml.indexOf(marker);
    if (idx >= 0) {
      final at = idx + marker.length;
      return '${toml.substring(0, at)}$line\n${toml.substring(at)}';
    }
    return '$toml\n[transport]\n$line\n';
  }

  /// Forbid veil's COMPILE-TIME seed list when the shared seeds were declined.
  ///
  /// This is the half of the opt-out that actually does anything. The app's
  /// deniable boot passes no `[[bootstrap_peers]]` on purpose (injecting them
  /// made `veil_node_apply_config` fail with ENOENT on Android), so every stock
  /// install satisfies veil's `builtin_seed_policy = "auto"` condition —
  /// "neither `peers` nor `[[bootstrap_peers]]` is set" — and the runtime
  /// splices `veil_bootstrap::builtin_seeds()` into its own dial list. Handing
  /// the node an empty Dart-side peer list therefore removes NOTHING: it dials
  /// the same operator-run hosts a moment later, from inside itself.
  ///
  /// `"never"` is the only value that answers the question, and it is written
  /// while the config is being composed — so a node whose owner declined never
  /// holds the addresses at all, rather than holding them under an instruction
  /// not to use them.
  ///
  /// Writes NOTHING when the seeds are kept: veil's own default is `auto` and
  /// spelling it out here would freeze a decision that belongs to the runtime.
  /// Pure helper (no FFI), so it is unit-testable.
  static String withBuiltinSeedPolicy(String toml, bool useBundledSeeds) {
    if (useBundledSeeds) return toml;
    const line = 'builtin_seed_policy = "never"';
    // `veil_config_compose` serializes a full Config, so `[global]` normally
    // already carries a rendered policy — replace it rather than appending a
    // second key the TOML parser would reject as a duplicate.
    final rendered = RegExp(
      r'^[ \t]*builtin_seed_policy[ \t]*=.*$',
      multiLine: true,
    );
    if (rendered.hasMatch(toml)) return toml.replaceAll(rendered, line);
    const marker = '[global]\n';
    final idx = toml.indexOf(marker);
    if (idx >= 0) {
      final at = idx + marker.length;
      return '${toml.substring(0, at)}$line\n${toml.substring(at)}';
    }
    return '$toml\n[global]\n$line\n';
  }

  /// Name the directory the node must read its identity material from.
  ///
  /// WITHOUT THIS THE MATERIAL IS UNREACHABLE, however correctly it was
  /// provisioned. veil takes the identity directory to be the one holding the
  /// node's config file — and under deferred init, which is how this app starts
  /// its node, veil itself stages that config in a per-boot temp directory of
  /// its own making: a random name, created after the app has handed over, and
  /// scrubbed on shutdown. So there is no moment at which the app could put a
  /// document there, and a node that finds none builds the degenerate
  /// `master_pk == device_pk` document instead — the exact state in which two
  /// devices restored from one phrase collapse into a single node.
  ///
  /// Measured, not reasoned: with the material laid out in the runtime
  /// directory and this key absent, the node logged
  /// `sovereign_identity.standalone_built` while all three files sat next to
  /// its sockets.
  ///
  /// Pure helper (no FFI), so it is unit-testable — same shape as
  /// [withBuiltinSeedPolicy], and the same duplicate-key hazard: a rendered
  /// `[global]` may already carry the key.
  static String withIdentityDir(String toml, String? dir) {
    if (dir == null || dir.isEmpty) return toml;
    final line = 'identity_dir = "$dir"';
    final rendered = RegExp(r'^[ \t]*identity_dir[ \t]*=.*$', multiLine: true);
    if (rendered.hasMatch(toml)) return toml.replaceAll(rendered, line);
    const marker = '[global]\n';
    final idx = toml.indexOf(marker);
    if (idx >= 0) {
      final at = idx + marker.length;
      return '${toml.substring(0, at)}$line\n${toml.substring(at)}';
    }
    return '$toml\n[global]\n$line\n';
  }

  /// Append a `[metrics]` table exposing the node's Prometheus counters on a
  /// LOOPBACK listener — the stand's per-node twin of the relay's metrics
  /// endpoint, for correlating the node's own periodic work (DHT publishes,
  /// lookups, transport bytes) against live-call latency. Pure helper (no
  /// FFI) so it is unit-testable; debug builds alone decide whether to call
  /// it (same convention as the debug hook). No-op when [port] is null/zero
  /// or a `[metrics]` table already exists.
  static String withDebugMetrics(String toml, int? port) {
    if (port == null || port <= 0) return toml;
    if (toml.contains('[metrics]')) return toml;
    return '$toml\n[metrics]\n'
        'listen = "tcp://127.0.0.1:$port"\n'
        'path = "/metrics"\n'
        'allow_unauthenticated_remote_metrics = true\n';
  }

  /// Append `[[bootstrap_peers]]` tables so the node dials a known network
  /// (a seed set / testnet) at boot — without them an embedded node only sees
  /// the compiled-in BUILTIN_SEEDS. Pure helper (no FFI) so it is unit-testable.
  /// Mirrors the on-disk node.toml shape veil renders (top-level tables, NOT
  /// nested under `[network]`).
  static String withBootstrapPeers(String toml, List<BootstrapPeerCfg> peers) {
    if (peers.isEmpty) return toml;
    final buf = StringBuffer(toml);
    for (final p in peers) {
      // Defense-in-depth: never interpolate a value that could break out of the
      // TOML string (quote / newline / backslash) — skip a malformed entry
      // rather than emit a corrupt or injected config. transport must be a
      // structural scheme://rest URI; the rest must be plain base64-ish tokens.
      if (!_tomlSafe(p.transport) ||
          !_tomlSafe(p.publicKey) ||
          !_tomlSafe(p.nonce) ||
          !_tomlSafe(p.algo) ||
          !RegExp(
            r'^[a-z0-9.+-]+://[^\s\x00-\x1f"\\]+$',
          ).hasMatch(p.transport)) {
        continue;
      }
      buf
        ..write('\n[[bootstrap_peers]]\n')
        ..write('transport = "${p.transport}"\n')
        ..write('public_key = "${p.publicKey}"\n')
        ..write('nonce = "${p.nonce}"\n')
        ..write('algo = "${p.algo}"\n');
    }
    return buf.toString();
  }

  /// Configure public UDP reflectors used to discover the external address of
  /// the exact socket later reused by a peer-to-peer QUIC hole punch. Values
  /// must be numeric `IPv4:port` or `[IPv6]:port`; native config validates them
  /// again. Replaces a rendered `udp_reflectors = []` instead of duplicating
  /// `[nat]`.
  static String withUdpReflectors(String toml, List<String> reflectors) {
    final normalized = normalizeUdpReflectors(reflectors);
    if (normalized.isEmpty) return toml;

    final rendered = normalized.map((e) => '"$e"').join(', ');
    final line = 'udp_reflectors = [$rendered]';
    final existing = RegExp(
      r'^\s*udp_reflectors\s*=\s*\[[^\n\r]*\]\s*$',
      multiLine: true,
    );
    if (existing.hasMatch(toml)) return toml.replaceFirst(existing, line);

    final nat = RegExp(r'^\[nat\]\s*$', multiLine: true);
    final match = nat.firstMatch(toml);
    if (match != null) {
      final at = match.end;
      return '${toml.substring(0, at)}\n$line${toml.substring(at)}';
    }
    return '$toml\n[nat]\n$line\n';
  }

  /// Validate, canonicalize, de-duplicate and bound reflector endpoints.
  /// Exposed so public config loaders can fail loudly before node startup.
  static List<String> normalizeUdpReflectors(List<String> reflectors) {
    final normalized = <String>[];
    for (final raw in reflectors) {
      final value = _normalizeUdpReflector(raw);
      if (value != null && !normalized.contains(value)) normalized.add(value);
      // Bound accidental or hostile discovery fan-out before native startup.
      if (normalized.length == 8) break;
    }
    return List.unmodifiable(normalized);
  }

  static String? _normalizeUdpReflector(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.contains(RegExp(r'\s'))) return null;

    String host;
    String portText;
    var ipv6 = false;
    if (value.startsWith('[')) {
      final match = RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(value);
      if (match == null) return null;
      host = match.group(1)!;
      portText = match.group(2)!;
      ipv6 = true;
    } else {
      final colon = value.lastIndexOf(':');
      if (colon <= 0 || value.indexOf(':') != colon) return null;
      host = value.substring(0, colon);
      portText = value.substring(colon + 1);
    }
    final port = int.tryParse(portText);
    final address = InternetAddress.tryParse(host);
    if (port == null || port < 1 || port > 65535 || address == null) {
      return null;
    }
    if (ipv6 != (address.type == InternetAddressType.IPv6)) return null;
    return ipv6 ? '[${address.address}]:$port' : '${address.address}:$port';
  }

  /// True when [s] carries no TOML-string-breaking characters, so it is safe to
  /// interpolate inside `key = "..."`.
  static bool _tomlSafe(String s) => !s.contains(RegExp(r'["\n\r\\\t]'));

  /// Append the `[anonymity]` table to a composed [toml]. `receive_anonymous`
  /// (plain rendezvous RECEIVE = REACHABILITY: register a subscriber at a relay
  /// so a NAT'd node can be reached by its node_id at all — NOT anonymity, the
  /// relay already learns our node_id from the ad we publish) is ALWAYS on. When
  /// [anonymous], it ADDITIONALLY enables `onion_service` (location anonymity:
  /// register over an onion circuit so peers/relays never learn this identity's
  /// IP, so it can't be correlated to the user's other identities). Mirrors the
  /// veil stub boot config so the applied-config reload doesn't warn
  /// `anonymity.reload_ignored`. Pure helper — no FFI — so it is unit-testable.
  static String withAnonymity(String toml, bool anonymous) {
    if (toml.contains('[anonymity]')) return toml;
    final onion = anonymous ? 'onion_service = true\n' : '';
    return '$toml\n[anonymity]\nreceive_anonymous = true\n$onion';
  }

  /// Force app-embedded nodes to advertise the client-only `leaf` role.
  ///
  /// Veil's general-purpose config default is `core`, which is appropriate
  /// for an operator daemon but not for a phone or desktop client. Leaving the
  /// role implicit made every xVeil process start Core-only services, including
  /// a public UDP reflector on port 39999. The app consumes reflector
  /// announcements from authenticated Core peers; it must not become an
  /// operator merely because an older stored identity omitted `role`.
  ///
  /// Apply this only to the ephemeral composed config. The stored identity
  /// remains free of runtime posture, and a stale explicit `core` value is
  /// replaced rather than duplicated. If the input is not an identity config,
  /// leave it untouched so malformed data still fails in the native parser.
  static String withClientNodeRole(String toml) {
    final lines = toml.split('\n');
    final out = <String>[];
    var inIdentity = false;
    var sawIdentity = false;
    for (final line in lines) {
      final trimmed = line.trim();
      final table = RegExp(r'^\[([^\]]+)\]$').firstMatch(trimmed);
      if (table != null) {
        inIdentity = table.group(1)!.toLowerCase() == 'identity';
        if (inIdentity) {
          sawIdentity = true;
          out
            ..add(line)
            ..add('role = "leaf"');
          continue;
        }
      }
      if (inIdentity && RegExp(r'^role\s*=').hasMatch(trimmed)) continue;
      out.add(line);
    }
    return sawIdentity ? out.join('\n') : toml;
  }

  /// Force the `[Identity]` lazy-mining preference, OVERRIDING whatever the
  /// stored identity baked in. Lazy mining is a CPU-heavy BACKGROUND grind
  /// (raising the identity's anti-sybil difficulty via repeated PoW) that the
  /// node does NOT need to function; it competes with the latency-critical async
  /// runtime on mobile, and identities minted before the cap fix target an
  /// UNREACHABLE difficulty 64 — grinding a core forever, starving IPC (→ 12s FFI
  /// timeouts + UI hangs). Default OFF; the user opts IN via settings.
  ///
  /// Strips any persisted `lazy_mining` / `max_lazy_difficulty` and re-applies:
  /// disabled ⇒ absent ⇒ deserialises to `lazy_mining = false`; enabled ⇒
  /// `lazy_mining = true` with a REACHABLE cap (32, not 64) so the miner finishes
  /// and returns to idle. Pure helper (no FFI), so it is unit-testable.
  static String withLazyMining(String toml, bool enabled) {
    final stripped = toml
        .split('\n')
        .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('lazy_mining') &&
              !t.startsWith('max_lazy_difficulty');
        })
        .join('\n');
    if (!enabled) return stripped;
    // Opt-in: insert under the identity table with a reachable cap. If no
    // identity header is found (shouldn't happen for a real config) the string
    // is returned unchanged, leaving lazy mining OFF — the safe default.
    return stripped.replaceFirstMapped(
      RegExp(r'\[identity\]\n', caseSensitive: false),
      (m) => '${m[0]}lazy_mining = true\nmax_lazy_difficulty = 32\n',
    );
  }

  /// Append a `[session]` table with a TIGHT keepalive so the node's mesh
  /// session to its relays survives mobile NAT / Android socket reaping. The
  /// default keepalive is 30 s; on a phone the obfs4 TCP connection to the seeds
  /// gets reset ("Connection reset by peer") well before that, the routing table
  /// never warms, and `lookup_relay_x25519` (mailbox registration) times out — so
  /// the node can't register and becomes unreachable after a restart. A tight
  /// keepalive keeps the mapping fresh; idle_timeout MUST stay > keepalive.
  /// 15 s still let mobile relay sessions churn (observed: a phone registering
  /// on 2 relays as its session reset between keepalives → rendezvous ad /
  /// subscriber lag → cookie_unknown introduce drops → delivery latency), so
  /// tighten to 10 s to cover more aggressive carrier-NAT / radio idle windows.
  /// Pure helper (no FFI), unit-testable.
  /// Bytes per hour this device will spend on OTHER peers' DHT work.
  ///
  /// Measured 18.08.2026 on an idle client with three bytes per second of
  /// actual application traffic: 1.3 GB a day on a desktop and 5 GB a day on a
  /// phone, of which 85% was work done for strangers — storing their records,
  /// answering their lookups, being a hop of their walks. The answers to this
  /// device's own questions were one thousandth of the bill.
  ///
  /// veil's own default for a leaf is 8 MB/h. A phone gets an eighth of that:
  /// it is the device paying in metered data and battery, and it is also the
  /// one the network can least rely on as a replica, because it is asleep half
  /// the time. Left alone on desktop, where the veil default already applies.
  ///
  /// Not a switch. Every xVeil client runs as `leaf` and only the seeds are
  /// `core`, so a client that serves nothing takes the DHT's replica set down
  /// to three machines. Pure helper (no FFI), unit-testable.
  static String withMobileServiceBudget(String toml, {required bool isMobile}) {
    if (!isMobile || toml.contains('service_budget_bytes_per_hour'))
      return toml;
    const perHour = 1024 * 1024;
    if (toml.contains('[dht]')) {
      return toml.replaceFirst(
        '[dht]',
        '[dht]\nservice_budget_bytes_per_hour = $perHour',
      );
    }
    return '$toml\n[dht]\nservice_budget_bytes_per_hour = $perHour\n';
  }

  /// Set `[dht] participate` — whether this node serves the DHT for OTHERS.
  ///
  /// Not the same question as the service budget beside it. The budget refuses
  /// work AFTER the bytes have already crossed the network, which is why it
  /// was measured to change the traffic by nothing at all. This is advertised
  /// at handshake time (`NO_DHT_SERVICE`), so upgraded peers stop CHOOSING
  /// this node as a store target or a walk hop — the only thing that can
  /// reduce inbound traffic.
  ///
  /// What it does not touch: reachability. The node still publishes its own
  /// records, still resolves, still receives mail. It only stops doing DHT
  /// work on other people's behalf.
  ///
  /// The cost is real and belongs to the network, not to the person who turns
  /// it off: on a fleet where every client is a leaf and only the seeds are
  /// core, clients that serve nothing take the replica set down to the seeds.
  /// Hence the default split — phones off (5 GB/day measured, against bytes of
  /// their own traffic), desktops on — and hence the setting exists at all.
  static String withDhtParticipation(String toml, {required bool participate}) {
    if (toml.contains('participate')) return toml;
    // `true` is veil's own default and serialises to nothing; writing it
    // anyway makes the composed config say what it means, and makes a later
    // flip visible in a diff rather than being an absence.
    final line = 'participate = $participate';
    if (toml.contains('[dht]')) {
      return toml.replaceFirst('[dht]', '[dht]\n$line');
    }
    return '$toml\n[dht]\n$line\n';
  }

  static String withSessionKeepalive(String toml) {
    if (toml.contains('[session]')) return toml;
    return '$toml\n[session]\nkeepalive_interval_secs = 10\nidle_timeout_secs = 45\n';
  }

  /// Append `[transport.rotation]` to stretch the connection-rotation window to
  /// 6-12 h. veil's default rotates the transport every 30-60 min (DPI flow-
  /// duration jitter), which gracefully CLOSES the recipient's OVL1 session to
  /// its rendezvous relay; the relay drops the session-backed rendezvous
  /// subscriber on that close, so a sender's live introduce in the re-register
  /// gap black-holes (`cookie_unknown`) and delivery falls back to the slower
  /// ~14 s mailbox-drain path. A 6-12 h window makes rotations rarer than any
  /// delivery window while keeping SOME flow-duration jitter (preferred over a
  /// full `-1` disable). Either device can receive, so it is set unconditionally.
  /// Hot-reload re-applies it (`set_session_rotation_range`) — no native rebuild.
  /// Pure helper (no FFI), unit-testable.
  ///
  /// ⛔ This did nothing until 23.08. The guard was `if (toml.contains(
  /// '[transport.rotation]')) return toml`, and `veil_config_compose` renders
  /// that section with veil's own defaults — 1800/3600, the very numbers this
  /// helper exists to replace. So the section was always present, the helper
  /// always returned early, and the phone rotated every 30-60 min exactly as
  /// if the fix had never been written. Measured 23.08: sessions to one seed
  /// reopened at 37, 27 and 32 minute intervals.
  ///
  /// Replace the rendered values instead, the way `withBuiltinSeedPolicy`
  /// already does for the same reason. Appending is not an option — a second
  /// `[transport.rotation]` is a duplicate key the TOML parser rejects.
  static String withTransportRotation(String toml) {
    const min = 'min_lifetime_secs = 21600';
    const max = 'max_lifetime_secs = 43200';
    final renderedMin = RegExp(
      r'^[ \t]*min_lifetime_secs[ \t]*=.*$',
      multiLine: true,
    );
    final renderedMax = RegExp(
      r'^[ \t]*max_lifetime_secs[ \t]*=.*$',
      multiLine: true,
    );
    if (toml.contains('[transport.rotation]')) {
      var out = toml;
      out = renderedMin.hasMatch(out)
          ? out.replaceAll(renderedMin, min)
          : out.replaceFirst(
              '[transport.rotation]\n',
              '[transport.rotation]\n$min\n',
            );
      out = renderedMax.hasMatch(out)
          ? out.replaceAll(renderedMax, max)
          : out.replaceFirst(
              '[transport.rotation]\n',
              '[transport.rotation]\n$max\n',
            );
      return out;
    }
    return '$toml\n[transport.rotation]\n$min\n$max\n';
  }

  /// Merge outbound frames on the wire.
  ///
  /// Every frame costs framing and obfs4 padding whatever it carries, and on an
  /// idle phone that overhead is larger than the payload: measured 23.08 over
  /// 599 s on one seed link, 521 frames carrying 190 B/s of bodies cost 413 B/s
  /// on the wire — **260 bytes per frame**, about twice what each wrapped.
  /// Outbound frames cluster (30% of gaps under 50 ms), so replaying that
  /// capture through a 200 ms window merges 39% of them.
  ///
  /// `outbound_batch_always` is required: veil gates the window behind a LOW
  /// BATTERY reading, because it was built as a radio-wake saver. The saving
  /// here is bytes, and a charging phone pays the same 260 as a flat one.
  ///
  /// Interactive frames bypass the coalescer entirely, so liveness probes and
  /// backpressure are unaffected; only non-interactive frames wait, and at most
  /// one window.
  ///
  /// Replaces rendered values rather than skipping when the section exists —
  /// `[mobile]` IS rendered by `veil_config_compose`, which is exactly the trap
  /// that left `withTransportRotation` inert for as long as it existed.
  static String withOutboundCoalescing(String toml) {
    const window = 'outbound_batch_window_ms = 200';
    const always = 'outbound_batch_always = true';
    final renderedWindow = RegExp(
      r'^[ \t]*outbound_batch_window_ms[ \t]*=.*$',
      multiLine: true,
    );
    final renderedAlways = RegExp(
      r'^[ \t]*outbound_batch_always[ \t]*=.*$',
      multiLine: true,
    );
    const marker = '[mobile]\n';
    if (!toml.contains(marker)) {
      return '$toml\n[mobile]\n$window\n$always\n';
    }
    var out = toml;
    out = renderedWindow.hasMatch(out)
        ? out.replaceAll(renderedWindow, window)
        : out.replaceFirst(marker, '$marker$window\n');
    out = renderedAlways.hasMatch(out)
        ? out.replaceAll(renderedAlways, always)
        : out.replaceFirst(marker, '$marker$always\n');
    return out;
  }

  /// Append `[proxy.socks5]` / `[proxy.exit]` tables for traffic routing. The
  /// node runtime spawns these as services on boot AND re-spawns them on
  /// apply-config reload, so toggling routing needs no native rebuild — just a
  /// re-applied config carrying (or omitting) these sections. Pure helper (no
  /// FFI), so it is unit-testable. A SOCKS5 client role is only emitted with a
  /// valid exit ([ProxyRouting.socks5Active]); veil skips an exit-less SOCKS5.
  static String withProxy(String toml, ProxyRouting proxy) {
    if (!proxy.isActive || toml.contains('[proxy.')) return toml;
    final buf = StringBuffer(toml);
    final emittedListens = <String>{};
    if (proxy.socks5Active) {
      final exits = proxy.effectiveDefaultOproxyNodeIds;
      buf
        ..write('\n[proxy.socks5]\n')
        ..write('enabled = true\n')
        ..write('listen = "${proxy.socks5Listen}"\n')
        ..write('exit_node_id = "${exits.first}"\n')
        ..write('exit_node_ids = [${exits.map((id) => '"$id"').join(', ')}]\n');
      emittedListens.add(proxy.socks5Listen);
    }
    for (final profile in proxy.runtimeSocksProfiles) {
      final exits = profile.exitNodeIds
          .where(ProxyRouting.isValidNodeId)
          .toSet()
          .toList(growable: false);
      if (exits.isEmpty ||
          !ProxyRouting.isValidListen(profile.listen) ||
          !emittedListens.add(profile.listen)) {
        continue;
      }
      buf
        ..write('\n[[proxy.socks5_profiles]]\n')
        ..write('enabled = true\n')
        ..write('listen = "${profile.listen}"\n')
        ..write('exit_node_id = "${exits.first}"\n')
        ..write('exit_node_ids = [${exits.map((id) => '"$id"').join(', ')}]\n');
    }
    if (proxy.exitEnabled) {
      buf
        ..write('\n[proxy.exit]\n')
        ..write('enabled = true\n')
        ..write('allow_private = ${proxy.exitAllowPrivate}\n');
    }
    return buf.toString();
  }

  static String _composeConfigImpl({
    required String identityToml,
    required String listenTransport,
    required String ipcSocket,
    required String adminSocket,
    DynamicLibrary? lib,
    bool anonymous = false,
    bool lazyMining = false,
    List<BootstrapPeerCfg> bootstrapPeers = const [],
    List<String> udpReflectors = const [],
    String? obfs4PskFile,
    ProxyRouting proxy = ProxyRouting.disabled,
    bool useBundledSeeds = true,
    String? identityDir,
    bool? serveDht,
  }) {
    final dl = lib ?? _veilLib();
    final composeFn = dl.lookupFunction<_ComposeNative, _ComposeDart>(
      'veil_config_compose',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );

    // args[0] is the identity TOML — it carries the Ed25519 PRIVATE KEY. Both
    // the Dart copy below and the native buffer it is written into are wiped in
    // the finally (audit XV-22); see lib/core/secret_wipe.dart for exactly how
    // much that is worth on each side.
    final args = [
      identityToml,
      listenTransport,
      ipcSocket,
      adminSocket,
    ].map(utf8.encode).toList();
    final ptrs = <Pointer<Uint8>>[];
    final errOut = calloc<Pointer<Utf8>>();
    try {
      for (final bytes in args) {
        final p = calloc<Uint8>(bytes.length);
        p.asTypedList(bytes.length).setAll(0, bytes);
        ptrs.add(p);
      }
      final out = composeFn(
        ptrs[0],
        args[0].length,
        ptrs[1],
        args[1].length,
        ptrs[2],
        args[2].length,
        ptrs[3],
        args[3].length,
        errOut,
      );
      if (out == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_config_compose failed: $msg');
      }
      final toml = out.toDartString();
      freeStr(out);
      return withIdentityDir(
        withBuiltinSeedPolicy(
          withOutboundCoalescing(
            withTransportRotation(
              withSessionKeepalive(
                withObfs4PskFile(
                  withUdpReflectors(
                    withProxy(
                      withBootstrapPeers(
                        withMobileServiceBudget(
                          withDhtParticipation(
                            withClientNodeRole(
                              withLazyMining(
                                withAnonymity(toml, anonymous),
                                lazyMining,
                              ),
                            ),
                            // Platform default when the user has not chosen:
                            // phones serve nothing, desktops serve.
                            participate:
                                serveDht ??
                                !(Platform.isAndroid || Platform.isIOS),
                          ),
                          isMobile: Platform.isAndroid || Platform.isIOS,
                        ),
                        bootstrapPeers,
                      ),
                      proxy,
                    ),
                    udpReflectors,
                  ),
                  obfs4PskFile,
                ),
              ),
            ),
          ),
          useBundledSeeds,
        ),
        identityDir,
      );
    } finally {
      // Only ptrs[0]/args[0] hold a secret; the rest are socket paths. Wiping
      // all of them anyway costs nothing and removes the chance that a later
      // edit reorders the list and silently drops the key out of the wipe.
      for (var i = 0; i < ptrs.length; i++) {
        wipeNativeSecret(ptrs[i], args[i].length);
        calloc.free(ptrs[i]);
      }
      for (final a in args) {
        wipeSecretBytes(a);
      }
      calloc.free(errOut);
    }
  }

  /// Start a node from [configPath]. [lib] defaults to the in-process symbols
  /// (the preloaded libveilclient_ffi). Throws if start fails.
  static EmbeddedNode start(String configPath, {DynamicLibrary? lib}) {
    final dl = lib ?? _veilLib();
    final startFn = dl.lookupFunction<_StartNative, _StartDart>(
      'veil_node_start',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );

    final bytes = utf8.encode(configPath);
    final pathPtr = calloc<Uint8>(bytes.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      pathPtr.asTypedList(bytes.length).setAll(0, bytes);
      final handle = startFn(pathPtr, bytes.length, errOut);
      if (handle == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_node_start failed: $msg');
      }
      return EmbeddedNode._(handle, dl);
    } finally {
      calloc.free(pathPtr);
      calloc.free(errOut);
    }
  }

  /// Sign [message] with the Ed25519 identity in [identityToml] (the config the
  /// app holds in its deniable container). Stateless pure crypto — no running
  /// node needed. Returns the 64-byte signature + 32-byte public key; throws on
  /// failure (e.g. a non-Ed25519 identity or malformed TOML).
  static ({Uint8List signature, Uint8List publicKey}) signMessage(
    String identityToml,
    Uint8List message, {
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final signFn = dl.lookupFunction<_SignNative, _SignDart>(
      'veil_identity_sign',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final tomlBytes = utf8.encode(identityToml);
    final tomlPtr = calloc<Uint8>(tomlBytes.length);
    // from_raw_parts needs a non-null ptr even for len 0 — allocate at least 1.
    final msgPtr = calloc<Uint8>(message.isEmpty ? 1 : message.length);
    final sigOut = calloc<Uint8>(64);
    final pkOut = calloc<Uint8>(32);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      tomlPtr.asTypedList(tomlBytes.length).setAll(0, tomlBytes);
      if (message.isNotEmpty) {
        msgPtr.asTypedList(message.length).setAll(0, message);
      }
      final rc = signFn(
        tomlPtr,
        tomlBytes.length,
        msgPtr,
        message.length,
        sigOut,
        pkOut,
        errOut,
      );
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_identity_sign failed: $msg');
      }
      return (
        signature: Uint8List.fromList(sigOut.asTypedList(64)),
        publicKey: Uint8List.fromList(pkOut.asTypedList(32)),
      );
    } finally {
      // [identityToml] carries the Ed25519 private key, so the native copy of
      // it and the Dart bytes we built it from are zeroed before release
      // (audit XV-22). The signature and public key are public values.
      wipeNativeSecret(tomlPtr, tomlBytes.length);
      wipeSecretBytes(tomlBytes);
      calloc.free(tomlPtr);
      calloc.free(msgPtr);
      calloc.free(sigOut);
      calloc.free(pkOut);
      calloc.free(errOut);
    }
  }

  /// Does [document] authorise [publicKey] to speak for [nodeId]?
  ///
  /// The question a DEVICE's signature raises, which [verifyMessage] cannot
  /// answer: that one binds a key to an author by hash, which is right when the
  /// author signs with their own key and wrong for an identity with several
  /// devices — the author is the identity, the key is the device's, and the two
  /// hashes differ by construction.
  ///
  /// Asked as a question rather than by reading the document here: the master
  /// binding, the validity window and each device certificate are checked
  /// together on the native side, where they are already audited, so no caller
  /// can apply half of them. A revoked subkey answers false, because a document
  /// that no longer lists a key no longer speaks for it.
  static bool identityDocumentAuthorizes({
    required Uint8List document,
    required Uint8List nodeId,
    required Uint8List publicKey,
    DynamicLibrary? lib,
  }) {
    if (document.isEmpty || nodeId.length != 32 || publicKey.length != 32) {
      return false;
    }
    final dl = lib ?? _veilLib();
    final fn = dl.lookupFunction<_DocAuthorizesNative, _DocAuthorizesDart>(
      'veil_identity_document_authorizes',
    );
    final docPtr = calloc<Uint8>(document.length);
    final nidPtr = calloc<Uint8>(32);
    final pkPtr = calloc<Uint8>(32);
    try {
      docPtr.asTypedList(document.length).setAll(0, document);
      nidPtr.asTypedList(32).setAll(0, nodeId);
      pkPtr.asTypedList(32).setAll(0, publicKey);
      return fn(docPtr, document.length, nidPtr, pkPtr) == 0;
    } finally {
      calloc.free(docPtr);
      calloc.free(nidPtr);
      calloc.free(pkPtr);
    }
  }

  /// Verify [signature] over [message] by [publicKey], bound to [nodeId]
  /// (checks node_id == BLAKE3(publicKey) AND the Ed25519 signature). Returns
  /// true iff authentic. Stateless pure crypto.
  static bool verifyMessage({
    required Uint8List nodeId,
    required Uint8List publicKey,
    required Uint8List message,
    required Uint8List signature,
    DynamicLibrary? lib,
  }) {
    if (nodeId.length != 32 ||
        publicKey.length != 32 ||
        signature.length != 64) {
      return false;
    }
    final dl = lib ?? _veilLib();
    final verifyFn = dl.lookupFunction<_VerifyNative, _VerifyDart>(
      'veil_identity_verify',
    );
    final nidPtr = calloc<Uint8>(32);
    final pkPtr = calloc<Uint8>(32);
    final msgPtr = calloc<Uint8>(message.isEmpty ? 1 : message.length);
    final sigPtr = calloc<Uint8>(64);
    try {
      nidPtr.asTypedList(32).setAll(0, nodeId);
      pkPtr.asTypedList(32).setAll(0, publicKey);
      if (message.isNotEmpty) {
        msgPtr.asTypedList(message.length).setAll(0, message);
      }
      sigPtr.asTypedList(64).setAll(0, signature);
      final rc = verifyFn(nidPtr, pkPtr, msgPtr, message.length, sigPtr);
      return rc == 0; // 0 == VERIFY_VALID
    } finally {
      calloc.free(nidPtr);
      calloc.free(pkPtr);
      calloc.free(msgPtr);
      calloc.free(sigPtr);
    }
  }

  /// Start a node in deferred-init mode bound to [adminEndpoint] (an
  /// ephemeral, identity-free Unix path or authenticated loopback-TCP URI). It
  /// boots under a throwaway identity; call
  /// [applyConfig] with the real config to promote it — so the private key never
  /// touches a config file on disk.
  ///
  /// When [anonymous], `[anonymity]` is armed in the stub BOOT config so the
  /// node is actually onion-reachable once its real identity is applied. This
  /// must be set here, not via [applyConfig]: veil pins anonymity at boot and a
  /// later reload does not re-apply it. The published onion descriptor is sealed
  /// against the live identity, so it resolves to the real identity post-[applyConfig].
  static EmbeddedNode startDeferred(
    String adminEndpoint, {
    bool anonymous = false,
    DynamicLibrary? lib,
  }) {
    final dl = lib ?? _veilLib();
    final startFn = dl.lookupFunction<_StartDeferredNative, _StartDeferredDart>(
      'veil_node_start_deferred',
    );
    final freeStr = dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );

    final bytes = utf8.encode(adminEndpoint);
    final sockPtr = calloc<Uint8>(bytes.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      sockPtr.asTypedList(bytes.length).setAll(0, bytes);
      final handle = startFn(sockPtr, bytes.length, anonymous, errOut);
      if (handle == nullptr) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_node_start_deferred failed: $msg');
      }
      return EmbeddedNode._(handle, dl);
    } finally {
      calloc.free(sockPtr);
      calloc.free(errOut);
    }
  }

  /// Promote a deferred node to its real identity by applying [configToml]
  /// (e.g. the bytes from [mineConfig], loaded from the deniable container) over
  /// its admin socket, in memory. Throws if the apply fails.
  void applyConfig(String configToml) {
    // Ordering guard, no longer a memory-safety one. The native handle is an
    // opaque generational token now (report10 #1): a stop removes its table
    // entry, so a later call finds nothing rather than dereferencing freed
    // memory, and a stop landing mid-call cannot free the value under it.
    //
    // The check stays because refusing loudly here is still the right answer.
    // "the node handle is not live" from the other side of an FFI boundary
    // tells a person nothing about what they did; this names the mistake at
    // the layer that can see the intent.
    if (_stopped) {
      throw StateError(
        'applyConfig called after stop() — node handle is freed',
      );
    }
    final applyFn = _dl.lookupFunction<_ApplyConfigNative, _ApplyConfigDart>(
      'veil_node_apply_config',
    );
    final freeStr = _dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );

    final bytes = utf8.encode(configToml);
    final tomlPtr = calloc<Uint8>(bytes.length);
    final errOut = calloc<Pointer<Utf8>>();
    try {
      tomlPtr.asTypedList(bytes.length).setAll(0, bytes);
      final rc = applyFn(_handle, tomlPtr, bytes.length, errOut);
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_node_apply_config failed: $msg');
      }
    } finally {
      // The composed config embeds the identity section, private key and all —
      // this is the largest and longest-lived plaintext copy of it in the
      // process. Zero it before the allocator can hand the block on (XV-22).
      wipeNativeSecret(tomlPtr, bytes.length);
      wipeSecretBytes(bytes);
      calloc.free(tomlPtr);
      calloc.free(errOut);
    }
  }

  /// Tell the running node to re-read its identity document and republish.
  ///
  /// For the one change that is NOT a reconfiguration: linking a second device
  /// merges its key into `identity_document.bin`, and the node — which read that
  /// file when the config was applied — has to read it again. [applyConfig] with
  /// the same config does make it re-read, by stopping and restarting every
  /// service, and that drops every IPC connection the app holds: measured on a
  /// two-device stand, the link succeeded and every mailbox deposit after it
  /// failed with `connection closed` until the app was restarted.
  ///
  /// Throws if the node refuses — including when the document on disk names a
  /// different identity, which must never pass quietly.
  void reloadIdentity() {
    if (_stopped) {
      throw StateError(
        'reloadIdentity called after stop() — node handle is freed',
      );
    }
    final reloadFn = _dl
        .lookupFunction<_ReloadIdentityNative, _ReloadIdentityDart>(
          'veil_node_reload_identity',
        );
    final freeStr = _dl.lookupFunction<_FreeStrNative, _FreeStrDart>(
      'veil_free_string',
    );
    final errOut = calloc<Pointer<Utf8>>();
    try {
      final rc = reloadFn(_handle, errOut);
      if (rc != 0) {
        final err = errOut.value;
        final msg = err == nullptr ? 'unknown error' : err.toDartString();
        if (err != nullptr) freeStr(err);
        throw StateError('veil_node_reload_identity failed: $msg');
      }
    } finally {
      calloc.free(errOut);
    }
  }

  /// Stop the node. Returns whether its thread actually finished.
  ///
  /// `false` means the budget passed and the native side DETACHED the thread:
  /// the node may still hold its sockets and its network identity, and nothing
  /// can be retried — the handle is consumed either way, so a second call with
  /// the same pointer would be a double free (report9 X-17). The answer exists
  /// so a caller can stop saying "locked" when it is not.
  ///
  /// The bounded entry point is looked up rather than assumed. A build running
  /// against an older `libveilclient_ffi` has only the unbounded
  /// `veil_node_stop`, and looking up a symbol that library does not export
  /// fails at `dlsym` — a crash on the lock path, in exchange for a bound.
  bool stop({Duration budget = const Duration(seconds: 10)}) {
    if (_stopped) return true;
    _stopped = true;
    if (_dl.providesSymbol('veil_node_stop_timeout')) {
      final boundedStop = _dl
          .lookupFunction<_StopTimeoutNative, _StopTimeoutDart>(
            'veil_node_stop_timeout',
          );
      return boundedStop(_handle, budget.inMilliseconds) == 0;
    }
    // Older library: the unbounded join is all there is. It returns when the
    // node is down, so "finished" is the honest answer for this path.
    _dl.lookupFunction<_StopNative, _StopDart>('veil_node_stop')(_handle);
    return true;
  }
}

/// Create a resource, then finish setting it up — releasing it if the second
/// step throws.
///
/// The deniable boot is two FFI calls: `startDeferred` binds the admin socket
/// and starts the node thread, then `applyConfig` promotes the real identity.
/// Between them the node EXISTS and nothing else holds a reference to it, so a
/// throw from the second step stranded a running node — holding its admin
/// socket, its IPC socket and its listen port, with no handle left to stop it.
/// The next boot then failed on a taken port for a reason unrelated to why the
/// first one had not started (audit XV-03).
///
/// Ownership therefore never sits in the gap: whoever creates is responsible
/// until the value is returned, and [abandon] runs before the failure
/// propagates. Generic so it can be exercised without an FFI node.
T createThenPromote<T>({
  required T Function() create,
  required void Function(T) promote,
  required void Function(T) abandon,
}) {
  final resource = create();
  try {
    promote(resource);
  } catch (_) {
    // Best-effort: the promotion failure is what the caller needs to see, and
    // a throw from the cleanup would replace it with a less useful one.
    try {
      abandon(resource);
    } catch (_) {}
    rethrow;
  }
  return resource;
}

/// [NodeController] backed by the embedded in-process node — the production
/// path for sandboxed desktop and iOS (no `veil-cli` subprocess). Same
/// readiness contract as the subprocess controller (probe the app socket).
class EmbeddedNodeController implements NodeController {
  EmbeddedNodeController({
    this.configPath,
    required this.appSocketPath,
    this.lib,
    EmbeddedNode Function()? starter,
    this.readinessTimeout = const Duration(seconds: 25),
    this.pollInterval = const Duration(milliseconds: 300),
  }) : _starter = starter,
       assert(
         configPath != null || starter != null,
         'provide a configPath or a custom starter',
       );

  /// Config file to boot from (file mode). Null when a custom [_starter] is
  /// used — e.g. the deniable path that boots deferred + apply-config.
  final String? configPath;
  final String appSocketPath;
  final DynamicLibrary? lib;
  final Duration readinessTimeout;
  final Duration pollInterval;

  /// Produces a started [EmbeddedNode]. Defaults to a file-config boot; the
  /// deniable path passes a starter that does startDeferred + applyConfig.
  final EmbeddedNode Function()? _starter;

  final _status = StreamController<NodeStatus>.broadcast();
  NodeStatus _current = NodeStatus.stopped;
  EmbeddedNode? _node;

  @override
  NodeStatus get current => _current;
  @override
  Stream<NodeStatus> status() => _status.stream;

  void _emit(NodeStatus s) {
    _current = s;
    if (!_status.isClosed) _status.add(s);
  }

  @override
  Future<void> start() async {
    if (_current.phase == NodePhase.starting ||
        _current.phase == NodePhase.connected) {
      return;
    }
    _emit(const NodeStatus(phase: NodePhase.starting));

    final probe = veilSocketProbe(appSocketPath);
    if (await probe()) {
      _emit(const NodeStatus(phase: NodePhase.connected)); // already up
      return;
    }
    try {
      _node = (_starter ?? () => EmbeddedNode.start(configPath!, lib: lib))();
    } catch (e) {
      _emit(NodeStatus(phase: NodePhase.error, message: '$e'));
      return;
    }

    final deadline = DateTime.now().add(readinessTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await probe()) {
        _emit(const NodeStatus(phase: NodePhase.connected));
        return;
      }
      await Future<void>.delayed(pollInterval);
    }
    _emit(
      const NodeStatus(
        phase: NodePhase.error,
        message: 'embedded node did not become ready before timeout',
      ),
    );
  }

  @override
  Future<void> setEconomyMode(bool economy) async {
    // Background/economy tier is driven through the transport
    // (VeilClient.setBackgroundMode), not the node-control FFI.
  }

  /// True when the last [stop] left a node thread running behind it.
  ///
  /// The teardown that abandoned it cannot try again — see
  /// [EmbeddedNode.stop] — so this is what the app has instead: a fact it can
  /// report rather than a lock it can claim.
  bool get lastStopWasAbandoned => _lastStopAbandoned;
  bool _lastStopAbandoned = false;

  @override
  Future<void> stop() async {
    final node = _node;
    _node = null;
    if (node != null) {
      _lastStopAbandoned = !node.stop();
      if (_lastStopAbandoned) {
        devLog(
          () =>
              'xVeil[node]: stop did not finish in its budget — the thread was '
              'detached and the node may still hold its sockets',
        );
      }
    }
    _emit(NodeStatus.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }
}
