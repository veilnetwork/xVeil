package network.veil.xveil

import android.Manifest
import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.util.Rational
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Handles the `xveil/media_permissions` MethodChannel (mirrors the macOS
 * MainFlutterWindow handler) so the call media controller can request the
 * RECORD_AUDIO runtime grant before the veil audio engine opens an AAudio
 * capture stream. Camera maps to CAMERA for the video path.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "xveil/media_permissions"
    private val pipChannelName = "xveil/pip"
    private val pipEventsChannelName = "xveil/pip_events"
    private val callActionChannelName = "xveil/call_actions"
    private val screenCaptureChannelName = "xveil/screen_capture"
    private val cameraCapabilitiesChannelName = "xveil/camera_capabilities"
    private val nativeCallCameraChannelName = "xveil/native_call_camera"
    private val micRequestCode = 0x4D49 // 'MI'
    private val screenCaptureRequestCode = 0x5343 // 'SC'
    private var pending: MethodChannel.Result? = null
    private var pendingScreenCapture: MethodChannel.Result? = null
    private var callActionChannel: MethodChannel? = null
    private var pipEventsChannel: MethodChannel? = null
    private var screenCaptureChannel: MethodChannel? = null
    private var nativeCallCamera: NativeCallCamera? = null
    private var pendingCallAction: String? = null
    private var pipAutoWanted = false
    private var pipAspect = Rational(16, 9)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeCallCamera = NativeCallCamera(this, flutterEngine.renderer)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val type = call.argument<String>("type") ?: "audio"
                when (call.method) {
                    "status" -> result.success(if (granted(type)) "authorized" else "notDetermined")
                    "request" -> request(type, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            cameraCapabilitiesChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "exactFps" -> {
                    val cameraId = call.argument<String>("cameraId")
                    if (cameraId == null) {
                        result.error("bad_args", "cameraId required", null)
                    } else {
                        result.success(exactCameraFps(cameraId))
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            nativeCallCameraChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (!granted("video")) {
                        result.error("permission", "Camera permission is not granted", null)
                        return@setMethodCallHandler
                    }
                    val engine = call.argument<Number>("engine")?.toLong() ?: 0L
                    val width = call.argument<Int>("width") ?: 640
                    val height = call.argument<Int>("height") ?: 480
                    val fps = call.argument<Int>("fps") ?: 30
                    nativeCallCamera?.start(engine, width, height, fps) { value, error ->
                        runOnUiThread {
                            if (error == null) {
                                result.success(value)
                            } else {
                                result.error("camera_start", error, null)
                            }
                        }
                    } ?: result.error("camera_start", "Camera bridge is unavailable", null)
                }
                "stop" -> {
                    val camera = nativeCallCamera
                    if (camera == null) {
                        result.success(true)
                    } else {
                        camera.stop { runOnUiThread { result.success(true) } }
                    }
                }
                "stats" -> result.success(nativeCallCamera?.stats() ?: emptyMap<String, Any>())
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "enter" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val width = call.argument<Int>("width") ?: 16
                            val height = call.argument<Int>("height") ?: 9
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational(width, height))
                                .build()
                            result.success(enterPictureInPictureMode(params))
                        } else {
                            result.success(false)
                        }
                    }
                    // Leave an ACTIVE PiP window (call ended / lost its video).
                    // There is no direct "exit PiP" API; finishing the activity
                    // would tear down the Flutter engine (and the embedded
                    // node's Dart owners) — moveTaskToBack unpins the task and
                    // dismisses the window while keeping the activity alive.
                    "exit" -> {
                        val inPip =
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                                isInPictureInPictureMode
                        if (inPip) moveTaskToBack(true)
                        result.success(inPip)
                    }
                    // Arm/disarm PiP for the CURRENT video call. Dart's
                    // paused-lifecycle callback fires after the activity has
                    // already left the resumed state, when the platform refuses
                    // enterPictureInPictureMode — so backgrounding a video call
                    // froze the peer's view instead of continuing in PiP. The
                    // supported paths are autoEnter params (API 31+) and
                    // onUserLeaveHint (below) for older releases.
                    "setAuto" -> {
                        pipAutoWanted = call.argument<Boolean>("enabled") ?: false
                        val width = call.argument<Int>("width") ?: 16
                        val height = call.argument<Int>("height") ?: 9
                        pipAspect = Rational(width, height)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            try {
                                setPictureInPictureParams(
                                    PictureInPictureParams.Builder()
                                        .setAspectRatio(pipAspect)
                                        .setAutoEnterEnabled(pipAutoWanted)
                                        .build()
                                )
                                android.util.Log.i(
                                    "xveil-pip",
                                    "setAuto applied enabled=$pipAutoWanted"
                                )
                            } catch (error: Exception) {
                                // PiP unsupported/disabled by device policy —
                                // surface it, a silent drop cost a debug cycle.
                                android.util.Log.w(
                                    "xveil-pip",
                                    "setPictureInPictureParams failed: $error"
                                )
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        screenCaptureChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            screenCaptureChannelName,
        ).also { channel ->
            ScreenCaptureBridge.attach(channel)
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> requestScreenCapture(result)
                    "stop" -> {
                        stopScreenCapture()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Media epic: one representative frame of a video the user is SENDING
        // (their own plaintext source file) for the message micro-thumb.
        // MediaMetadataRetriever decodes — keep it off the UI thread.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "xveil/video_thumb")
            .setMethodCallHandler { call, result ->
                if (call.method != "frame") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("bad_args", "path required", null)
                    return@setMethodCallHandler
                }
                val maxDim = call.argument<Int>("maxDim") ?: 64
                Thread {
                    val bytes = grabVideoFrame(path, maxDim)
                    // No decodable frame is a normal outcome (unsupported
                    // codec, audio-only container) — null, not an error.
                    runOnUiThread { result.success(bytes) }
                }.start()
            }
        pipEventsChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            pipEventsChannelName,
        )
        callActionChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            callActionChannelName,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumeInitialAction" -> {
                        val action = pendingCallAction ?: callActionFrom(intent)
                        pendingCallAction = null
                        result.success(action)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        deliverCallAction(intent)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Pre-API-31 has no autoEnter params; this hint is the only moment the
        // platform still accepts a programmatic PiP entry on the way out.
        if (pipAutoWanted &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S
        ) {
            try {
                enterPictureInPictureMode(
                    PictureInPictureParams.Builder()
                        .setAspectRatio(pipAspect)
                        .build()
                )
            } catch (_: Exception) {
            }
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: android.content.res.Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipEventsChannel?.invokeMethod(
            "pipChanged",
            isInPictureInPictureMode,
        )
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverCallAction(intent)
    }

    private fun requestScreenCapture(result: MethodChannel.Result) {
        if (pendingScreenCapture != null) {
            result.success(false)
            return
        }
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingScreenCapture = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(manager.createScreenCaptureIntent(), screenCaptureRequestCode)
        } catch (error: Exception) {
            pendingScreenCapture = null
            result.error("screen_capture", error.message, null)
        }
    }

    /**
     * Exact AE target ranges supported by the selected Camera2 device.
     *
     * Querying Camera2 before configuring the Flutter controller avoids asking
     * the backend for an unsupported fixed range (for example 60..60, which a
     * compatibility layer may silently broaden to 10..30). Returning only
     * lower==upper ranges lets Dart preserve 60 fps on capable cameras while
     * choosing a stable 30 on the common front-camera profile that tops out
     * there.
     */
    private fun exactCameraFps(cameraId: String): List<Int> {
        return try {
            val manager = getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val characteristics = manager.getCameraCharacteristics(cameraId)
            val ranges = characteristics.get(
                CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES,
            ) ?: emptyArray()
            ranges
                .filter { it.lower == it.upper && it.upper > 0 }
                .map { it.upper }
                .distinct()
                .sorted()
        } catch (error: Exception) {
            android.util.Log.w(
                "xveil-camera",
                "Unable to query exact FPS ranges for camera $cameraId: $error",
            )
            emptyList()
        }
    }

    @Deprecated("MediaProjection consent still uses the platform activity-result contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == screenCaptureRequestCode) {
            val result = pendingScreenCapture
            pendingScreenCapture = null
            if (result == null) return
            if (resultCode == Activity.RESULT_OK && data != null) {
                try {
                    ScreenCaptureService.start(this, resultCode, data)
                    result.success(true)
                } catch (error: Exception) {
                    result.error("screen_capture", error.message, null)
                }
            } else {
                result.success(false)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    /**
     * First decodable frame of the video at [path], downscaled so its longest
     * side is [maxDim], JPEG-encoded. Null on any failure — the thumb is
     * always optional.
     */
    private fun grabVideoFrame(path: String, maxDim: Int): ByteArray? {
        val retriever = android.media.MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            // A hair in (100ms) rather than 0: many encodes open on a
            // black/blank frame; CLOSEST_SYNC keeps it cheap on any API level.
            val frame = retriever.getFrameAtTime(
                100_000L,
                android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: return null
            val scale = maxDim.toFloat() / maxOf(frame.width, frame.height)
            val scaled = if (scale >= 1f) frame else android.graphics.Bitmap.createScaledBitmap(
                frame,
                maxOf(1, (frame.width * scale).toInt()),
                maxOf(1, (frame.height * scale).toInt()),
                true,
            )
            val out = java.io.ByteArrayOutputStream()
            scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, out)
            out.toByteArray()
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun permFor(type: String) =
        if (type == "video") Manifest.permission.CAMERA else Manifest.permission.RECORD_AUDIO

    private fun granted(type: String) =
        ContextCompat.checkSelfPermission(this, permFor(type)) ==
            PackageManager.PERMISSION_GRANTED

    private fun request(type: String, result: MethodChannel.Result) {
        if (granted(type)) {
            result.success(true)
            return
        }
        if (pending != null) {
            // A request is already in flight; don't stack the system dialog.
            result.success(false)
            return
        }
        pending = result
        ActivityCompat.requestPermissions(this, arrayOf(permFor(type)), micRequestCode)
    }

    private fun callActionFrom(intent: Intent?): String? =
        intent?.getStringExtra("xveil_call_action")

    private fun deliverCallAction(intent: Intent?) {
        val action = callActionFrom(intent) ?: return
        val channel = callActionChannel
        if (channel == null) {
            pendingCallAction = action
        } else {
            channel.invokeMethod("callAction", action)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == micRequestCode) {
            val ok = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pending?.success(ok)
            pending = null
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        nativeCallCamera?.stop()
        nativeCallCamera = null
        stopScreenCapture()
        screenCaptureChannel?.let(ScreenCaptureBridge::detach)
        screenCaptureChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun stopScreenCapture() {
        val pendingResult = pendingScreenCapture
        pendingScreenCapture = null
        if (pendingResult != null) {
            try {
                @Suppress("DEPRECATION")
                finishActivity(screenCaptureRequestCode)
            } catch (_: Exception) {
            }
            pendingResult.success(false)
        }
        ScreenCaptureService.stop(this)
    }
}
