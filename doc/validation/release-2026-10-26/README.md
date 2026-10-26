# Release and bootstrap verification

Published Veil [0.11.46](https://github.com/veilnetwork/veil/releases/tag/v0.11.46),
then xVeil [0.13.93](https://github.com/veilnetwork/xVeil/releases/tag/v0.13.93).
Hidden-volume remains at the already published 2.6.4; its source did not change.

The final source CI, native library matrix and release workflows passed.
Veil exposes 43 assets; seven checksum manifests verified against the installer's
pinned Ed25519 key, and their 28 binary digests match GitHub's asset digests.
The downloaded server binary matches its signed checksum. xVeil exposes all
15 expected nonempty platform assets with SHA-256 metadata.

Six production and three testnet services were updated sequentially with
binary/config/state backups and rollback checks. The testnet binary was built
from the final tagged source with its network seed features and verified in an
isolated Linux container. Post-install checks and a second fleet verification
after app publication confirmed the expected executable hashes, advancing
health ticks, active sessions and successful DHT listing on all nine services.
Configurations retain their previous hashes and no automatic restarts occurred.

This document records the published tags. Subsequent diagnostic-report changes
are local work and are not part of xVeil 0.13.93. Hardware media qualification
is described separately in the video-cruise validation evidence.
