# Production instrumentation audit — 2026-10-21

Generated PCM, replacement ADM/codec creation and the PCM-driver library are
confined to disposable stand source exports produced by
`scripts/prepare_physical_pcm_probe.py`; the app's `lib/`, Android/macOS packaging
and workflows do not import or bundle them. The regular debug API is already
unconditionally excluded from release and explicitly gated in profile builds.

The remaining video-adapter observation history was being constructed on every
production stats poll. It is now excluded at compile time for product builds.
Profile enables it only with both debug-hook defines. Debug/tests retain it.
The observation sequence used by actual growth control remains unconditional;
removing diagnostics must not freeze the video ramp.

Two standalone AOT executables (default and with both stand defines) reached
the full 900-kbit/s, 60-FPS target and exposed no diagnostic map with
`dart.vm.product=true`. Marker strings for the removed decision history were
absent from the AOT binary. A debug execution retained diagnostics and the same
full target. The 161 video-policy regressions passed.

The current SDK media source was built normally, with test/CC build flags unset:
105 defined media API exports and no `test`/`fake` exports. No relay configuration
or release artifact was deployed during the audit. Retained test tools live in
`scripts/` and `test/`; they are not app runtime imports.

Reproduce the product-mode behavior check:

```sh
dart compile exe --define=XVEIL_DEBUG_HOOK=true \
  --define=XVEIL_DEBUG_HOOK_PROFILE=true \
  scripts/probe_call_policy_diagnostics.dart -o /private/tmp/policy-product-probe
/private/tmp/policy-product-probe no-diagnostics
dart run scripts/probe_call_policy_diagnostics.dart diagnostics
```
