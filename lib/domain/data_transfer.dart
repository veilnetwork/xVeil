// Offline transfer of everything this identity holds: the archive format.
//
// Two shapes of the same archive, chosen by the person exporting:
//
//   * OPEN — the body is written as it stands. Readable with `head`, which is
//     the point: a person moving their own data should be able to see what
//     they are moving.
//   * SEALED — the body is encrypted under a password. The header stays
//     readable either way (a reader must be able to say "this needs a
//     password" without one), and is bound into the encryption as associated
//     data, so editing it — flipping `keys`, forging a fingerprint, lying
//     about the counts — breaks every chunk that follows.
//
// The body is a stream of records, never a document: an archive with a
// hundred thousand messages and a gigabyte of attachments is written and read
// a chunk at a time. Holding the whole of it in memory is what XV-08 was, and
// on a phone it is not a slowdown but a kill.
//
// ## Layout
//
//   XVEILBK1\n                    magic, so a wrong file is refused by its
//                                 first eight bytes rather than by a parser
//                                 error somewhere in the middle
//   {header json}\n               ALWAYS plaintext, ALWAYS one line
//   <body>                        records, sealed in chunks when the header
//                                 says the body is sealed
//
// A record is a header line and an optional payload whose length that line
// declares:
//
//   {"k":"file","id":"…","n":1234}\n
//   <1234 raw bytes>
//
// The last record is `{"k":"end"}`, INSIDE the sealed body. Without it a
// truncated archive would look complete: chunks are independently sealed, so
// cutting the file short removes data without breaking any tag that remains.
// The end marker is what makes "the file stops here" different from "the file
// was cut here".

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// First line of every archive. The digit is the format generation: a reader
/// that does not know it refuses the file whole rather than guessing.
const String kDataTransferMagic = 'XVEILBK1';

/// Plaintext bytes per sealed chunk (1 MiB).
///
/// Big enough that the per-chunk overhead (16-byte tag + 4-byte length) is
/// noise, small enough that a phone holds one chunk, not one archive.
const int kTransferChunkBytes = 1 << 20;

/// Argon2id cost for the password-sealed archive.
///
/// The expensive end of what a phone will tolerate for a once-per-transfer
/// operation: this password protects a file that may sit in somebody's cloud
/// drive for years, where an attacker grinds offline for as long as they like.
///
/// Measured, not guessed (2026-09-08, this project's Mac, the pure-Dart
/// implementation the app actually ships — there is no native provider
/// registered): 8 MiB/t1 = 49 ms, 32 MiB/t2 = 66 ms, 64 MiB/t3 = 175 ms,
/// 128 MiB/t3 = 363 ms. 128 MiB is chosen over 256 because the cost of the
/// step is not the only cost: a mid-range phone has to ALLOCATE it, and an
/// export that dies for want of memory protects nothing at all.
///
/// The implementation was checked against the reference vector (argon2id,
/// v=19, m=65536, t=2, p=1, "password"/"somesalt") before these numbers were
/// trusted — a fast KDF and a wrong KDF look identical from the outside.
const int kTransferKdfMemoryKib = 128 * 1024;
const int kTransferKdfIterations = 3;
const int kTransferKdfParallelism = 4;
const int kTransferKdfSaltBytes = 16;

/// What a record in the body is.
enum TransferRecordKind {
  /// A [DeviceSyncEvent] body, verbatim. Everything that has to MERGE rather
  /// than overwrite travels as one of these, so the offline merge and the
  /// over-the-network merge are the same code deciding the same way.
  sync,

  /// The node identity — this is the part that makes a fresh install become
  /// this device. Present only when the exporter chose to include it.
  identity,

  /// The owner's own profile record.
  profile,

  /// A settings value the device-group sync does NOT carry.
  ///
  /// Its allowlist is narrow by design — a window size or a file path belongs
  /// to one machine. But identity-level state lives in the same namespace (a
  /// claimed nickname, for one), and dropping it would lose it silently. So it
  /// travels, and the importer FILLS A GAP with it rather than overwriting:
  /// an archive does not get to decide that this device's value was wrong.
  setting,

  /// One stored file's bytes.
  file,

  /// End of the body. See the note at the top of this file.
  end;

  static TransferRecordKind? fromName(String? name) {
    for (final k in TransferRecordKind.values) {
      if (k.name == name) return k;
    }
    return null;
  }
}

/// One record: what it is, what it says, and (optionally) its bytes.
class TransferRecord {
  const TransferRecord({
    required this.kind,
    this.meta = const {},
    this.payload,
  });

