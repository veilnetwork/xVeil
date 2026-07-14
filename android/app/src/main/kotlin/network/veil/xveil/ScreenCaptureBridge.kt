package network.veil.xveil

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/** Process-local bridge from the MediaProjection service to the Flutter media
 * controller. The service never persists a frame: one byte array is handed to
 * Dart and the next frame is dropped until Dart acknowledges this one. */
object ScreenCaptureBridge {
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var channel: MethodChannel? = null

    fun attach(value: MethodChannel) {
        channel = value
    }

    fun detach(value: MethodChannel) {
        if (channel === value) channel = null
    }

    fun emitFrame(frame: ByteArray, completed: () -> Unit) {
        main.post {
            val current = channel
            if (current == null) {
                completed()
                return@post
            }
            current.invokeMethod("frame", frame, object : MethodChannel.Result {
                override fun success(result: Any?) = completed()
                override fun error(code: String, message: String?, details: Any?) = completed()
                override fun notImplemented() = completed()
            })
        }
    }

    fun emitStopped() {
        main.post { channel?.invokeMethod("stopped", null) }
    }
}
