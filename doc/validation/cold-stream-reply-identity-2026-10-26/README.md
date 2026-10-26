# Cold stream reply identity lookup

Local correction after the queued-write cycle. No release, push, production
installation or relay deployment.

## Confirmed cold-start gap

An accepted contact's physical device may be known through a verified identity
document restored by the host, while the new native runtime's DHT mirror is
still empty. NodeServices::identity_of_device_local previously searched only
the DHT mirror and returned no identity in that state.

Anonymous stream answers go to the requester's physical device. Ads at that
address include both its stream cookie and its shared identity's mailbox cookie.
The stream resolver and FFI pool opener use identity_of_device_local to exclude
the latter: mailbox registrations are not circuit-splice destinations. Missing
the restored identity therefore leaves an unusable mailbox advertisement
eligible as a return-stream route.

The lookup now first uses the existing verified document-floor hint. That hint
already rejects expired, revoked, ambiguous and uncheckpointed host mappings.
The prior local-DHT fallback remains available. This is only exclusion of a
mailbox cookie, not authorization to read content or admission of a claimed
sender. No network walk, new trust rule, wire format or relay priority is added.

The regression creates and verifies a signed delegated-device document, exports
the real host authorization snapshot, stops the native runtime, starts it again
and imports that snapshot before application traffic. It verifies that the DHT
document is absent and the verified device hint is present. Before correction,
the actual reply-route identity lookup nevertheless returned None; afterwards
it returns the restored identity. The failure and success were both observed.

All 726 enabled veil-node-runtime library tests passed (11 existing skips),
including the document-floor expiry/revocation/checkpoint tests and the existing
DHT lookup coverage. All 325 enabled veilclient-ffi library tests passed (two
existing skips). Rust warnings were denied. The external target mount identity
was checked before and throughout Rust compilation/testing.

## Handshake diagnostics and live observations

The existing endpoint RT trace can now record bounded numeric ingress events:
rejected protected introduction, unknown peer tag, admitted SYN and admitted
SYN_ACK. Counts are emitted at powers of two, without peers, cookies, tags,
sequence numbers, payloads or raw clocks. They are silent when RT trace is off.
No relay learns these classifications. A real feed regression also checks that
an introduction encrypted to the wrong key is rejected while the following
correctly encrypted handshake answer is admitted exactly once.

Before the lookup correction, the optimized diagnostic build ran three cold
anonymous transfers between the existing independent macOS QA nodes B and C.
A stayed offline. B remained the linked device of identity X; C used identity Y.
Each transfer used a fresh uncached 3 MiB file plus 251 bytes, with both contacts'
P2P policies temporarily denied and restored afterwards. Native ingress counters
confirmed one admitted SYN and SYN_ACK in every run, with no intro rejection.
Complete verified downloads took 67.829, 27.211 and 35.332 seconds. None of those
three runs reproduced the earlier 25-second connection timeout. A preliminary
64 KiB probe used the datagram path and is excluded from stream qualification.
The mapped native library paths were checked against the selected QA artifact.

These observations do not establish that the earlier network timeout had this
specific cause. The cold lookup bug is established by the isolated restart
regression. Variable DATA delivery latency remains a separate unresolved issue;
neither the numeric counters nor this lookup correction changes bulk pacing.

The final optimized library, including the lookup correction, was subsequently
cold-launched in both QA processes and its mapped path verified in each process.
Two more fresh uncached 3 MiB plus 251-byte files were transferred with P2P denied:

| Direction | Complete verified download | Connection timeout/retry | Ingress |
| --- | ---: | --- | --- |
| C to linked B | 19.788 s | None | SYN and SYN_ACK admitted |
| Linked B to C | 18.383 s | None | SYN and SYN_ACK admitted |

Both files matched byte-for-byte and by SHA-256. These functional checks establish
successful anonymous delivery in both directions on this stand; they do not
establish a fixed latency guarantee or reproduce the reported Windows setup.
Original contact policies were restored, RT trace disabled and both owned app
process groups verified exited. Latest encrypted profiles were archived without
rolling back native state. Main apps, the offline phone and system settings were
untouched.

Latest encrypted QA profiles and raw diagnostics are retained privately. Public
evidence contains no device identities, addresses, tickets, content identifiers,
payloads or raw event timestamps. Windows 10, cellular quality and the full
multi-device campaign remain outside this cycle's qualification.