  final TransferRecordKind kind;
  final Map<String, dynamic> meta;
  final Uint8List? payload;

  int get payloadLength => payload?.length ?? 0;
}

/// How the body is protected, and with what parameters.
///
/// Kept as data rather than as constants so an archive written by an older
/// build still says how to open it. Constants would make yesterday's archive
/// unreadable the day the cost is raised.
class TransferSeal {
  const TransferSeal({
    required this.salt,
    required this.memoryKib,
    required this.iterations,
    required this.parallelism,
    required this.chunkBytes,
  });

  final Uint8List salt;
  final int memoryKib;
  final int iterations;
  final int parallelism;
  final int chunkBytes;

  Map<String, dynamic> toJson() => {
    'alg': 'chacha20-poly1305',
    'kdf': 'argon2id',
    'salt': base64.encode(salt),
    'm': memoryKib,
    't': iterations,
    'p': parallelism,
    'chunk': chunkBytes,
  };

  static TransferSeal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final salt = raw['salt'];
    final m = raw['m'], t = raw['t'], p = raw['p'], chunk = raw['chunk'];
    if (raw['alg'] != 'chacha20-poly1305' || raw['kdf'] != 'argon2id') {
      return null;
    }
    if (salt is! String || m is! int || t is! int || p is! int || chunk is! int) {
      return null;
    }
    if (m <= 0 || t <= 0 || p <= 0 || chunk <= 0) return null;
    final saltBytes = Uint8List.fromList(base64.decode(salt));
    if (saltBytes.isEmpty) return null;
    return TransferSeal(
      salt: saltBytes,
      memoryKib: m,
      iterations: t,
      parallelism: p,
      chunkBytes: chunk,
    );
  }
}

/// The readable head of an archive: who it belongs to, what is inside, and
/// whether a password is needed.
///
/// Everything here is readable WITHOUT the password on purpose — an importer
/// has to be able to say "this belongs to a different identity" or "this needs
/// a password" before asking for one. Nothing secret goes in here; the
/// fingerprint is a public node id.
class TransferHeader {
  const TransferHeader({
    required this.createdMs,
    required this.nodeIdHex,
    required this.includesIdentity,
    required this.includesFiles,
    this.label,
    this.counts = const {},
    this.fileBytes = 0,
    this.seal,
  });

  final int createdMs;

  /// The identity this archive came from, as its public node id. An import
  /// into a different identity is refused on this, before anything is read.
  final String nodeIdHex;

  final String? label;
  final bool includesIdentity;
  final bool includesFiles;

  /// Per-kind record counts, for the preview shown before an import runs.
  final Map<String, int> counts;

  /// Total bytes of file payloads, so the preview can say how big this is.
  final int fileBytes;

  /// Null when the body is open.
  final TransferSeal? seal;

  bool get isSealed => seal != null;

  Map<String, dynamic> toJson() => {
    'v': 1,
    'created': createdMs,
    'node': nodeIdHex,
    if (label != null) 'label': label,
    'keys': includesIdentity,
    'files': includesFiles,
    'counts': counts,
    'fileBytes': fileBytes,
    if (seal != null) 'seal': seal!.toJson(),
  };

  static TransferHeader? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != 1) return null;
    final created = raw['created'], node = raw['node'];
    if (created is! int || node is! String || node.isEmpty) return null;
    final counts = <String, int>{};
    final rawCounts = raw['counts'];
    if (rawCounts is Map) {
      rawCounts.forEach((k, v) {
        if (k is String && v is int) counts[k] = v;
      });
    }
    final sealRaw = raw['seal'];
    final seal = sealRaw == null ? null : TransferSeal.fromJson(sealRaw);
    // A `seal` that is present but unreadable must not degrade into "open":
    // that would hand the caller a body it cannot parse and call it plaintext.
    if (sealRaw != null && seal == null) return null;
    final fileBytes = raw['fileBytes'];
    return TransferHeader(
      createdMs: created,
      nodeIdHex: node,
      label: raw['label'] is String ? raw['label'] as String : null,
      includesIdentity: raw['keys'] == true,
      includesFiles: raw['files'] == true,
      counts: counts,
      fileBytes: fileBytes is int ? fileBytes : 0,
      seal: seal,
    );
  }
}

/// Why an archive could not be read.
///
/// Separate causes rather than one message, because the caller acts on them
/// differently: a wrong password is worth asking again, a wrong file is not,
/// and a truncated archive means "you have half a file", which the person
/// needs to hear in those words.
enum TransferFailure { notAnArchive, unsupportedVersion, badPassword, truncated, corrupt }

