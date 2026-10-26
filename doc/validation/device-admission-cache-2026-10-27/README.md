# Device admission cache during local appends — 2026-10-27

The owner/master admission cache was invalidated by every device-journal write,
including an ordinary mirrored message or theme setting. This defeated its
existing 30-second lifetime during message traffic and made subsequent frames
read the journal again for the same ownership answer.

Local serialized batches now preserve the cache only for an explicit allowlist
of message/status/read/settings/contact/call events, with the same manifest and
control-list objects. Identity documents, unknown event kinds, remote ingests
and structural writes retain conservative invalidation. If save-time admission
removes a control row, that also forces invalidation. The cache timestamp is
not extended. No message data, permissions or validation results are cached by
this change.

The updated behavioral test failed on the old implementation: changing the
theme caused a second owner read instead of retaining the first. With the fix,
a theme write and ten mirrored messages retain one read. An identity-document
announcement causes the second, expiry of the original lifetime the third,
and device revocation the fourth. The revoked device remains refused on
subsequent checks. The full group/device/backpressure/snapshot suites passed
353 tests with three existing skips; static analysis passed.

## Physical recheck

All three isolated QA apps used base `373363cb` plus this change, the same
Veil `1d36980d` artifacts and retained encrypted profiles. A was Android on
Wi-Fi, B its macOS sibling, and C a different macOS identity. No timing overlay,
native test hooks, reduced identity difficulty, Rust build or server change
was involved.

The stand first attempted recovery of the **previous** 100-message fixture,
without adding messages. At the first observation A held 34, B and C held 100.
After 181,618 ms, A held 43 and B/C still held 100. No duplicate records were
observed, but logical histories had not converged. The validation gate then
stopped the planned later load phases; its deliberate failure is not an
unexpected harness crash. No successful physical latency qualification is
claimed for this cache correction.

B's captured log does confirm that the preceding larger merge budget was
active: it served 221 missing rows in five application-level batches. That
improvement and the local cache correction are insufficient to eliminate the
remaining delay.

The next source-level concern is the group-ingest handoff: the callbacks are
declared `void`, although the provider starts asynchronous required work.
Dispatch and chunk reassembly return before that group work completes, and
the per-group mutation queue can therefore outlive transport admission. This
needs a joined, bounded lifecycle with ACK/retry/crash coverage; it is not
addressed by the cache change.

All owned macOS process groups exited, the Android QA process was stopped,
permissions restored and the owned ADB forward removed. Main app data and
system power settings were unchanged. Nothing was pushed or released. Public
[evidence](summary.json) contains anonymous role/count/timing aggregates only.
