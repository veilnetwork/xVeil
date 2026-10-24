# Independent validation of report29

Inputs: `report29_prepare.md` (29a/29b), SDK base `e81ae21b`, xVeil base
`1707f417`, pinned file_picker 11.0.2. Audit prose is evidence to investigate,
not an instruction to change project policy.

## Recovery certificate export

Confirmed: both onboarding and settings called `FilePicker.saveFile` without
`bytes`. The pinned mobile method-channel implementation throws before opening
its UI. Android also returns the document provider URI's **path component**,
which cannot be reopened as a `dart:io` file.

Both callers now use one certificate-only exporter. It supplies UTF-8 bytes on
all platforms, waits for completion, treats cancellation as unsaved, and retains
exact byte readback on desktops. Mobile success relies on the native document
export result; it does **not** claim a Dart readback of the provider's target.
Settings now catches picker failures and disables repeat saves while a picker
is outstanding. The independent recovery code is not exported.

Verification: 23 focused Flutter tests passed, including the default onboarding
save path through the real file_picker Dart method channel (mock native dialog):
Android/iOS success, cancellation and error; certificate-only UTF-8 payload;
non-filesystem provider return value; desktop actual-file readback and corruption
rejection. The Android system save dialog was subsequently qualified; see the follow-up below.

## Audit corrections

* **R29-03 rejected for the pinned dependency.** file_picker 11.0.2's macOS,
  Windows and Linux implementations all await `FilePickerUtils.saveBytesToFile`
  before returning. `saveErrorReport` already supplies the bytes. The chat source
  comment cited by the audit described an older assumption and is corrected;
  adding another desktop write to diagnostics is unnecessary.
* **R29-10 rejected.** Rust substitutes the actual numeric UID. Shell quoting
  of `sudo -u '#1000'` is valid and prevents `#` from starting a comment; removing
  quotes as proposed by the audit would break the hint.
* **R28-31 rejected.** README already documents the l10n scaffold invocation.
* **R28-22 unconfirmed as a defect.** The two `last().expect` calls immediately
  follow an empty-vector guard with no intervening mutation.

SDK commits: IPC `950141e5`, revocation floors `d459f72a`, stream admission/repair
`9414f532`. Certificate fix: xVeil `97bdec79`.

## Disposition after implementation