class TransferException implements Exception {
  const TransferException(this.failure, [this.detail]);
  final TransferFailure failure;
  final String? detail;

  @override
  String toString() =>
      'TransferException(${failure.name}${detail == null ? '' : ': $detail'})';
}

final Chacha20 _aead = Chacha20.poly1305Aead();

/// Derive the body key from a password, with the parameters the archive
/// itself declares.
Future<SecretKey> deriveTransferKey(String password, TransferSeal seal) async {
  final kdf = Argon2id(
    memory: seal.memoryKib,
    iterations: seal.iterations,
    parallelism: seal.parallelism,
    hashLength: 32,
  );
  return kdf.deriveKey(
    secretKey: SecretKey(utf8.encode(password)),
    nonce: seal.salt,
  );
}

/// 12-byte nonce from the chunk index.
///
/// Unique per chunk under a key derived from a fresh random salt, so no reuse.
/// It also pins ORDER: a chunk moved to another position decrypts under the
/// wrong nonce and fails its tag rather than being silently accepted.
Uint8List _chunkNonce(int index) {
  final n = Uint8List(12);
  var x = index;
  for (var i = 0; i < 8 && x != 0; i++) {
    n[i] = x & 0xff;
    x >>= 8;
  }
  return n;
}

/// Writes an archive to [sink].
///
/// [sink] is a function rather than an `IOSink` so the tests can collect bytes
/// in memory and the app can hand it a file, without either of them knowing
/// about the other.
class DataTransferWriter {
  DataTransferWriter._(this._sink, this._headerBytes, this._key, this._seal);

  final Future<void> Function(List<int> bytes) _sink;
  final Uint8List _headerBytes;
  final SecretKey? _key;
  final TransferSeal? _seal;

  final BytesBuilder _pending = BytesBuilder(copy: false);
  int _chunkIndex = 0;
  bool _closed = false;

  /// Start an archive: writes the magic and the header, and derives the body
  /// key when [password] is given.
  /// [cost] overrides the KDF parameters. It exists for the tests, which would
  /// otherwise pay the real cost for every archive they write; the archive
  /// carries whatever was used, so a cheap one still opens.
  static Future<DataTransferWriter> open({
    required Future<void> Function(List<int> bytes) sink,
    required TransferHeader header,
    String? password,
    TransferSeal? cost,
    Uint8List? saltForTest,
  }) async {
    TransferSeal? seal;
    SecretKey? key;
    if (password != null) {
      final salt = saltForTest ?? cost?.salt ?? _randomBytes(kTransferKdfSaltBytes);
      seal = TransferSeal(
        salt: salt,
        memoryKib: cost?.memoryKib ?? kTransferKdfMemoryKib,
        iterations: cost?.iterations ?? kTransferKdfIterations,
        parallelism: cost?.parallelism ?? kTransferKdfParallelism,
        chunkBytes: cost?.chunkBytes ?? kTransferChunkBytes,
      );
      key = await deriveTransferKey(password, seal);
    }
    final sealed = TransferHeader(
      createdMs: header.createdMs,
      nodeIdHex: header.nodeIdHex,
      label: header.label,
      includesIdentity: header.includesIdentity,
      includesFiles: header.includesFiles,
      counts: header.counts,
      fileBytes: header.fileBytes,
      seal: seal,
    );
    final headerLine = jsonEncode(sealed.toJson());
    final headerBytes = Uint8List.fromList(utf8.encode(headerLine));
    await sink(utf8.encode('$kDataTransferMagic\n'));
    await sink(headerBytes);
    await sink(const [0x0a]);
    return DataTransferWriter._(sink, headerBytes, key, seal);
  }

  /// Append one record.
  Future<void> add(TransferRecord record) async {
    if (_closed) {
      throw StateError('the archive is closed');
    }
    final meta = <String, dynamic>{'k': record.kind.name, ...record.meta};
    if (record.payloadLength > 0) meta['n'] = record.payloadLength;
    await _body(utf8.encode('${jsonEncode(meta)}\n'));
    final payload = record.payload;
    if (payload != null && payload.isNotEmpty) await _body(payload);
  }

