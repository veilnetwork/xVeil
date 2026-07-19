# Android Whisper model artifact

`ggml-base-q5_1.bin` is deliberately not tracked. Build
`libveil_whisper.so` with `../build_veil_whisper_android.sh`; the script stages
the matching model here after verifying SHA-256. CI can instead set
`XVEIL_WHISPER_MODEL_SRC` to its cached model.

The Android Gradle build verifies the size and SHA-256 again, packages the
model into APK/AAB assets, and refuses a release build when the model is absent.