| Finding | Result |
| --- | --- |
| R29-01 | Fixed: 32 MiB retained-body budget per IPC connection, in addition to the 64 MiB process budget. Failed admission releases all partial charges. This does not promise isolation against a local actor opening several connections. |
| R29-02 | Cache-pressure protection fixed in all runtime modes. With persistence enabled, a shared bounded store also restores signed timestamp/revocation floors after restart. Incoming documents cannot drop previously observed tombstones; cached certificates are checked against the shared floor. xVeil now restores/checkpoints those floors through its encrypted identity container; see the embedded-host follow-up below. |
| R29-03 | Rejected for file_picker 11.0.2; diagnostics already supplies the bytes. |
| R29-04 | Fixed local refusal semantics: additive SERVER_BUSY (12), request ID echoed, inaccurate client payload comment corrected. Loss-tolerant batches remain fire-and-forget; per-cell delivery receipts would change their contract. |
| R29-05 | Matched D-SACK observations intentionally remain bounded by RTO, not SRTT. A malicious receiver can withhold all ACKs anyway. Existing matching of actual repair handoff, fresh minimum RTT, one observation per repair and recovery-round decay remain. R29-06 removes the confirmed local source of unnecessary duplicate repairs. No claim that an uncooperative receiver can be forced to maintain its own throughput. |
| R29-06 | Fixed: discard locally retained DATA/FIN repairs already covered by accepted cumulative ACK/SACK, clear their local reservation and never count a cancelled repair as network handoff. Partial ACK tails, unaccepted originals and control cells remain eligible. |
| R29-07 | Fixed: at most 4096 probes per synchronous open, with an immediately refused local handle on exhaustion. Existing routes remain untouched; the old >64-collision regression still passes. |
| R29-08 | Fixed: the artifact gate requires a compile-flag-only marker, in addition to the always-present schema. Actual Dart AOT of the production journal with/without the flag proves the old positive check inadequate and the new gate selective. |
| R29-09 | Fixed: joined shell/PowerShell continuation commands retain original physical line numbers. LF/CRLF regression cases and repository workflows pass. |
| R29-10 | Rejected; quoted numeric sudo UID is correct. |
| PC-1 | Fixed count amplification: at most 8192 out-of-order map entries. Reject new entries without SACKing or evicting previously promised bytes; gap repair frees capacity. Verified across sequence wrap. The report's claimed 16 KiB minimum carrier cell / 128 GB attack cost is not a reliable bound for current negotiated cells. |
| PC-2 | Fixed: reserve accept capacity without awaiting the application. Full backlog queues a best-effort REFUSED reset through one bounded worker; a stalled reset carrier cannot park demux. No route/driver is allocated for the refused SYN. |
| PC-3 | Hardened independently of the withdrawal's incomplete queue argument: cap effective new-data window below half the u32 sequence space, including BBR-off / huge advertised window. Check numeric in-flight byte counts as quantities. No debug panic on peer input. |
| R28-16 | No current external panic path established: the cited batching/deadline/sequence values follow the direct/relay constructor invariants. Future constructor changes need to maintain those invariants; no media-policy change made for this speculative item. |
| R28-18 | Allocation exists in the library convenience method, but the actual runtime gateway receive loop already allocates one buffer outside its loop (`runtime/mesh_gateway.rs`). No hot-path allocation fix claimed for that runtime. |
| R28-22 | Guarded last() calls; no current defect established. |
| R28-31 | Already documented by README; not an orphan. |

### Security-state limits

With runtime persistence enabled, `peer_identity_floors.json` lives beside the
node config, with a maximum of 512
verified documents. Ordinary entries use LRU eviction; tombstone-bearing entries
are not evicted. If all entries contain revocations, new identities are refused
rather than forgetting revocations. Corrupt/unreadable snapshots fail closed.
A failed write retains the floor in RAM and retries on a subsequent observation;
restart durability requires a successful atomic snapshot write. This does not
protect against an operator deleting or deliberately rolling back the state
file. The operations documentation records these limits.

### Verification

* 1096 Rust tests passed, 20 explicitly ignored by their existing test configuration
  (onion stream, IPC, runtime and veilclient, including integration/doc tests).
* Clippy for those crates, all targets, with `-D warnings`: passed.
* 23 certificate Flutter tests passed; 11 diagnostics tests passed both without
  and with `XVEIL_DIAGNOSTICS=true`; focused Dart analysis passed.
* Workflow pin self-tests and actual repository workflow checks passed.
* The committed AOT regression compiles the actual production journal twice:
  both outputs retain the schema, only the flagged executable passes the new
  artifact gate. This qualifies the gate contract, not a newly packaged APK or
  desktop release artifact.
* Controlled negative checks restored parent production paths while retaining
  the new tests, then restored the working source under a hash guard. They
  failed for the expected reason: full accept backlog, 8193rd tiny out-of-order
  entry, and restored revoked certificate after process restart. With only the
  outbound cancellation disabled, the real async carrier was offered the
  already-ACKed repair 10 times rather than once. Corrected paths pass.

No server updates or stand calls were performed for the initial report cycle.
The Android follow-up below temporarily installed an inert test entrypoint and
restored the original APK. The preceding physical file qualification belongs to SDK
`e81ae21b`; the initial SDK changes above had automated qualification, followed by the
physical SDK qualification below.
A real certificate save dialog on each platform and release packaging remain
separate qualifications. Existing untracked multi-device evidence is untouched.


## Follow-up: Android certificate dialog and ephemeral runtime

