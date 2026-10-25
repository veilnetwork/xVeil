# Video probes during an RTT warning

**Candidate status:** unit and native-codec checks pass; phone validation is
pending. The phone disappeared from ADB before installation. The new Android
and macOS QA frontends are built, but this cycle has no physical candidate call
or measured improvement in its full-quality ramp.

## Evidence behind the change

In the preceding [physical qualification](../video-packet-duration-2026-10-25/README.md),
one Mac source stayed at two FPS for about 13 seconds. During approximately nine
of those seconds, RTT estimates of 238–295 ms withheld growth despite small
audio buffers and confirmed decoder progress. A later repair hold also delayed
growth. These are separate reasons; this change addresses the RTT warning.

[before-decisions.csv](before-decisions.csv) extracts those pre-change policy
observations. Times are relative to the call fixture. Applied cadence and
decoder credit are snapshots following the decision; audio and RTT columns
come from the decision's recorded inputs. This is not a candidate replay or a
prediction of its network performance.

## Policy

When current audio measurements permit growth but RTT is outside its ordinary
recovery rail and below the existing 400-ms failure rail, the delivery model
may request a cautious probe:

- A fresh causal decoder acknowledgement must cover media sent after the last
  accepted native budget change, from every expected receiver.
- Probe gain is 1.25 for bitrate and cadence. Bitrate rounds up to whole kbit/s;
  cadence remains fractional, so one FPS becomes 1.25 FPS rather than two.
- Accepted budget changes impose a three-second interval on cautious probes.
  Failed native updates and cached decoder reports earn no extra step.
- Measured audio loss, growing buffers, pressure, unknown measurements, missing
  receivers, paused capture and source constraints still withhold these probes.
- Fresh fully healthy feedback restores the existing fast startup. Older
  engines without causal delivery telemetry retain their existing RTT policy.

The source pressure and repair-hold policy, failure thresholds, codec settings,
relay behavior and protocol were not changed. Candidate diagnostics expose the
boolean `rtt_probe_eligible`; decoder credit and native acceptance still decide
whether an eligible probe is actually applied.

## Checks

| Check | Result |
|---|---|
| Focused adapter, delivery, source-pressure and group-media checks | 299 passed |
| New RTT-probe cases | 24 passed |
| Same new tests against preceding production policy | Semantic assertion failures; compilation succeeded |
| Real Opus/VP8 public budget API, 19 kbit/s at 1.25 FPS | 15 transmitted video frames during the 12-second drive; audio progressed |
| Android and macOS QA frontend builds | Passed; production native libraries identical to baseline |
| Physical candidate call | Pending; no phone available |

The new cases cover fractional cadence, probe spacing, native failure/retry,
fresh and cached decoder reports, legacy engines, rising buffers below the hard
ceiling, receiver growth verdicts, requested buffer targets, hard RTT failure,
loss, interruptions, source pressure, stopped video and missing receivers.

The native fixture uses actual Opus and VP8 with local transport callbacks and
synthetic input. It verifies that the public API does not round the fractional
probe to one or two FPS; it does not assess physical speech or image quality.
Only its test was added in the SDK. Production media and Rust libraries were
reused without code changes. No GUI test applications were started, no phone
installation attempted, and no device permissions, system power or volume
settings changed in this cycle.

[summary.json](summary.json) contains software hashes and qualification status.
Public evidence excludes device IDs, peers, addresses, credentials, absolute
native timestamps, capture labels, audio and images. Detailed build/test logs
remain in the private stand cache.

## Required follow-up

Run the rebuilt QA apps on Mac and phone, verify whether cautious probes are
actually exercised, measure the full-quality ramp, and check audio continuity.
The previous 20–31-second full-quality-ramp result remains the physical baseline.
Live speech, loudness, Windows, the full multi-device matrix and production
fault-injection cleanup also remain separate unfinished work.
