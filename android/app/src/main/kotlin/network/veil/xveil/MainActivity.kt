package network.veil.xveil

import android.Manifest
import android.content.pm.PackageManager
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
    private val micRequestCode = 0x4D49 // 'MI'
    private var pending: MethodChannel.Result? = null

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
