# Windows receive-only audio probe

This operator stand feeds synthetic Opus/RTP into an **unchanged production
`veil_media.dll`**, through the same datagram callback ABI used by the engine.
It uses the real Windows ADM and checks the Windows audio session belonging to
the probe's exact PID. It requests playout only (`send=0, recv=1`); no microphone
or PCM recording, network listener, real identity or app profile is involved.

The small `datagram_fixture.cpp` DLL deliberately replaces the **transport**,
not the media engine. Its name must be `veilclient_ffi.dll` because the Windows
engine resolves that module by name. Build and run it only in a newly created
stand directory. Never install this fixture DLL next to `xveil.exe`.

## Inputs and build

### COM lifetime control without playing audio

`test/native/windows_audio_com_lifetime_probe.cpp` reuses this transport fixture
to check construction/destruction of the real media engine. Copy that source to
the isolated stand directory, build the fixture DLL as below, then compile:

```powershell
cl /nologo /std:c++17 /EHsc /W4 /WX /wd4191 windows_audio_com_lifetime_probe.cpp /Fe:com-lifetime.exe /link ole32.lib
if ($LASTEXITCODE) { throw 'COM lifetime probe compile failed' }
```

Run `com-lifetime.exe ABSOLUTE_FIXTURE_DLL ABSOLUTE_MEDIA_DLL unicast sta` in the
interactive session; repeat in fresh processes for `unicast mta`, `group sta`
and `group mta`. All four must exit 0 and report both creation/destruction COM
preservation. Exit 1 is a product failure; other nonzero exits indicate fixture
failure or timeout. This control never starts capture/playout or the network;
it does not establish audible sound. The same binary-provenance and isolated
directory requirements apply. Never put the fixture in an application bundle.

### Receive-only audio control

Use the x64 Visual Studio Developer PowerShell, Python 3, and FFmpeg with
libopus. Supply a media DLL whose SHA has already been verified against the
release provenance, or against a qualified source build. Record/check its
SHA before and after execution; merely copying an arbitrary DLL is not a
provenance check.

From the repository root, copy these files into the new stand directory:

- `test/native/windows_audio_receive_probe/{receiver,datagram_fixture}.cpp`
- `windows/runner/audio_output_probe.{h,cpp}`
- the verified media DLL as `veil_media.dll`

In that stand directory:

```powershell
cl /nologo /std:c++17 /EHsc /W4 /WX /wd4191 /LD datagram_fixture.cpp /Fe:veilclient_ffi.dll
if ($LASTEXITCODE) { throw 'boundary compile failed' }
cl /nologo /std:c++17 /EHsc /W4 /WX /wd4191 receiver.cpp audio_output_probe.cpp /Fe:receiver.exe /link ole32.lib uuid.lib winmm.lib
if ($LASTEXITCODE) { throw 'receiver compile failed' }
```

Warning 4191 is disabled for the explicitly typed C-ABI `GetProcAddress`
bindings; other compiler warnings remain errors. These helpers need the
Windows SDK, not a WebRTC source build. The media DLL itself is not rebuilt
or patched by this stand.

Generate `p20.rtp`, `p40.rtp`, `p60.rtp` using `make_fixture.py DESTINATION
--packet-ms 20|40|60`. For the negative control, add `--silence`, e.g. `s40.rtp`.
Each fixture contains 12 seconds of real Opus, with RTP payload 111 and
synthetic SSRC/identity bytes. Pattern fixtures contain quiet tones at
1.5–3, 5–6.5, 8.5–10 seconds. The generator's peak is 0.03 full scale;
system and application volume are never changed by the helper.

## Execute and qualify

Run in the interactive user session, with absolute file paths. SSH session 0
is not a substitute for the desktop audio context. A scheduled interactive
task may launch the stand; the operator must remove that task afterwards.

The process interface is:

```text
receiver.exe ABSOLUTE_FIXTURE_DLL ABSOLUTE_MEDIA_DLL ABSOLUTE_RTP_FIXTURE
```

Capture stdout/stderr into private files. On PowerShell 5.1 retain the native
process handle **before** waiting, otherwise an otherwise completed process
can yield a null `ExitCode`. The qualified operator job uses this sequence:

```powershell
$process = Start-Process -FilePath $receiver -ArgumentList $arguments -PassThru -RedirectStandardOutput $rows -RedirectStandardError $stderr
$process.Handle | Out-Null
$session = $process.SessionId
if (!$process.WaitForExit(45000)) { Stop-Process -Id $process.Id -Force; throw 'probe deadline exceeded' }
$result = @{finished=$true; exitCode=$process.ExitCode; session=$session; mediaSha=$verifiedMediaSha}
$result | ConvertTo-Json -Compress | Set-Content $job
```

`$arguments` contains the three quoted absolute paths; `$verifiedMediaSha`
must agree with the selected binary's verified manifest. The receiver also
has its own 40-second watchdog. It unregisters the datagram callback on exit.
Neither a zero exit nor increasing RTP counters alone qualifies the audio path.

```text
python analyze.py PRIVATE_ROWS PRIVATE_JOB --engine-sha VERIFIED_SHA --packet-ms 40
python analyze.py PRIVATE_SILENCE_ROWS PRIVATE_SILENCE_JOB --engine-sha VERIFIED_SHA --packet-ms 40 --silence
```

The analyzer requires successful process completion in a desktop session,
the expected binary SHA, unmuted/nonzero app and endpoint volume, successful
native playout without capture, progressing RTP counters matching the packet
duration, emitted PCM, all three tone windows in both native stats and the
Windows session meter, quiet intervals, and callback cleanup. Unsupported or
ambiguous metering is unknown, never silently replaced by an endpoint-wide
meter belonging to other applications.

The meter is a normalized stream peak, **not SPL or human audibility**.
See Microsoft's [`GetPeakValue` contract](https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nf-endpointvolume-iaudiometerinformation-getpeakvalue).
No raw audio is read by the probe. The analyzer exports only aggregate
results; raw native rows and job/PID metadata remain private. Tests:

```text
python -m unittest discover -s test/native/windows_audio_receive_probe -p "test_*.py" -v
```

This isolates receive/decode/Windows-session output under a deterministic,
lossless boundary. It does not qualify app route preferences, signaling,
encryption, mobile handover, packet loss, physical speaker wiring, capture,
AEC, or listening quality. After collecting evidence, verify the process has
exited and remove the owned task and stand directory (including the fake DLL).
