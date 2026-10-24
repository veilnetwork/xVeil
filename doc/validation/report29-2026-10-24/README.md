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
rejection. A real device save dialog has not yet been qualified in this cycle.

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
| R29-02 | Fixed: a shared, bounded store persists signed peer documents as timestamp/revocation floors. Revocation entries survive ordinary cache pressure and process restart. Incoming documents cannot drop previously observed tombstones. Cached certificates are checked against the shared floor too. |
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

`peer_identity_floors.json` lives beside the node config, with a maximum of 512
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

No server updates, application installs, or stand calls were performed for this
report cycle. The preceding physical file qualification belongs to SDK
`e81ae21b`; the new SDK changes above have automated qualification in this cycle.
A real certificate save dialog on each platform and release packaging remain
separate qualifications. Existing untracked multi-device evidence is untouched.