  /// Append a record whose payload is STREAMED, never held.
  ///
  /// [length] is declared in the record header before a byte of the payload is
  /// written, which is what lets the reader skip a record it does not
  /// understand — so it has to be right. A stream that delivers a different
  /// number of bytes than it promised leaves an archive whose records no
  /// longer line up, and that is worth failing the export over rather than
  /// writing a file that reads as damaged later.
  Future<void> addStreamed({
    required TransferRecordKind kind,
    required int length,
    required Stream<List<int>> payload,
    Map<String, dynamic> meta = const {},
  }) async {
    if (_closed) {
      throw StateError('the archive is closed');
    }
    final head = <String, dynamic>{'k': kind.name, ...meta};
    if (length > 0) head['n'] = length;
    await _body(utf8.encode('${jsonEncode(head)}\n'));
    var written = 0;
    await for (final chunk in payload) {
      written += chunk.length;
      if (written > length) {
        throw StateError(
          'record payload is longer than the $length bytes it declared',
        );
      }
      await _body(chunk);
    }
    if (written != length) {
      throw StateError(
        'record payload declared $length bytes and delivered $written',
      );
    }
  }

  /// Write the end marker and flush what is left.
  Future<void> close() async {
    if (_closed) return;
    await add(const TransferRecord(kind: TransferRecordKind.end));
    _closed = true;
    await _flush(force: true);
  }

  Future<void> _body(List<int> bytes) async {
    if (_key == null) {
      await _sink(bytes);
      return;
    }
    _pending.add(bytes);
    await _flush();
  }

  Future<void> _flush({bool force = false}) async {
    final key = _key;
    final seal = _seal;
    if (key == null || seal == null) return;
    while (_pending.length >= seal.chunkBytes ||
        (force && _pending.length > 0)) {
      final all = _pending.takeBytes();
      final take = all.length < seal.chunkBytes ? all.length : seal.chunkBytes;
      final chunk = Uint8List.sublistView(all, 0, take);
      if (take < all.length) {
        _pending.add(Uint8List.sublistView(all, take));
      }
      final box = await _aead.encrypt(
        chunk,
        secretKey: key,
        nonce: _chunkNonce(_chunkIndex),
        aad: _headerBytes,
      );
      _chunkIndex++;
      final sealedLen = box.cipherText.length + box.mac.bytes.length;
      final frame = Uint8List(4)
        ..buffer.asByteData().setUint32(0, sealedLen, Endian.little);
      await _sink(frame);
      await _sink(box.cipherText);
      await _sink(box.mac.bytes);
      if (!force) break;
    }
  }
}

/// Reads an archive from a byte stream.
///
/// Two steps on purpose: [readHeader] first, so the caller can look at the
/// archive — whose it is, what is in it, whether it is sealed — and decide
/// whether to ask for a password at all; then [records], which needs the
/// password only if the header said so.
class DataTransferReader {
  DataTransferReader._(this._feed, this.header, this._headerBytes);

  final _ByteFeed _feed;
  final TransferHeader header;
  final Uint8List _headerBytes;

  static Future<DataTransferReader> open(Stream<List<int>> bytes) async {
    final feed = _ByteFeed(bytes);
    final magic = await feed.line();
    if (magic == null) {
      throw const TransferException(TransferFailure.notAnArchive, 'empty file');
    }
    if (magic != kDataTransferMagic) {
      // A file from a LATER generation says so by its magic; anything else is
      // simply not one of ours, and the two deserve different words.
      if (magic.startsWith('XVEILBK')) {
        throw const TransferException(TransferFailure.unsupportedVersion);
      }
      throw const TransferException(TransferFailure.notAnArchive);
    }
    final headerLine = await feed.line();
    if (headerLine == null) {
      throw const TransferException(TransferFailure.truncated, 'no header');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(headerLine);
    } catch (_) {
      throw const TransferException(TransferFailure.corrupt, 'header');
    }
    final header = TransferHeader.fromJson(decoded);
    if (header == null) {
      throw const TransferException(TransferFailure.unsupportedVersion);
    }
    return DataTransferReader._(
      feed,
      header,
      Uint8List.fromList(utf8.encode(headerLine)),
    );
  }

