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
import com.veil.veil_flutter.VeilDaemonService
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
    private var session: String? = null
    private var lastStartId = 0
    private var destroyed = false
    private var finishing = false
    private val stopReplies = mutableListOf<(Exception?) -> Unit>()
    private val main = Handler(android.os.Looper.getMainLooper())
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var workerThread: HandlerThread? = null
    private var worker: Handler? = null
    // ImageReader.close() also invalidates every acquired Image. Keep its
    // lifetime together with conversion, including shutdown from the main thread.
    private val imageLock = Any()
    private val frameInFlight = AtomicBoolean(false)
    private var lastFrameAtNs = 0L
    @Volatile private var shuttingDown = false
    private var stoppedEmitted = false
    private var firstImageLogged = false
    private var firstFrameLogged = false

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            main.post {
                shutdown()
                stopSelfResult(lastStartId)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastStartId = startId
        when (intent?.action) {
            ACTION_START -> startProjection(intent, startId)
            else -> stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }

    private fun startProjection(intent: Intent, startId: Int) {
        val requested = intent.getStringExtra(EXTRA_SESSION) ?: return
        val generation = intent.getLongExtra(EXTRA_GENERATION, -1)
        if (!ScreenCaptureBridge.isCurrent(requested) ||
            VeilDaemonService.startTicket() != generation) {
            ScreenCaptureBridge.emitStopped(requested)
            if (session == null) stopSelfResult(startId)
            return
        }
        if (session != null || current != null) {
            // Never silently report an overlapping consent as a live source.
            ScreenCaptureBridge.emitStopped(requested)
            return
        }
        current = this
        session = requested
        try {
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
            val manager = getSystemService(MediaProjectionManager::class.java)
            val mediaProjection = manager.getMediaProjection(
                intent.getIntExtra(EXTRA_RESULT_CODE, 0),
                token,
            ) ?: throw IllegalStateException("MediaProjection unavailable")
            projection = mediaProjection
            val metrics = resources.displayMetrics
            val scale = min(1f, MAX_EDGE.toFloat() / maxOf(metrics.widthPixels, metrics.heightPixels))
            val width = evenDimension(metrics.widthPixels, scale)
            val height = evenDimension(metrics.heightPixels, scale)
            val thread = HandlerThread("xveil-screen-capture").also { it.start() }
            workerThread = thread
            val handler = Handler(thread.looper)
            worker = handler
            val imageReader = ImageReader.newInstance(
                width,
                height,
                PixelFormat.RGBA_8888,
                2,
            )

            reader = imageReader
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
        synchronized(imageLock) {
            if (shuttingDown || source !== reader) return
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
                ScreenCaptureBridge.emitFrame(session ?: return, frame) { frameInFlight.set(false) }
            } finally {
                image.close()
            }
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
        shutdown()
        stopSelfResult(lastStartId)
    }

    // Only main-thread lifecycle methods enter cleanup. Image conversion holds
    // imageLock; stop waits for it before releasing the reader it references.
    // Keep failed resources owned so a retry is not mistaken for absence.
    private fun shutdown(): Exception? {
        shuttingDown = true
        var failure: Exception? = null
        fun attempt(block: () -> Unit) {
            try { block() } catch (error: Exception) { failure = error }
        }
        synchronized(imageLock) {
            attempt { reader?.setOnImageAvailableListener(null, null) }
            attempt { virtualDisplay?.release(); virtualDisplay = null }
            attempt { reader?.close(); reader = null }
        }
        attempt { projection?.unregisterCallback(projectionCallback) }
        attempt { projection?.stop(); projection = null }
        attempt {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        }
        return failure
    }

    private fun finishStop() {
        if (finishing) return
        finishing = true
        var failure = shutdown()
        val thread = workerThread
        try {
            if (thread != null && !thread.quitSafely() && thread.isAlive) {
                throw IllegalStateException("Capture worker did not accept shutdown")
            }
        } catch (error: Exception) { failure = error }
        val joinWorker = thread == null || !thread.isAlive || failure == null
        // Never block the main looper waiting for a worker. Acknowledgement is
        // after its actual exit, including its last accepted conversion.
        Thread({
            var error = failure
            try { if (joinWorker) thread?.join() } catch (caught: InterruptedException) { error = caught }
            main.post {
                finishing = false
                if (error == null) {
                    workerThread = null
                    worker = null
                    frameInFlight.set(false)
                    if (current === this) current = null
                    if (!stoppedEmitted) {
                        stoppedEmitted = true
                        session?.let(ScreenCaptureBridge::emitStopped)
                    }
                }
                val replies = stopReplies.toList()
                stopReplies.clear()
                replies.forEach { it(error) }
            }
        }, "xveil-screen-stop").apply { isDaemon = true; start() }
    }

    override fun onDestroy() {
        destroyed = true
        finishStop()
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
        private const val EXTRA_SESSION = "captureSession"
        private const val EXTRA_GENERATION = "captureGeneration"
        @Volatile private var current: ScreenCaptureService? = null

        fun hasUnreleasedCapture(): Boolean = current != null
        private const val NOTIFICATION_CHANNEL = "xveil_screen_share"
        private const val NOTIFICATION_ID = 0x585653
        private const val MAX_EDGE = 640
        private const val FRAME_GAP_NS = 100_000_000L // 10fps
        private const val TAG = "xVeilScreen"

        fun start(context: Context, session: String, generation: Long, resultCode: Int, data: Intent) {
            val intent = Intent(context, ScreenCaptureService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_DATA, data)
                putExtra(EXTRA_SESSION, session)
                putExtra(EXTRA_GENERATION, generation)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context, session: String, completed: (Exception?) -> Unit) {
            val owned = current
            if (owned == null || owned.session != session) {
                // Its queued START is already fenced by the bridge. Never stop
                // an unrelated service instance by class name.
                completed(null)
                return
            }
            owned.stopReplies.add(completed)
            if (owned.destroyed) {
                owned.finishStop()
                return
            }
            try {
                check(context.stopService(Intent(context, ScreenCaptureService::class.java)))
            } catch (error: Exception) {
                owned.stopReplies.remove(completed)
                completed(error)
            }
        }

        private fun evenDimension(value: Int, scale: Float): Int =
            maxOf(2, (value * scale).toInt() and -2)

        private fun clampByte(value: Int): Byte = value.coerceIn(0, 255).toByte()
    }
}
