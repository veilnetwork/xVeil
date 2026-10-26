# Certificate QR linking through the production sheets

Local verification after the interface fixes in 6991c503. No release or push.
Production application code and SDK pointers were unchanged in this cycle.

## What passed

The new gated widget/native test uses A/B/C and a local three-relay island.
A/B finish as devices of X; C remains a different identity. A begins with a
certificate/code (XVRC) holding the same proven master as its fixture identity.
Its code is entered only on the source sheet. The test:

1. Establishes A/C contact and stores pre-link chat history.
2. Opens the actual source device-link sheet and decodes its rendered QR pixels
   using macOS Vision. Supplies that decoded result at the scanner route return
   boundary; production QR and LAN parsing are used.
3. Opens the actual target join sheet, checks matching safety codes and confirms
   that an unapproved request leaves B's original identity unchanged.
4. Operates the recovery-code field, confirmation checkbox and prepare action.
   Restarts B's real native node under the stored admission before releasing
   readiness. The source sheet then sends its snapshot and closes successfully.
5. Checks identical group IDs and exactly the two physical devices in both
   addressing sets. Old A/C history reaches B. C-to-A/B and A-to-B/C messages
   arrive once with identical logical IDs on A and B.
6. Checks both rendered device lists contain exactly two physical-device rows.
7. Stops B, sends A to C, stops C, starts B and verifies recovery from online A.
   B retains X and its original physical key. Both rendered rosters remain
   correct after that restart.
8. Confirms the pinned snapshot's encrypted recovery certificate is preserved
   and cannot be opened with a newly generated, incorrect recovery code.
   Copying that encrypted credential is intentional project behavior; it is
   not equivalent to handing over the code or an unlocked master signer.

The UI test passed, along with both existing default native-fixture smoke tests.
Direct Dart analysis of the complete test/e2e directory found no issues. A
separate Flutter analyzer wrapper stalled before producing a result and was
terminated after the direct analysis completed; it is not counted as a pass.

## Stand ownership and limits

Fixture-only additions let the UI test hold the restart readiness future until
its owned restart is complete. They preserve the process worker's default
handshake. UI-originated asynchronous work must continue receiving widget
frames while native/storage shutdown is joined. Earlier stand iterations had
missed animation-time taps and stopped the widget clock during I/O/teardown;
those were test orchestration failures, not product defect claims. Owned stuck
runner groups and their relays were terminated and checked exited before retry.
The completed run shut down normally and removed its fixture directory.

All native nodes/stores are real, but the UI test shares one Flutter process
and mocked platform preferences. Its camera route result and unlocked app
controller are fixture boundaries. It does not certify actual camera/OS
permission behavior, the production controller's complete unlock path,
Windows 10, Android hardware or live media quality. Independent-process device
and call results are recorded separately in the preceding validation directory.
The user's entire Windows/Android report therefore remains unqualified.

Only aggregate flags and A/B/C labels are committed. Native logs/clocks,
identifiers, QR capabilities, credentials and stand ownership records remain
outside the repository. No production API or test hook was added. All owned
recorded process groups/relays exited; production apps/relays were unchanged.
