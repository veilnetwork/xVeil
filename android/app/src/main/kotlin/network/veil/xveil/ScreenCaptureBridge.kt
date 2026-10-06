package network.veil.xveil

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import android.util.Log

/** Process-local bridge from the MediaProjection service to the Flutter media
 * controller. The service never persists a frame: one byte array is handed to
 * Dart and the next frame is dropped until Dart acknowledges this one. */
object ScreenCaptureBridge {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var channel: MethodChannel? = null
    private var firstDelivery = true

    fun attach(value: MethodChannel) {
        channel = value
        firstDelivery = true
    }

    fun detach(value: MethodChannel) {
        if (channel === value) channel = null
    }

    fun emitFrame(frame: ByteArray, completed: () -> Unit) {
        main.post {
            val current = channel
            if (current == null) {
                if (firstDelivery) {
                    firstDelivery = false
                    Log.w("xVeilScreen", "first frame has no Flutter channel")
                }
                completed()
                return@post
            }
            val report = firstDelivery
            firstDelivery = false
            current.invokeMethod("frame", frame, object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (report) Log.i("xVeilScreen", "first Flutter frame acknowledged")
                    completed()
                }
                override fun error(code: String, message: String?, details: Any?) {
                    if (report) Log.w("xVeilScreen", "first Flutter frame rejected code=$code")
                    completed()
                }
                override fun notImplemented() {
                    if (report) Log.w("xVeilScreen", "first Flutter frame has no Dart handler")
                    completed()
                }
            })
        }
    }

    fun emitStopped() {
        main.post { channel?.invokeMethod("stopped", null) }
    }
}
