# Public Space ownership transfer: causal signature preservation

## Confirmed defect

Ownership transfer signatures cover `ControlEntry.seen`. The public authority
projection kept it in memory and reconstructed it for verification, but its XA1
binary codec dropped it. A transferred descriptor could verify before sending
and fail after a DHT round trip. The separate JSON link parser also rejected
its own emitted `seen` field.

The regression failed on the unmodified codec: the decoded causal reference
was null. This explains the native observation of two generation-1 records
with no accepted search candidates; it was not evidence of a transport size
limit or a failed ownership fold.

## Change and compatibility

XA1 remains byte-compatible for chains with no causal references. XA2 retains
each original signed reference as length-prefixed UTF-8 (a 16-bit little-endian
length; `0xffff` represents absence). It preserves absent versus empty values
and mixes old and new transfer links in one bounded chain. The maximum remains
24 transfers and the complete discovery payload remains limited to 16 KiB.

Older clients cannot verify XA2 and reject it; they must update to discover
Spaces whose authority chain contains causal references. No signatures are
bypassed and global search still requires two independent holders. Native
Veil treats the inner payload as opaque and needs no codec change or server
update for this fix.

Strict decoding rejects truncated data, unknown codec versions, excessive
link counts, invalid UTF-8, trailing bytes and an XA2 chain with every
reference absent. A successor cannot rewrite a predecessor reference even
when it signs the enclosing descriptor again.

## Native fixture corrections

The three-node stand now disables bundled seeds and meeting points, checks
exact authenticated peer identities, and waits for generation 1 with two
holders. The previous predicate could finish on an old generation before
new publication arrived. Failure diagnostics contain counts, generations,
fixed fixture role labels and verification booleans; they export no identities,
addresses, names, keys or raw native timestamps.

The native test also verifies a serialized transferred publication with the
real identity verifier before attempting discovery.

## Remaining issue

A separate native run after the codec fix returned a valid generation-1
candidate but only one holder: every replica retained the same holder sample.
The DHT currently stores one value per route and picks its holder through a
replica-salted deterministic rank. That policy can collapse holder diversity
in a small connected network. Increasing the timeout cannot recover an entry
that every replica discarded. This issue remains open; the codec fix does not
claim to solve availability quorum or the full defect-removal goal.

See `results.json` for the completed validation results.
