# Read-only Android saved-entry metadata

## Confirmed mechanism

The selected flutter_secure_storage 10.3.4 initializes its cipher before an
ordinary `read`. Its factory can write missing algorithm markers, and its key
constructors can generate replacement wrapping/application keys. Consequently,
opening quick-unlock options was not purely observational, including when the
requested public metadata record was absent. A separate preflight followed by
that initializer would still leave a generation window between check and use.
This is a verified integration mechanism, not attribution of a user incident.

## Change

Android non-biometric saved-entry reads now use `readPublic` on the existing
private native channel. The handler is serialized with accepted record removal
and persistence work and drains accepted operations on disposal. Other platforms
retain their existing readers. Biometric authentication and enrollment remain
on their existing paths.

The reader opens only fixed private namespace files through the existing bounded
XML/file-integrity guard. An absent record returns null without opening cipher
configuration, wrapped keys or Keystore. An existing record requires the pinned
RSA-OAEP/SHA-256 plus MGF1/SHA-1 wrapping policy, AES-GCM markers and an existing
wrapped application key. Native wiring retrieves an existing private Keystore
key directly. It never constructs a plugin cipher/factory or SharedPreferences
owner, generates keys, repairs XML, writes markers, resets or migrates storage.

Decryption uses the same pinned GCM format and strict UTF-8 decoding. File
snapshots must still agree after decryption. Malformed files, backups, missing
key material, an unsupported format, authentication failure or observable
replacement refuse the read. They do not become an empty record or trigger a
fallback initializer. Native error replies contain bounded codes and fixed text,
not paths, record values or platform exception messages. Temporary plaintext and
wrapped-key byte arrays are cleared; no new decrypted-key cache is introduced.

## Evidence

- Seven new Flutter checks cover existing/absent records without the plugin,
  missing bridge, unreadable storage, pending native replies, and unchanged
  macOS/Windows delegation. The former implementation fails both selected
  existing/absent controls behaviorally; exact source restoration passes.
- Kotlin/JVM tests exercise actual XML files and RSA-OAEP/AES-GCM operations,
  including Unicode, repeated reads, missing/corrupt configuration and keys,
  unavailable unwrap, altered ciphertext, backups, mutation during unwrap,
  invalid keys and exact file preservation. The preceding backing-file guard
  tests also pass after its small exact-name extension for wrapped-key files.
- An independent private interoperability harness compiles the selected plugin's
  actual `StorageCipherImplementationGCM`, `StorageCipher` and `KeyCipher`
  sources. Its encrypted ASCII, Unicode and 32-KiB fixtures all decrypt through
  the application reader. Only Android preference/Base64/context adapters are
  controlled on the JVM; plugin encryption and JCE cryptography are real.
- Android compilation recompiles all 23 application Kotlin, seven SDK Kotlin
  and 24 selected plugin Java sources. The resulting isolated QA APK and source
  inventories have recorded digests. No Rust or media engine is rebuilt.
- The final 28-suite serial Flutter run passes 358 checks, including enrollment,
  one-prompt authentication routing, erasure, crash recovery and ordinary startup.
  Sources and four pinned host native-library hashes stay unchanged throughout.
  Focused Dart analysis is clean.

## Limits and next work

No Android device is currently available through ADB. Compilation/JVM/channel
qualification is not a device, OEM or hardware-Keystore qualification. The
reader deliberately does not migrate unsupported historical layouts or repair
damaged quick-unlock records. Explicit enrollment still uses the selected
plugin's writer and its confirmed persistence barrier; this change does not
claim all plugin initialization paths are observational.

Packaged platform smoke, native-library provenance and storage activation remain
before enabling the three storage modes by default. No user credential store,
container or installed application was accessed. No push or release was made.