The current production `RecoveryCertificateStep` and shared exporter were built
into an inert standalone entrypoint outside the repository. The fixture contains
no actual identity or recovery capability and opens no container or node. On the
connected Android device:

* The Save button opened the real Google DocumentsUI save panel with the expected
  suggested filename.
* Cancelling returned to the ceremony; trying Continue kept the unsaved gate.
* Saving wrote the exact fixture bytes to a file. The separate recovery code was
  absent. Continue then reported `saved=true`.
* The fixture file and owned UI dumps were removed. The original APK was
  restored and independently pulled/hash-checked; the test process was absent.

No user identity was created/reset. The test APK preserved the installed app's
manifest/version for Android's update compatibility, was signed with the existing
application key, and was used only for this temporary physical qualification.
This tests Android's actual picker/provider path; it does not qualify macOS,
iOS or Windows UI.

Reviewing the embedded boot revealed a missing boundary in the initial SDK fix:
xVeil uses `persist_enabled=false` and recreates its runtime directory. SDK
`3c1b91d9` now makes both peer certificate and identity-floor stores memory-only
in that mode, without reading stale snapshot files or writing plaintext copies.
Persistent daemons retain on-disk floors. Two new regression tests cover both
modes; all 684 runtime tests passed (11 explicitly ignored), as did Clippy with
warnings denied.

**Gap recorded at that stage (closed below):** save/restore peer authorization floors through xVeil's
identity-specific encrypted container. The persistent-daemon restart test does
not prove the embedded application's restart behavior. A follow-up native/host
interface must restore that state before application traffic, keep it current,
and retain fail-closed handling of corrupt/rolled-back security state.


## Follow-up: SDK 3c1b91d9 on Mac and cellular Android

Fresh release-native libraries were built for macOS arm64 and Android arm64 and
staged into the previously frozen production-native stand frontends. The four
file-transfer Dart source hashes tracked by that frozen build are unchanged.
This is a qualification of the new SDK with that stand, not of newly packaged
current Flutter release artifacts. All 199 exported Veil symbols are unchanged;
no media test hooks or PCM drivers were added.

* Both QA identities were ready. Contact request: 6.720 s; acceptance: 7.353 s.
* Mac → phone text: 5.837 s, one copy. Phone → Mac: 0.594 s, one copy.
* Wi-Fi off, cellular default route verified. P2P denied on both test contacts.
* Mac → phone **32 MiB**: **134.669 s** download, full SHA-256 match, original
  180-second completion gate passed. Receiver has one matching offer.
* The outgoing offer was also verified after restarting only the owned Mac
  stand: one outgoing row persisted. The earlier `/messages` counter omitted
  outgoing `fileId` fields; `/conv_messages` supplies that field and confirms
  the row. That initial zero was a measurement error, not missing chat history.
* Contact P2P overrides, phone debug property and profile pointer restored;
  owned forwarding/captures removed. Original phone APK pulled again and
  hash-verified after restoration. Both stand processes and the separate Mac
  history-check process were independently verified absent.

No audio/video call was started. No server configuration was changed. This run
has no controlled throughput comparison and does not claim a speedup over the
prior SDK or qualify source restart, every offline case, or the encrypted host
host integration implemented and qualified below.


## Follow-up: encrypted embedded-host authorization (SDK `d4b403de`)

The R29-02 embedded restart gap is closed. The host stores bounded signed peer
floor documents inside the identity's existing encrypted ratchet namespace,
using disjoint keys and 1 KiB chunks. This consumes no new namespace root and
never puts peer identifiers/documents in diagnostic exports or plaintext
runtime snapshots. File/message-cache purges retain the evidence; erasing an
identity clears it. Each document replacement is an atomic container commit;
ordinary evicted rows are removed before inserts to keep crash recovery bounded.
Native code never evicts rows containing revocations.

