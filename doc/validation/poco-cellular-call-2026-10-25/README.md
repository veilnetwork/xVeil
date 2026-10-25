# Poco cellular call: startup succeeds, audiovisual quality fails

## Setup

Physical Poco on cellular data called a Mac using existing separate QA
identities. Android's active default network was verified from the current
network-agent entry before and after the test: cellular, without Wi-Fi.
Historical connectivity entries were excluded. No network, volume or power
settings were changed.

Installed the qualified QA APK with replacement preserving its profile;
verified the installed APK SHA-256 against the qualified artifact. Frontends
match `38bcbaaa`; production native SDK artifact is `325e36e0`, while checkout
`54dff306` adds optional DHT tracing. No native fault injection or relaxed PoW.
The main application and its data were not replaced. Mac used a separate
validated QA profile and `TMPDIR=/private/tmp/`.

Temporarily allowed P2P for these QA contacts, retaining automatic route
selection. Both endpoints had anonymous routing disabled. No forced relay,
mailbox signalling or relay media priority was introduced.

## Results

| Measurement | Result |
|---|---:|
| Phone placement to incoming ringing on Mac | 692 ms |
| Accept to at least five received audio RTP packets on both endpoints | 2,449 ms |
| Audio-only observation after startup | 10 s |
| Observation after enabling both cameras | 60.294 s |
| Decoded video frames, Mac / phone | 3 / 3 |
| Route on both endpoints throughout sampled active call | P2P |
| Route handovers | 0 |

**The video startup gate failed.** Neither receiver reached five decoded
frames within 60 seconds. The runner ended the call at that timeout, before
the planned subsequent 90-second continuity phase. There is no final-FPS pass.
Observed decoded stalls lasted at least 53.8/54.9 seconds on Mac/phone.

| Audio telemetry, receiver | Mac | Phone |
|---|---:|---:|
| Audio-only native jitter-buffer peak | 81 ms | 173 ms |
| Audio-only ending interruption count | 0 | 2 |
| Audio-only accumulated interruption duration | 0 ms | 387 ms |
| Video-phase native jitter-buffer peak | 242 ms | 203 ms |
| Ending interruption count | 8 | 15 |
| Ending accumulated interruption duration | 3,580 ms | 11,237 ms |
| Audio RTP received by end | 490 | 1,430 |

The interruption counters are native telemetry, not a listening assessment.
Microphones and cameras remained enabled. Continuous speech, intelligibility
and loudness were not tested. Received packet counts alone do not establish
usable speech quality.

Adaptation reported source pressure and paused video. Both senders reported
only three transmitted video frames; the phone camera capture still reported 30 FPS in a
live diagnostic sample. Thus the frozen remote image was not merely a stale
UI FPS label. This does not establish whether the pauses were excessive or
which upstream condition first caused the pressure. The call network-activity
lease was held in every sampled active/running-media observation; this is not
proof that every Android or SDK power mechanism was inactive.

## Transit observations and limits

Matched exact audio SR/RR feedback using private native traces, subtracting
receiver residence without synchronizing device clocks.

| Source | Matched audio observations | Callback transit RTT median / maximum |
|---|---:|---:|
| Mac | 15 | 202.410 / 1,163.279 ms |
| Phone | 13 | 83.624 / 1,393.142 ms |

This composite includes SDK/connection queues, network and dispatch. It does
not attribute delays to the cellular operator. No relay was selected during
this run, so a P2P-to-relay handover cannot explain its video freeze. There
were zero qualified observations of the new high-baseline probe branch;
this test does not physically qualify that branch or demonstrate a benefit
from it. One cellular call cannot establish a regression against a different
phone's earlier Wi-Fi run.

The adapter's receive-pressure input peaked at 827 ms on Mac and 203 ms on the
phone. Those policy inputs are exported separately from the native jitter
buffer peaks above; they must not be treated as the same measurement.

## Cleanup and evidence

Hung up both endpoints, disabled native traces, restored the contacts' initial
P2P policies, closed the owned Mac process group and force-stopped phone QA.
Rechecked zero remaining owned processes, removed the owned ADB forward,
restored and re-read initial User-0 microphone/camera grants, and archived the
owned Mac profile and runtime after checking open files. The installed QA APK
remains available; the main application was unchanged.

[summary.json](summary.json) and [series.csv](series.csv) contain fixed role
labels, software revisions, relative durations and allowlisted numeric or
boolean telemetry. Identities, addresses, keys, native absolute timestamps,
SSRC/LSR, raw logs and media are excluded. Private traces remain local.
