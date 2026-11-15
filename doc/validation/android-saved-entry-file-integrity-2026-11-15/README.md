# Android saved-entry backing-file integrity

## Confirmed mechanism

Android's SharedPreferences loader can replace an unreadable or malformed XML
file with an empty in-memory map without reporting failure to `contains`.
It can also restore a backup before loading. Consequently, the
[raw-record port](../android-saved-entry-records-2026-11-15/README.md) could
incorrectly treat damaged storage as absence. Editing a previously cached empty
map could then overwrite a readable file containing sibling records.

This was reproduced on an isolated AOSP Android 15 emulator. After a real plugin
write and process death, the fixture removed only the closing XML map tag,
preserving the encrypted entries. The unguarded native channel reported absence
while the nonempty malformed file remained unchanged. This establishes a local
failure mechanism, not the cause of a historical user incident.

## Change

The native presence/removal adapter validates the fixed private data file before
opening SharedPreferences. A bounded, complete XML parse checks its pinned
string-record layout, unique names and known plugin bookkeeping. Malformed or
unsupported content, unreadable files, symlinks, backups and observable file
replacement refuse verification. Only an absent file is accepted as an empty
store; inaccessible storage never takes that branch.

After framework loading, the entire cached string map must match the disk map,
including sibling values and bookkeeping. A second disk snapshot must agree.
Checking only the selected key is insufficient when both copies lack that key
but the disk still contains a sibling. The adapter refuses a mismatching cache
before editing it. Explicit removal still commits only the selected record and
checks absence through the same validated adapter.

Errors use the bounded `record_store_unreadable` code. Paths, XML, credential
names and platform exception text are not returned through this error. No
repair, reset, cipher initialization or key generation is performed by these
raw operations. Cipher policy and the authenticated-read prompt are unchanged.

## Evidence

The final isolated APK passed 64 fresh-process phases on API 35:

| Scenario | Independent cycles | Phases | Result |
| --- | ---: | ---: | --- |
| Ordinary namespace; remove synthetic Keystore key, inspect and delete record | 5 | 25 | Passed |
| Strong-biometric namespace; same removed-key sequence | 5 | 25 | Passed |
| Malformed data file; refuse presence and removal, preserve exact bytes | 2 | 8 | Passed |
| Stale empty framework cache; refuse removal and preserve disk sibling | 2 | 6 | Passed |

Each phase ends with SIGKILL of the verified foreground QA process. Each next
phase has a new PID. Independent removed-key scenarios reinstall only the fixed
QA package because deleting a key also invalidates its wrapping metadata.
Raw phases verify the synthetic alias remains absent and receive no fingerprint
events. Protected setup uses the actual strong-biometric AndroidKeyStore policy
and an enrolled virtual fingerprint.

The probe now transports StandardMethodCodec messages to the actual
`NativeQuickUnlock` handler. Android preferences, native parsing, Keystore,
plugin encryption and commits are real. The messenger supplies no method
results; Flutter/Dart UI and a running FlutterEngine are outside this probe.
All four series use one APK with matching local/installed SHA-256 values.
It compiles 22 actual app Kotlin sources, seven SDK Kotlin sources and 24
selected flutter_secure_storage 10.3.4 Java sources, plus the test Activity.
Source inventories and raw output are retained privately.

Host checks cover valid/empty/missing files, decoded numeric/predefined entities,
plugin bookkeeping, duplicate/nested/unknown entries, truncation, DTDs, backups,
symlinks and full-cache disagreement without mutation. Three compiled host
mutants fail behaviorally: empty-on-error, ignore-backup and ignore-cache.
An unguarded Android control also fails both the malformed-file and stale-cache
preservation probes with ordinary failed reports, rather than a crash/timeout.

178 checks pass across 14 serial Flutter suites. Native managed-identity payloads
remain byte-identical when OS-record verification refuses removal; an explicitly
recovered adapter can later complete erasure. Dart analysis is clean. Sources
and the four pinned host native-library digests were frozen around qualification.
No Rust or media engine was rebuilt.

An initial guard rejected Tink bookkeeping that the selected plugin also creates
in its ordinary layout. A separate harness attempt used the wrong ordinary RSA
alias, and an earlier request identifier contained an unsupported underscore.
Those attempts are excluded from the final result. The guard now admits the
observed bookkeeping while refusing unknown opaque credential names.

## Limits

These checks qualify the raw presence/removal boundary, not every plugin
initialization/read/write path. They do not repair corrupt preferences, establish
hardware security, inject physical disk failure or qualify an OEM phone. A
failed framework commit may leave RAM and disk different; verification then
refuses until their consistency is explicitly restored, potentially by restart.
The file checks are observations inside the application's private directory,
not a transaction against arbitrary concurrent external file replacement.

Full cold-start application erasure recovery, scope discovery, independent media
shutdown and the remaining managed-storage activation work are still unfinished.
The three requested storage modes are not enabled by this change. Managed
storage remains disabled. User applications and containers were untouched;
there is no push or release.

All QA installations were stopped and uninstalled. The owned emulator exited,
and its private SDK/image/AVD were removed, reclaiming approximately 2.4 GiB.
The shared ADB server, host SDK packages and user AVDs were left intact.
