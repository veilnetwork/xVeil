package network.veil.xveil

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.Image
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import androidx.core.content.ContextCompat
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min

/**
 * User-consented Android screen source for veil_media.
 *
 * The projection renders into a small in-memory RGBA ImageReader. A worker
 * converts the latest frame to I420 and the Flutter controller immediately
 * pushes it into the existing VP8 source. There is deliberately no
 * MediaRecorder, file, cache, or screenshot path here.
 */
class ScreenCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var workerThread: HandlerThread? = null
    private var worker: Handler? = null
    private val frameInFlight = AtomicBoolean(false)
    private var lastFrameAtNs = 0L
    private var shuttingDown = false
    private var stoppedEmitted = false
    private var firstImageLogged = false
    private var firstFrameLogged = false

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            shutdown(emitStopped = true)
            stopSelf()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startProjection(intent)
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startProjection(intent: Intent) {
        if (projection != null || shuttingDown) return
        createNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        val token = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_DATA)
        }
        if (token == null) {
            failStart()
            return
        }
        try {
            val manager = getSystemService(MediaProjectionManager::class.java)
            val mediaProjection = manager.getMediaProjection(
                intent.getIntExtra(EXTRA_RESULT_CODE, 0),
                token,
            ) ?: throw IllegalStateException("MediaProjection unavailable")
            val metrics = resources.displayMetrics
            val scale = min(1f, MAX_EDGE.toFloat() / maxOf(metrics.widthPixels, metrics.heightPixels))
            val width = evenDimension(metrics.widthPixels, scale)
            val height = evenDimension(metrics.heightPixels, scale)
            val thread = HandlerThread("xveil-screen-capture").also { it.start() }
            val handler = Handler(thread.looper)
            val imageReader = ImageReader.newInstance(
                width,
                height,
                PixelFormat.RGBA_8888,
                2,
            )

            workerThread = thread
            worker = handler
            reader = imageReader
            projection = mediaProjection
            mediaProjection.registerCallback(projectionCallback, handler)
            imageReader.setOnImageAvailableListener(::onImageAvailable, handler)
            virtualDisplay = mediaProjection.createVirtualDisplay(
                "xVeil screen share",
                width,
                height,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader.surface,
                null,
                handler,
            )
            XVeilLog.i(this, TAG) { "projection started ${width}x${height}" }
        } catch (_: Exception) {
            failStart()
        }
    }

    private fun onImageAvailable(source: ImageReader) {
        val image = try {
            source.acquireLatestImage()
        } catch (_: Exception) {
            null
        } ?: return
        try {
            if (!firstImageLogged) {
                firstImageLogged = true
                val plane = image.planes.firstOrNull()
                XVeilLog.i(this, TAG) {
                    "first image ${image.width}x${image.height} " +
                        "pixelStride=${plane?.pixelStride} rowStride=${plane?.rowStride}"
                }
            }
            val now = System.nanoTime()
            if (now - lastFrameAtNs < FRAME_GAP_NS || !frameInFlight.compareAndSet(false, true)) {
                return
            }
            lastFrameAtNs = now
            val frame = rgbaToI420(image)
            if (frame == null) {
                XVeilLog.w(this, TAG) { "RGBA to I420 conversion rejected a frame" }
                frameInFlight.set(false)
                return
            }
            if (!firstFrameLogged) {
                firstFrameLogged = true
                XVeilLog.i(this, TAG) { "first I420 frame bytes=${frame.size}" }
            }
            ScreenCaptureBridge.emitFrame(frame) { frameInFlight.set(false) }
        } finally {
            image.close()
        }
    }

    private fun rgbaToI420(image: Image): ByteArray? {
        val plane = image.planes.firstOrNull() ?: return null
        val width = image.width
        val height = image.height
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        if (pixelStride < 3 || width < 2 || height < 2) return null
        val source = plane.buffer
        val chromaWidth = (width + 1) / 2
        val chromaHeight = (height + 1) / 2
        val yLength = width * height
        val chromaLength = chromaWidth * chromaHeight
        val output = ByteBuffer.allocate(8 + yLength + chromaLength * 2)
        output.putInt(width)
        output.putInt(height)
        val bytes = output.array()
        val yOffset = 8
        val uOffset = yOffset + yLength
        val vOffset = uOffset + chromaLength

        for (y in 0 until height) {
            val row = y * rowStride
            for (x in 0 until width) {
                val rgb = row + x * pixelStride
                if (rgb + 2 >= source.limit()) return null
                val r = source.get(rgb).toInt() and 0xff
                val g = source.get(rgb + 1).toInt() and 0xff
                val b = source.get(rgb + 2).toInt() and 0xff
                bytes[yOffset + y * width + x] = clampByte(((66 * r + 129 * g + 25 * b + 128) shr 8) + 16)
            }
        }
        for (y in 0 until height step 2) {
            for (x in 0 until width step 2) {
                var uSum = 0
                var vSum = 0
                var count = 0
                for (dy in 0..1) {
                    val sy = y + dy
                    if (sy >= height) continue
                    for (dx in 0..1) {
                        val sx = x + dx
                        if (sx >= width) continue
                        val rgb = sy * rowStride + sx * pixelStride
                        val r = source.get(rgb).toInt() and 0xff
                        val g = source.get(rgb + 1).toInt() and 0xff
                        val b = source.get(rgb + 2).toInt() and 0xff
                        uSum += ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                        vSum += ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                        count++
                    }
                }
                val chroma = (y / 2) * chromaWidth + x / 2
                bytes[uOffset + chroma] = clampByte(uSum / count)
                bytes[vOffset + chroma] = clampByte(vSum / count)
            }
        }
        return bytes
    }

    private fun failStart() {
        shutdown(emitStopped = true)
        stopSelf()
    }

    private fun shutdown(emitStopped: Boolean) {
        if (shuttingDown) return
        shuttingDown = true
        reader?.setOnImageAvailableListener(null, null)
        virtualDisplay?.release()
        virtualDisplay = null
        reader?.close()
        reader = null
        val activeProjection = projection
        projection = null
        if (activeProjection != null) {
            try {
                activeProjection.unregisterCallback(projectionCallback)
            } catch (_: Exception) {
            }
            try {
                activeProjection.stop()
            } catch (_: Exception) {
            }
        }
        workerThread?.quitSafely()
        workerThread = null
        worker = null
        frameInFlight.set(false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        if (emitStopped && !stoppedEmitted) {
            stoppedEmitted = true
            ScreenCaptureBridge.emitStopped()
        }
    }

    override fun onDestroy() {
        shutdown(emitStopped = true)
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                getString(R.string.screen_share_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.screen_share_channel_description)
            },
        )
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("xVeil")
            .setContentText(getString(R.string.screen_share_notification_text))
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(openApp)
            .build()
    }

    companion object {
        private const val ACTION_START = "network.veil.xveil.screen.START"
        private const val EXTRA_RESULT_CODE = "resultCode"
        private const val EXTRA_DATA = "data"
        private const val NOTIFICATION_CHANNEL = "xveil_screen_share"
        private const val NOTIFICATION_ID = 0x585653
        private const val MAX_EDGE = 640
        private const val FRAME_GAP_NS = 100_000_000L // 10fps
        private const val TAG = "xVeilScreen"

        fun start(context: Context, resultCode: Int, data: Intent) {
            val intent = Intent(context, ScreenCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_DATA, data)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, ScreenCaptureService::class.java))
        }

        private fun evenDimension(value: Int, scale: Float): Int =
            maxOf(2, (value * scale).toInt() and -2)

        private fun clampByte(value: Int): Byte = value.coerceIn(0, 255).toByte()
    }
}
