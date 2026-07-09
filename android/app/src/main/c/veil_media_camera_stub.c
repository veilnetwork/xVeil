// Android's media path feeds camera frames from Dart through pushVideoFrame().
// The current prebuilt libveil_media.so was compiled with Android satisfying
// __linux__, so it still has an unresolved Linux platform-camera factory symbol.
// Export a no-op definition to let dlopen succeed; Android never calls it.
void* veil_media_android_noop_platform_camera(void*)
    __asm__(
        "_ZN10veil_media20CreatePlatformCameraENSt4__Cr8functionIFvPKhS3_S3_"
        "iiiiilEEE");

void* veil_media_android_noop_platform_camera(void* cb) {
  (void)cb;
  return 0;
}
