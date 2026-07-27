# Android Whisper model artifact

`ggml-base-q5_1.bin` is deliberately not tracked. Build
`libveil_whisper.so` with `../build_veil_whisper_android.sh`; the script stages
the matching model here after verifying SHA-256. CI can instead set
`XVEIL_WHISPER_MODEL_SRC` to its cached model.

**The model is no longer packaged into the APK by default.** It is 57 MiB and
does not compress, which made it 63% of the download (89.7 MiB against 32.8 MiB
without) for a feature most people never use. The app fetches it on demand
instead and keeps it once for the whole app, verifying the same pinned size and
SHA-256 this directory's staging step checks. A release build no longer refuses
to proceed without it.

Nothing needs to be staged here for transcription to work — it is only for a
build that must install without a network. Set `XVEIL_BUNDLE_WHISPER_MODEL=1`
for that (Android, macOS and Linux use the same opt-in); the packaging step
then verifies size and SHA-256 again and fails loudly if either is wrong,
because a bundled-but-wrong model is worse than none.
