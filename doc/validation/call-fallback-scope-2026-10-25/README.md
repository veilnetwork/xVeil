# Fallback ownership must belong to one call

**Startup follow-up:** a later run with this ownership repair still took
26–32 seconds to receive audio in both directions. A separate capability
selection defect caused repeated receive-pool rebuilds and relay-slot pressure.
After that repair, the same two native cases reached the audio gate in
4.156 seconds and 447 ms. See the
[capability investigation and qualification limits](../call-rendezvous-capability-2026-10-25/README.md).
The results below describe the original ownership cycle.

## Confirmed defect

The production `AnonStreamHub::private_media_routes` factory cloned the hub's
four producer cores for every call. Cloning also shared their opener registry,
fallback pool and circuit owner. After the
[lifetime cleanup](../call-fallback-lifetime-2026-10-25/README.md), stopping one
call therefore closed the shared owner, cancelled another call's fallback
openers/circuits and permanently prevented later calls on that hub from opening
their fallback routes. Private routes could still work; this was not proof
that every subsequent call must fail entirely.

The previous network fixtures constructed fresh cores for each call, bypassing
this factory and missing its sharing mistake. New tests use the actual
production `AnonStreamHub::new` and `private_media_routes` entry points, with one
hub retained across call lifetimes.

## Fix

Each call now constructs four isolated producer cores from the hub's base
circuit backend. Their owners, opener registries, pools and local route-health
state belong to that call. Closing it retains the existing immediate cleanup,
without closing another call or poisoning the factory for a later call.
Shared file-stream registrations and authentication remain hub-wide.

No relay limit, scheduling class, wire marker, protocol or C ABI changed.
The non-circuit backend still returns no private route object. All additional
fixtures are test-only; the Unix IPC fixtures are gated to Unix platforms.

## Evidence

| Check | Result |
|---|---|
| New factory regression against preceding production code | Semantic failure: all four live/subsequent call cases admitted **0** fallback workers instead of 4 |
| Same regression after fix | All four cases admit all 4 producers; covers same-peer repeated calls and another peer sharing the hub |
| Real node/relay fixture using the production factory | Exact encrypted media packet received before and after another call closes; surviving origin still exists |
| Subsequent call on the same live hub | Opens a fresh fallback and delivers another exact authenticated packet |
| Stopped call cleanup in that fixture | Its old origin is absent; the runtimes remain running during the check |
| Full embedded FFI suite | **377 passed, 11 existing ignored** |
| Strict Clippy, all FFI targets | Passed |
| Rustfmt and whitespace checks | Passed |

The real network fixture uses actual origin circuits, relay builders and
dispatchers, splicing, directional media encryption and the receive callback.
Its session links are joined in memory; this is not a physical phone call,
an acoustic quality check or a measured startup speedup. The factory regression
uses an offline node and checks actual worker admission, not media delivery.

Full-suite flags were `--no-default-features` with
`node-embedded,allow-empty-seeds,test-low-difficulty,packet-tunnel`. The low PoW
difficulty is confined to the local test build. A final fixture attribute
restricts the new network test to Unix; on this Mac it does not change the test
body or production code. Strict Clippy checked that final source state.

## Remaining startup delay

The earlier native three-device trace also contains relay `PerLinkFull`
refusals at the unchanged 64-circuit per-link limit. That observation is real,
but this fix does not establish which allocations filled the link or remove
every cause of the earlier approximately 14-second cold anonymous startup.
The first slow call also preceded any close on its hub, so this lifetime
interaction cannot explain all of its delay.

Rebuild and qualify repeated anonymous calls with the updated SDK before
claiming a physical latency improvement. This cycle did not install a new
phone or desktop app and did not update relays. No GUI app was launched;
owned Rust test process groups were verified exited. Local fixture runtimes,
IPC server and socket were closed by their successful tests.

[summary.json](summary.json) contains only software hashes, counts and test
status. Detailed logs remain in the private stand cache; no device addresses,
source IDs, keys, payloads, absolute native timestamps or capture labels are
included in the public evidence.
