# Local release builds verify media implementation and packaged bytes

Base: xVeil `92b9f84a`, Veil `5fff0ad0`. Producer changes are committed locally
in Veil `5b2a31c7`. No native runtime implementation or protocol changes here.

## Confirmed gap and pin audit

CI already checked native source provenance when fetching engines. Local
builder.py instead admitted staged Android engines by presence, checked APK
exports, and admitted desktop bundle engines by presence. An old implementation
with the same exports could pass those local release gates. The dependency
fetcher also accepted an existing engine by exports and downloaded binaries
without their build records.

Thirteen new test methods on the unchanged base produce **22 assertion failures**;
three method controls pass. Tests exercise actual release plans before the first
compiler command, APK extraction, desktop bundle checks, cache admission, and
release/run-artifact download publication. Network replies and export checks
are controlled; source hashing, binary hashing, ZIP handling and file publication
are real. Invalid downloads leave the previous staged pair intact.

The seven published provenance records for `engine-2026.11.12.2` were fetched
read-only. **All seven name a different native source digest** from the current
tree. They remain correctly rejected, with no pin or validator bypass. The
current source digest is:

```text
e427544568d661d901999cd680bef2f191e4fe308eaa0203dfdb6ea8c5bde453
```

The previously qualified private macOS component matches current source and its
own binary SHA, and passes the 107-export gate. This audit fetches old provenance
records only; it does not claim fresh compilation or qualification of seven
replacement binaries.

## Change

- Local Android/Linux/Windows release plans use the same source/binary verifier
  as CI before compilation. Artifact checks verify the actual APK entry or
  desktop loader location against the staged producer record: lib/ on Linux,
  beside the runner on Windows. An unused nested copy does not satisfy the gate.
  Debug presence
  admission and desktop optional-engine policy remain unchanged.
- The fetcher verifies cached records and stages both downloaded inputs in a
  temporary directory. It validates the pair before replacing staged files.
  Candidates keep a non-loadable .part suffix until publication.
  Release and run-artifact routes both carry matching records; old artifacts
  without records require rebuilding rather than an unchecked fallback.
- Linux/Android/Windows wrapper builders capture source digest before compiling
  and record final bytes after linking/postprocessing, rejecting source changes.
  Their compile/link commands are unchanged. macOS already used this mechanism.
- Workflows preserve that producer source witness in their richer records and
  carry sidecars through fetching, staging and workflow artifacts. Android
  preserves the producer's media bytes and excludes provenance from the APK.
  Generated records are ignored by Git; BUILDING.md describes manual staging.
- Neutral AOT materialization retains the record as an independent input: it
  survives copying, affects the fingerprint and cannot mutate its original.

No user settings, app runtime behavior, storage layout, membership, mailbox or
network policy changes. No existing library is relabeled to match new source.

## Qualification

**79 Python tests run: 77 pass and two are skipped**, across twelve related
build, provenance, artifact, neutral-workspace and privacy suites. The skipped
cases require the real Windows compiler and a Windows export-ACL failure; they
are not counted as passes. Existing build-support checks pass separately.
All **439 final code/config inputs** retain their test-run hashes; ignore rules
are separately checked at each generated record location.

Four deliberate mutants produce assertion failures: remove preflight admission
**9**, validate staged instead of packaged bytes **3**, check source but omit
binary SHA **8**, and publish unverified downloads **3**. Mutations are restored
before final testing. Final baseline failures are assertions, not import/errors.
A later fixture hook initially referenced a helper absent on the baseline;
that error was corrected before the qualified final baseline and is not counted.

A standalone Android Gradle Plugin **9.0.1**, Gradle **9.1.0** fixture compiles
the exact production Kotlin packaging block. A debug-bearing Android arm64
shared-library fixture is compiled with NDK **28.2.13676358**. Production packaging
preserves its SHA and includes zero provenance entries. Removing keepDebugSymbols
changes the SHA, establishing the need to check packaging as well as staging.
Both owned Gradle workspaces are removed; no APK is installed.

Unix producer scripts pass bash syntax checks. On the available Windows host,
the actual PowerShell parser accepts the native producer and four workflow
PowerShell blocks with template values substituted. The temporary script is
removed. Two earlier stdin-fed parser attempts did not finish and are not
qualified; their owned processes are retired and a later query observes zero
remaining. This is syntax qualification, not a full Windows compiler/link run.
All four changed workflow YAML files parse successfully.
The Windows CI checkout now includes the submodules needed by these tests.
An additional Windows unit repeat was not qualified because source transfer
failed; it is not counted as a product regression or a passing run.

The shared verifier accepts the actual current macOS component and rejects all
seven old source records. The component's SHA remains unchanged. These checks
are separate from the unit-test totals and do not exercise capture or sound.

## Remaining release work

The follow-up below completes the seven replacement engines. Final application
packages and macOS package qualification remain; a component prerelease is not
an application release. The original Windows 10 camera complaint is not
attributed by these checks.

No GUI window, focus change, OS input, physical capture, user container or seed
is changed. Owned test/build supervisors exit and the existing user app remains
running. Privacy checks pass for the staged changes. No push or release.

## Follow-up: seven replacement engines published

The final producer source is xVeil `2f6658a2` / Veil `5b2a31c7`, with the same
native source digest printed above. Linux/Android run `44107427387` and Windows
run `44107439146` completed all seven compilation jobs. Each library passed its
107-export gate; downloaded producer and workflow records agree on source and
binary SHA. ELF/PE machine types were independently checked for all targets.

The fourteen assets in [engine-2026.11.17.1](https://github.com/veilnetwork/xVeil/releases/tag/engine-2026.11.17.1)
were first uploaded as a draft, downloaded again, and compared byte-for-byte
by SHA with the qualified inputs and GitHub asset digests. The tag resolves to
the intended source commit. The prerelease is published without changing the
latest application release. All three application workflow pins select it.
Subsequent Rust/HV-only changes do not alter the C++ media source digest.

This qualifies compilation, provenance, exports and publication. It does not
claim a user-visible Windows 10 camera fix or a new physical call test.
