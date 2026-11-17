# Group screen retirement retains its engine and permits a real retry

Base: `845db212`. This follows the
[pending-start owner correction](../group-screen-start-owner-2026-11-17/README.md).
It does not attribute the Windows 10 camera complaint.

## Evidence

Screen OFF detached its Android source before awaiting stop. Concurrent leave
or disposal then found no source and could dispose the engine and release the
actual CallSlot while the known stop reply remained pending. A failed screen
start had a second problem: an exception left a failed source in the shared
field, so retry returned success without creating a source. A normal false
reply discarded the source without retrying its cleanup.

The latter matters in the actual AndroidScreenCapture adapter. A lost native
start reply triggers native cleanup. If that first cleanup fails, the adapter
retains channel ownership, correctly preventing another source from starting.
Discarding the controller's reference left a transient cleanup failure blocking
the next enable.

Eleven new tests on the unchanged base produce **nine assertion failures and
two passing controls**. All drive the actual group service, media controller and
CallSlot. Controlled source/engine cases cover OFF, reentrant disposal from stop,
concurrent disposal, a returned close error, attached-source teardown, failed
startup close, and retry after a thrown start. Three cases use the actual
AndroidScreenCapture/MethodChannel bridge against a controlled messenger:

- native stop reply held while OFF and leave race;
- lost start reply plus transient native cleanup failure, then retry;
- the same failure with permanently refused cleanup: no successful share or
  overlapping native start is claimed.

The oracle is an actual competing lease, engine disposal, source/native start
counts, delivered frames and service state. Gates replace timing thresholds;
all replies and commands are released/joined in cleanup. Native bridge handlers
and retained channel owners are cleaned up independently at the end.

## Change

Camera retirement tracking is generalized to per-engine capture retirement.
The existing camera wrapper retains its behavior; a screen wrapper uses the
same registration-before-port rule. OFF, captured teardown and source startup
cleanup register their own stop replies. Teardown joins that engine's known
camera and screen replies before disposing it and releasing the lease.

Source-start refusal or exception now retires the exact failed source. Detach
occurs before entering its stop port, but its reply is registered before a
callback can leave/dispose the call. Exceptions retain their original contract;
retirement failure does not replace the start error. A retry therefore creates
a new source instead of accepting the failed placeholder. A transient native
cleanup failure gets an explicit cleanup attempt before retrying admission.

The existing policy after a returned close error remains best-effort: a failed
reply is not proof of physical release. The screen OFF error is still returned
to its caller. Native channel ownership continues to prevent overlap when
cleanup remains refused. No native code, ABI, media pin, permission, codec,
wire format, membership, storage or mailbox policy changes.

## Qualification and limits

**948 tests pass, zero skipped**, across twenty related call, group, capture,
slot, audio-policy, diagnostic and profile-lifetime suites. With diagnostics
enabled, **498 pass, zero skipped**, in five overlapping suites; these counts
are not additive. Analyzer and whitespace checks pass. All **1,956 tracked
Dart/package-manifest inputs** retain their final-run hashes.

Four deliberate mutants give the intended assertion failures: untracked OFF
**5**, untracked startup cleanup **2**, omitted false-result cleanup **1**, and
omitted exception cleanup **2**. All mutations are restored before final runs.
The initial fixture's import/style findings were corrected before qualification;
they are not counted as regression failures.

These are host controller/service and actual Dart Android-bridge executions
against controlled native replies. They do not start MediaProjection or use a
physical phone, and do not prove hardware shutdown after a returned failure.
Windows 10 and the original user camera case remain separate.

Tests use TMPDIR=/private/tmp/. No GUI windows, OS input, physical media, phone
installation, user container or seeds are changed. Test processes exit and the
existing user app remains running. No push or release.
