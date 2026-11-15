# Full-profile legacy compaction worker

This connects the existing worker-local prepared-compaction capability and
private external-reference recovery backend. It adds the operation owner;
it does not enable mixed-profile maintenance in the ordinary dialog yet.

## Operation and admission

One supervised storage worker retains exclusive existing-profile/catalog roles
through synchronous native prepare, staged hidden-roster repair, private intents
for visible owners, authorized publication, native close and actual-source
reference recovery. Native handles and publication never move to a child
isolate after role admission. Serving pauses throughout the accepted async
operation, so close joins that operation instead of releasing its roles early.
The operation is one-shot; a failed run requires an explicit new owner.

Inputs are deep snapshots before the first await. Every visible identity must
have an authorization, and every plaintext identity requires explicit consent.
Password/key pairs must be distinct and byte-valid, and every known legacy
child referenced by any supplied hidden or visible master must be covered.
Public inventory and consent are checked before resuming any private intents.
Each visible root is authenticated; hidden password-derived keys must match
its supplied old key. Original-source inspection uses raw handles, avoiding
open-time migrations/vacuum before preparation. This does not enumerate or
promise preservation of unknown hidden spaces outside the supplied keep-set.

Controller and worker share strict staged-roster repair. Managed locators keep
their independent keys, completed repairs are recognized on retry, and an
unresolved child prevents publication instead of deleting its roster entry.
Owned mapping buffers are cleared after use; callbacks borrow and must copy.
A metadata retry does not repeat the native rewrite.

Publication refusal aborts the prepared replacement and repairs external
intents against the retained source. A warning after publication preserves
`mayHaveApplied`, actual recovery outcome and an allowlisted warning category
(alias revocation, durability, content verification or uncertain publication).
Native error text, paths and keys are not part of the bounded outcome. A worker
death without a reply is conservatively reported as possibly applied, with no
recovery witness. It is not success, permission to retry or proof of release.

## Profile ownership

`ProfileStorageRouterOwner.compactLegacy` seals old facades immediately and
serializes the complete operation with suspend/close. It quiesces existing
preference-file owners around the full-profile worker. A refused native close
retains the worker for cleanup; the router is not reopened on a fabricated
release. Successful closure restores metadata selection, including distinct
saved access root and transient legacy view, without unlocking an identity.
An intervening profile close/suspension revokes publication and prevents reopen.

The existing private journal is bound to the default `xveil.store` source name.
The owner therefore rejects an alternate source path before suspension. Proper
source binding is required before supporting custom container names; silently
compacting the default file for another configured source is forbidden.

## Qualification and limits

The native suite uses actual hidden master/child files plus independent encrypted
and plaintext visible masters referencing both hidden spaces. Success and refusal
check exact payloads, key generations, labels, anonymity, unaffected managed
references and private-journal cleanup. Admission controls cover missing owners,
wrong visible keys, missing plaintext consent, missing hidden children and wrong
old-key mappings. Caller mutation before bootstrap and while owner work is queued
cannot alter accepted inputs. Publication warnings are exercised through a real
hardlink, not a fabricated exception.

Two real process-group SIGKILL boundaries cover prepared-but-not-authorized
publication and committed/recovered-but-reply-pending publication. Before killing,
a competing opener must observe actual full-profile contention. The parent joins
process death before recovery and verifies both hidden files and all visible
references. The first case retains byte-identical source data; the second keeps
the published generation. A separate disposable worker verifies that lost replies
produce bounded uncertain outcomes without claiming native release.

Final sequential runs report **90 passes, no skips**: 16 native operation/owner
cases and 74 regressions spanning controller repair/lifecycle, profile ownership,
preference quiescence, ordinary/backend reference recovery, real process-death
recovery and the headless-import guard. Full `lib` plus all new tests/helper
analysis reports no issues. The chosen library's binary digest and all 145
recorded Rust input digests match; this round changes no Rust source or native
binary. An intermediate borrowed-password regression was caught by two failing
buffer-ownership cases and fixed before these runs; it is not attributed to the
previous released implementation.

These are host-native storage/owner checks, not full application RPC-death,
physical Android/OEM, Windows source-directory durability or release-AOT
qualification. All-owner dialog collection and controller entry wiring remain
open. Other native targets still need the persisted-padding library rebuild and
qualification. Production managed defaults remain OFF and the general
mixed-profile compaction guard remains ON. No push or release is part of this
round.
