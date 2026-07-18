package network.veil.xveil

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.util.Range
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

/**
 * Call-only Camera2 capture path.
 *
 * The Flutter camera plugins serialize every YUV plane through a platform
 * channel before Dart copies it into the media FFI buffer. Besides spending
 * two full-frame copies, the callback shares the UI isolate with the call
 * overlay and periodically stalls both the preview and the sender. This class
 * keeps preview on a SurfaceTexture and hands ImageReader's direct buffers to
 * libveil_media from a camera HandlerThread. No camera pixels cross Dart.
 */
class NativeCallCamera(
    context: Context,
    private val textures: TextureRegistry,
) {
    private val cameraManager =
        context.applicationContext.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null
    private var imageReader: ImageReader? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null

    @Volatile private var engineAddress: Long = 0
    @Volatile private var running = false
    @Volatile private var pendingStartReply: ((Map<String, Any?>?, String?) -> Unit)? = null
    private val statsLock = Any()
    private var inputFrames = 0L
    private var pushedFrames = 0L
    private var firstInputNs = 0L
    private var lastInputNs = 0L
    private var maxInputGapNs = 0L
    private var inputHolds75Ms = 0L
    private var maxPushNs = 0L
    private var pushHolds16Ms = 0L
    private var pushHolds33Ms = 0L
    private var selectedFps = 0

    companion object {
        init {
            System.loadLibrary("veil_media")
        }
    }

    private external fun nativePushAndroid420(
        engineAddress: Long,
        y: java.nio.ByteBuffer,
        u: java.nio.ByteBuffer,
        v: java.nio.ByteBuffer,
        width: Int,
        height: Int,
        yStride: Int,
        uStride: Int,
        vStride: Int,
        uvPixelStride: Int,
        rotation: Int,
        timestampUs: Long,
    ): Int

    @SuppressLint("MissingPermission")
    fun start(
        engineAddress: Long,
        requestedWidth: Int,
        requestedHeight: Int,
        requestedFps: Int,
        reply: (Map<String, Any?>?, String?) -> Unit,
    ) {
        stop()
        if (engineAddress == 0L) {
            reply(null, "media engine is not available")
            return
        }
        val replied = AtomicBoolean(false)
        lateinit var finish: (Map<String, Any?>?, String?) -> Unit
        finish = { value, error ->
            if (replied.compareAndSet(false, true)) {
                if (pendingStartReply === finish) pendingStartReply = null
                reply(value, error)
            }
        }
        pendingStartReply = finish

        try {
            val cameraId = chooseFrontCamera()
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val size = chooseCommonSize(
                characteristics,
                requestedWidth.coerceAtLeast(160),
                requestedHeight.coerceAtLeast(120),
            )
            val fpsRange = chooseStableFps(characteristics, requestedFps.coerceIn(10, 60))
            val sensorRotation =
                (characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0) % 360
            val mirror =
                characteristics.get(CameraCharacteristics.LENS_FACING) ==
                    CameraCharacteristics.LENS_FACING_FRONT

            val cameraThread = HandlerThread("xveil-call-camera").also { it.start() }
            val cameraHandler = Handler(cameraThread.looper)
            thread = cameraThread
            handler = cameraHandler
            this.engineAddress = engineAddress
            selectedFps = fpsRange.upper
            resetStats()

            val entry = textures.createSurfaceTexture()
            textureEntry = entry
            entry.surfaceTexture().setDefaultBufferSize(size.width, size.height)
            val preview = Surface(entry.surfaceTexture())
            previewSurface = preview
            val reader = ImageReader.newInstance(
                size.width,
                size.height,
                ImageFormat.YUV_420_888,
                3,
            )
            imageReader = reader
            reader.setOnImageAvailableListener({ source -> onImage(source, sensorRotation) }, cameraHandler)

            cameraManager.openCamera(
                cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        if (this@NativeCallCamera.engineAddress == 0L) {
                            device.close()
                            return
                        }
                        cameraDevice = device
                        val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                            addTarget(preview)
                            addTarget(reader.surface)
                            set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                            set(
                                CaptureRequest.CONTROL_AF_MODE,
                                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO,
                            )
                            set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, fpsRange)
                        }
                        device.createCaptureSession(
                            listOf(preview, reader.surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(session: CameraCaptureSession) {
                                    if (this@NativeCallCamera.engineAddress == 0L) {
                                        session.close()
                                        return
                                    }
                                    captureSession = session
                                    session.setRepeatingRequest(request.build(), null, cameraHandler)
                                    running = true
                                    finish(
                                        mapOf(
                                            "textureId" to entry.id(),
                                            "width" to size.width,
                                            "height" to size.height,
                                            "rotation" to sensorRotation,
                                            "mirror" to mirror,
                                            "fps" to fpsRange.upper,
                                            "cameraId" to cameraId,
                                        ),
                                        null,
                                    )
                                }

                                override fun onConfigureFailed(session: CameraCaptureSession) {
                                    finish(null, "Camera2 session configuration failed")
                                    stop()
                                }
                            },
                            cameraHandler,
                        )
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        device.close()
                        finish(null, "Camera2 device disconnected")
                        stop()
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        device.close()
                        finish(null, "Camera2 device error $error")
                        stop()
                    }
                },
                cameraHandler,
            )
        } catch (error: Exception) {
            finish(null, error.toString())
            stop()
        }
    }

    /**
     * Stop capture and optionally run [done] after the camera handler has
     * drained. The drain is important: an ImageReader callback may still be
     * inside nativePushAndroid420 when Flutter asks to destroy the media
     * engine. Waiting for the handler fence makes that pointer lifetime exact.
     */
    fun stop(done: (() -> Unit)? = null) {
        engineAddress = 0
        running = false
        val pending = pendingStartReply
        pendingStartReply = null
        pending?.invoke(null, "Camera2 start cancelled")
        val oldHandler = handler
        val oldThread = thread
        try {
            imageReader?.setOnImageAvailableListener(null, null)
        } catch (_: Exception) {}
        try {
            captureSession?.stopRepeating()
        } catch (_: Exception) {}
        try {
            captureSession?.close()
        } catch (_: Exception) {}
        captureSession = null
        try {
            cameraDevice?.close()
        } catch (_: Exception) {}
        cameraDevice = null
        try {
            imageReader?.close()
        } catch (_: Exception) {}
        imageReader = null
        try {
            previewSurface?.release()
        } catch (_: Exception) {}
        previewSurface = null
        try {
            textureEntry?.release()
        } catch (_: Exception) {}
        textureEntry = null
        handler = null
        thread = null
        if (oldHandler != null && oldThread != null && oldThread.isAlive &&
            Looper.myLooper() != oldHandler.looper
        ) {
            val posted = oldHandler.post {
                oldThread.quitSafely()
                done?.invoke()
            }
            if (posted) return
        }
        oldThread?.quitSafely()
        done?.invoke()
    }

    fun stats(): Map<String, Any> = synchronized(statsLock) {
        val elapsed = lastInputNs - firstInputNs
        val fps = if (inputFrames >= 2 && elapsed > 0) {
            (inputFrames - 1).toDouble() * 1_000_000_000.0 / elapsed.toDouble()
        } else {
            0.0
        }
        mapOf(
            "camera_native" to true,
            "camera_requested_fps" to selectedFps,
            "camera_capture_fps" to ((fps * 10.0).toInt() / 10.0),
            "camera_capture_frames" to inputFrames,
            "camera_processed_frames" to pushedFrames,
            "camera_capture_max_gap_ms" to maxInputGapNs / 1_000_000,
            "camera_capture_holds_75ms" to inputHolds75Ms,
            "camera_push_max_ms" to maxPushNs / 1_000_000.0,
            "camera_push_holds_16ms" to pushHolds16Ms,
            "camera_push_holds_33ms" to pushHolds33Ms,
            "camera_running" to running,
        )
    }

    private fun resetStats() = synchronized(statsLock) {
        inputFrames = 0
        pushedFrames = 0
        firstInputNs = 0
        lastInputNs = 0
        maxInputGapNs = 0
        inputHolds75Ms = 0
        maxPushNs = 0
        pushHolds16Ms = 0
        pushHolds33Ms = 0
    }

    private fun onImage(source: ImageReader, rotation: Int) {
        val image = source.acquireLatestImage() ?: return
        try {
            val address = engineAddress
            val planes = image.planes
            if (address == 0L || planes.size < 3) return
            val nowNs = SystemClock.elapsedRealtimeNanos()
            synchronized(statsLock) {
                if (firstInputNs == 0L) firstInputNs = nowNs
                if (lastInputNs != 0L) {
                    val gap = nowNs - lastInputNs
                    if (gap > maxInputGapNs) maxInputGapNs = gap
                    if (gap >= 75_000_000L) inputHolds75Ms++
                }
                lastInputNs = nowNs
                inputFrames++
            }
            val uvPixelStride = planes[1].pixelStride
            if (uvPixelStride != planes[2].pixelStride) return
            val startedNs = SystemClock.elapsedRealtimeNanos()
            val rc = nativePushAndroid420(
                address,
                planes[0].buffer.slice(),
                planes[1].buffer.slice(),
                planes[2].buffer.slice(),
                image.width,
                image.height,
                planes[0].rowStride,
                planes[1].rowStride,
                planes[2].rowStride,
                uvPixelStride,
                rotation,
                image.timestamp / 1_000,
            )
            val pushNs = SystemClock.elapsedRealtimeNanos() - startedNs
            synchronized(statsLock) {
                if (rc == 0) pushedFrames++
                if (pushNs > maxPushNs) maxPushNs = pushNs
                if (pushNs >= 16_000_000L) pushHolds16Ms++
                if (pushNs >= 33_000_000L) pushHolds33Ms++
            }
        } finally {
            image.close()
        }
    }

    private fun chooseFrontCamera(): String {
        return cameraManager.cameraIdList.firstOrNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_FRONT
        } ?: cameraManager.cameraIdList.firstOrNull()
        ?: throw IllegalStateException("No camera is available")
    }

    private fun chooseCommonSize(
        characteristics: CameraCharacteristics,
        requestedWidth: Int,
        requestedHeight: Int,
    ): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: throw IllegalStateException("Camera has no stream configuration map")
        val previewSizes = map.getOutputSizes(SurfaceTexture::class.java)?.toList().orEmpty()
        val yuvSizes = map.getOutputSizes(ImageFormat.YUV_420_888)?.toSet().orEmpty()
        val common = previewSizes.filter { it in yuvSizes }
        if (common.isEmpty()) throw IllegalStateException("Camera has no common preview/YUV size")
        val targetArea = requestedWidth.toLong() * requestedHeight.toLong()
        val targetRatio = requestedWidth.toDouble() / requestedHeight.toDouble()
        return common.minByOrNull { size ->
            val area = size.width.toLong() * size.height.toLong()
            val areaError = abs(area - targetArea).toDouble() / targetArea.toDouble()
            val ratioError = abs(size.width.toDouble() / size.height.toDouble() - targetRatio)
            ratioError * 8.0 + areaError
        }!!
    }

    private fun chooseStableFps(
        characteristics: CameraCharacteristics,
        requestedFps: Int,
    ): Range<Int> {
        val ranges = characteristics.get(
            CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES,
        )?.toList().orEmpty()
        if (ranges.isEmpty()) return Range(30, 30)
        val exact = ranges.filter { it.lower == it.upper && it.upper in 10..60 }
        exact.firstOrNull { it.upper == requestedFps }?.let { return it }
        exact.firstOrNull { it.upper == 30 }?.let { return it }
        exact.maxByOrNull { it.upper }?.let { return it }
        return ranges
            .filter { it.upper >= 10 }
            .minWithOrNull(
                compareBy<Range<Int>>(
                    { abs(it.upper - requestedFps) },
                    { it.upper - it.lower },
                ),
            ) ?: ranges.first()
    }
}