Boot reads storage before starting the native node, restores the signed floors
before binding application endpoints, and replays transient native boot
observations against that durable baseline. A stale pre-restore replica cannot
veto a known revocation by using a larger timestamp. Corrupt/partial storage,
invalid signatures and repeated restore are refused without silently replacing
the security state with an empty store. Warm key caches are rechecked/retired.

A revision poll alone would leave a crash window. After host restore, new
native document authorization remains unavailable until the host acknowledges
exactly the exported revision **after** the encrypted commit. Older ACKs do not
unlock newer observations. Async resolution waits briefly for this local work
instead of immediately treating it as a missing DHT record. The checkpoint owner
runs during the rest of boot, periodically, around ratchet flushes, and before
closing the shared native handle. A failed commit does not ACK and is retryable;
failed restore cannot overwrite the durable baseline during boot unwind.

Verification of this follow-up:

* Runtime: **692 passed**, 11 explicitly ignored. FFI: **297 passed**, 1 ignored.
* Selected Flutter storage/ratchet/certificate/teardown suites: **131 passed**.
* Real native FFI, encrypted-container restart, production stack boot,
  nickname boot and ratchet ABI: **8 passed** against the final matching dylib.
* Native short-buffer export preserves output bytes and reports the required
  size. Invalid signatures do not consume the valid one-time restore.
* Clippy with warnings denied, regenerated header/ABI contract, SDK format
  check and whole-project Dart analysis passed.
* All owned native test nodes stopped, sockets/runtime directories removed;
  Flutter test processes exited. No phone app, call, audio device or server was
  changed in this follow-up.

The new four-function native API changes the generated ABI contract: app
bindings and native library must be rebuilt together. These tests qualify the
Mac native/container path. The physical Android/file results above belong to
SDK `3c1b91d9`; the physical Android host qualification is recorded below; release-packaging
qualification remains outstanding. Replacing the entire encrypted container
with an older backup is not covered by these ordinary-restart guarantees.

`peer-authorization-summary.json` contains only approved booleans/counts and
software hashes. Raw native logs and generated identities were not committed.


## Follow-up: rebuilt host on cellular Android (SDK `d4b403de`)

Both Flutter stand frontends were rebuilt from root `b88ea12c`, using matching
fresh production-native SDK libraries and no media/PCM test drivers. The four
new authorization exports and the generated ABI contract match on both targets.
The existing owned QA profiles were used; no user identity was reset.

* Before startup, Android's encrypted container held **0** peer authorization
  documents. After foreground messaging and abrupt force-stop it held **3**;
  after restarting Android and further network activity it held **6**.
* Copied encrypted checkpoints opened through the real hidden-volume library.
  Every document passed the real SDK's signature/binding restore; all peers
  retained before restart were still represented afterwards. Test nodes stopped
  and their temporary runtime directories were removed.
* Before restart, text arrived once in each direction: **0.549 s** Mac → phone,
  **0.556 s** phone → Mac. After restart, the Mac's new text also arrived exactly
  once. These existing-contact checks do not qualify a new Windows invitation.
* The unchanged **180 s** file gate **failed**: a 32 MiB Mac → cellular Android
  download had reached **16 MiB** before the API returned 504. No complete-file
  hash match can be claimed. Power samples showed the receiver awake. Native
  traces show retransmission/reordering waits; this run does not isolate the
  network's contribution or prove that host persistence caused the slowdown.
* Investigation found an independent sticky maximum in RACK: observed
  reordering gaps never aged out, unlike its other 30-second timing evidence.
  The measured allowance grew from milliseconds to **7.185 s** during this
  run. Its correction/qualification is tracked separately; this failed gate
  must not be silently replaced with a longer completion limit.

The original APK was restored and independently pulled/hash-checked. The phone
and owned Mac processes/captures were absent, forwarding removed, profile
pointer unchanged, and the prior debug property restored. No calls/audio or
server changes occurred. `android-host-authorization-summary.json` contains
only approved numeric/boolean/software-revision fields; encrypted container
copies, keys and raw logs remain private.