  /// The records, in the order they were written.
  ///
  /// Throws [TransferException] with [TransferFailure.badPassword] when the
  /// first chunk will not open — which is the honest reading: the header is
  /// authenticated as associated data, so a failure here means either the
  /// password is wrong or somebody edited the header.
  Stream<TransferRecord> records({String? password}) async* {
    final seal = header.seal;
    _ByteFeed body = _feed;
    if (seal != null) {
      if (password == null) {
        throw const TransferException(TransferFailure.badPassword, 'sealed');
      }
      final key = await deriveTransferKey(password, seal);
      body = _ByteFeed(_unsealed(_feed, key, seal));
    }
    var sawEnd = false;
    while (true) {
      final line = await body.line();
      if (line == null) break;
      if (line.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        throw const TransferException(TransferFailure.corrupt, 'record header');
      }
      if (decoded is! Map) {
        throw const TransferException(TransferFailure.corrupt, 'record header');
      }
      final kind = TransferRecordKind.fromName(decoded['k'] as String?);
      final n = decoded['n'];
      final length = n is int && n > 0 ? n : 0;
      final payload = length == 0 ? null : await body.take(length);
      if (length > 0 && payload == null) {
        throw const TransferException(TransferFailure.truncated, 'payload');
      }
      if (kind == TransferRecordKind.end) {
        sawEnd = true;
        break;
      }
      // An unknown kind is skipped, not fatal: an archive from a later build
      // should still give up everything this one understands. Its payload was
      // consumed above, so the stream stays aligned.
      if (kind == null) continue;
      final meta = <String, dynamic>{};
      decoded.forEach((k, v) {
        if (k is String && k != 'k' && k != 'n') meta[k] = v;
      });
      yield TransferRecord(kind: kind, meta: meta, payload: payload);
    }
    if (!sawEnd) {
      throw const TransferException(TransferFailure.truncated, 'no end marker');
    }
  }

  Stream<List<int>> _unsealed(
    _ByteFeed feed,
    SecretKey key,
    TransferSeal seal,
  ) async* {
    var index = 0;
    while (true) {
      final frame = await feed.take(4);
      if (frame == null) return;
      final sealedLen = ByteData.sublistView(frame).getUint32(0, Endian.little);
      if (sealedLen < 16) {
        throw const TransferException(TransferFailure.corrupt, 'chunk length');
      }
      final sealed = await feed.take(sealedLen);
      if (sealed == null) {
        throw const TransferException(TransferFailure.truncated, 'chunk');
      }
      final cipher = Uint8List.sublistView(sealed, 0, sealedLen - 16);
      final mac = Mac(Uint8List.sublistView(sealed, sealedLen - 16));
      try {
        final plain = await _aead.decrypt(
          SecretBox(cipher, nonce: _chunkNonce(index), mac: mac),
          secretKey: key,
          aad: _headerBytes,
        );
        yield plain;
      } on SecretBoxAuthenticationError {
        // The first chunk failing is overwhelmingly "wrong password"; a later
        // one cannot be, since the key already opened everything before it —
        // that is damage, and saying "wrong password" there would send the
        // person to type a password that was right all along.
        throw TransferException(
          index == 0 ? TransferFailure.badPassword : TransferFailure.corrupt,
          index == 0 ? null : 'chunk $index',
        );
      }
      index++;
    }
  }
}

/// Incremental reader over a byte stream: give me a line, give me N bytes.
class _ByteFeed {
  _ByteFeed(Stream<List<int>> source) : _it = StreamIterator(source);

  final StreamIterator<List<int>> _it;
  final BytesBuilder _buf = BytesBuilder(copy: false);
  Uint8List _held = Uint8List(0);
  bool _done = false;

  Uint8List get _bytes {
    if (_buf.length > 0) {
      final more = _buf.takeBytes();
      final joined = Uint8List(_held.length + more.length)
        ..setRange(0, _held.length, _held)
        ..setRange(_held.length, _held.length + more.length, more);
      _held = joined;
    }
    return _held;
  }

  Future<bool> _pull() async {
    if (_done) return false;
    if (!await _it.moveNext()) {
      _done = true;
      return false;
    }
    _buf.add(_it.current);
    return true;
  }

  /// Up to the next `\n`, decoded as UTF-8; null at end of stream.
  Future<String?> line() async {
    while (true) {
      final b = _bytes;
      final nl = b.indexOf(0x0a);
      if (nl >= 0) {
        final out = utf8.decode(Uint8List.sublistView(b, 0, nl));
        _held = Uint8List.sublistView(b, nl + 1);
        return out;
      }
      if (!await _pull()) {
        if (_bytes.isEmpty) return null;
        // A last line without its newline is still a line; refusing it would
        // turn a file some tool trimmed into "not an archive".
        final out = utf8.decode(_bytes);
        _held = Uint8List(0);
        return out;
      }
    }
  }

  /// Exactly [n] bytes; null when the stream ends first.
  Future<Uint8List?> take(int n) async {
    while (_bytes.length < n) {
      if (!await _pull()) return null;
    }
    final b = _bytes;
    final out = Uint8List.fromList(Uint8List.sublistView(b, 0, n));
    _held = Uint8List.sublistView(b, n);
    return out;
  }
}

Uint8List _randomBytes(int n) {
  final rnd = SecretKeyData.random(length: n);
  return Uint8List.fromList(rnd.bytes);
}
