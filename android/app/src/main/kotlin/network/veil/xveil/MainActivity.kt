package network.veil.xveil

import android.Manifest
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
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
    private val micRequestCode = 0x4D49 // 'MI'
    private var pending: MethodChannel.Result? = null
    private var callActionChannel: MethodChannel? = null
    private var pipEventsChannel: MethodChannel? = null
    private var pendingCallAction: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                val type = call.argument<String>("type") ?: "audio"
                when (call.method) {
                    "status" -> result.success(if (granted(type)) "authorized" else "notDetermined")
                    "request" -> request(type, result)
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
                    else -> result.notImplemented()
                }
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
}
