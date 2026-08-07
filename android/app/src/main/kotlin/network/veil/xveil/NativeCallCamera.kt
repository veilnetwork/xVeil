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
import android.os.Process
import android.os.SystemClock
import android.util.Range
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
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
    private var processingThread: HandlerThread? = null
    private var processingHandler: Handler? = null
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
    private var replacedFrames = 0L
    private var selectedFps = 0
    private val pendingImage = AtomicReference<android.media.Image?>(null)
    private val processorScheduled = AtomicBoolean(false)

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
        requestedCameraId: String?,
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
            val cameraId = chooseCamera(requestedCameraId)
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

            // Camera2 reports ImageReader availability on this looper. Keep it
            // at display priority and do only acquire/enqueue work here: a
            // default-priority callback was visibly starved by the raster and
            // WebRTC queues during a call, producing 75-100 ms holes in BOTH
            // the SurfaceTexture preview and the encoded stream.
            val cameraThread = HandlerThread(
                "xveil-call-camera",
                Process.THREAD_PRIORITY_DISPLAY,
            ).also { it.start() }
            val cameraHandler = Handler(cameraThread.looper)
            val frameThread = HandlerThread("xveil-call-frame-copy").also { it.start() }
            val frameHandler = Handler(frameThread.looper)
            // Some OEM HandlerThread implementations publish the Looper
            // before applying the constructor priority. Set it again from the
            // owning threads so the policy is effective before camera open.
            cameraHandler.post {
                // THREAD_PRIORITY_DISPLAY is silently reset by this Xiaomi
                // Camera2 stack; -1 is retained (verified through /proc/top)
                // and still keeps availability callbacks ahead of normal work.
                Process.setThreadPriority(Process.THREAD_PRIORITY_MORE_FAVORABLE)
            }
            frameHandler.post {
                Process.setThreadPriority(Process.THREAD_PRIORITY_MORE_FAVORABLE)
            }
            thread = cameraThread
            handler = cameraHandler
            processingThread = frameThread
            processingHandler = frameHandler
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
                            // TEMPLATE_RECORD enables SIMPLE face detection on
                            // this OEM and feeds a face-priority scene pipeline.
                            // A call needs stable low-latency frames, not face
                            // metadata; explicitly bypass that variable-cost
                            // analysis while retaining normal AE/AWB/AF.
                            set(
                                CaptureRequest.STATISTICS_FACE_DETECT_MODE,
                                CaptureRequest.STATISTICS_FACE_DETECT_MODE_OFF,
                            )
                            set(
                                CaptureRequest.CONTROL_SCENE_MODE,
                                CaptureRequest.CONTROL_SCENE_MODE_DISABLED,
                            )
                            // The Xiaomi HAL selected its
                            // `ZSLPreviewRawForThirdPartyApp` graph even for
                            // TEMPLATE_RECORD. That graph retains/reorders raw
                            // frames for zero-shutter-lag still capture, which
                            // is useless in a call and showed up as a repeated
                            // pause-then-burst cadence at ImageReader. Disable
                            // it explicitly when this optional request key is
                            // advertised by the device.
                            if (characteristics.availableCaptureRequestKeys
                                    ?.contains(CaptureRequest.CONTROL_ENABLE_ZSL) == true
                            ) {
                                set(CaptureRequest.CONTROL_ENABLE_ZSL, false)
                            }
                            // Qualcomm's third-party video pipeline otherwise
                            // keeps the GME/EIS stages live. On this Xiaomi the
                            // GME node intermittently blocked 100-220 ms; the
                            // Camera2 input cadence and the remote video froze
                            // at exactly those timestamps even though native
                            // frame push, encoder, P2P and renderer were idle.
                            // A call at 640x360 benefits more from deterministic
                            // cadence than from crop-based stabilization.
                            val videoStabilizationModes = characteristics.get(
                                CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES,
                            )
                            if (videoStabilizationModes?.contains(
                                    CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
                                ) == true
                            ) {
                                set(
                                    CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                                    CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
                                )
                            }
                            val opticalStabilizationModes = characteristics.get(
                                CameraCharacteristics.LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION,
                            )
                            if (opticalStabilizationModes?.contains(
                                    CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
                                ) == true
                            ) {
                                set(
                                    CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                                    CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
                                )
                            }
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
                                    // The SurfaceTexture path already applies
                                    // the producer transform matrix in
                                    // Flutter's external-texture renderer, so
                                    // the texture ARRIVES upright and the
                                    // preview rotation Dart should apply is
                                    // zero. SENSOR_ORIENTATION is still
                                    // required by the separate ImageReader/YUV
                                    // path above; applying it again in Dart
                                    // rotates the self-preview onto its side.
                                    //
                                    // But an upright texture has the sensor's
                                    // axes SWAPPED, and these width/height are
                                    // the size Dart lays the texture out at.
                                    // Reporting the sensor size with a rotation
                                    // of zero told Dart to put a portrait image
                                    // in a landscape box, which is what
                                    // squashed the self-view on the phone.
                                    // Report the size the texture actually has.
                                    val previewSwapsAxes =
                                        sensorRotation == 90 || sensorRotation == 270
                                    finish(
                                        mapOf(
                                            "textureId" to entry.id(),
                                            "width" to
                                                if (previewSwapsAxes) size.height else size.width,
                                            "height" to
                                                if (previewSwapsAxes) size.width else size.height,
                                            "previewRotation" to 0,
                                            "mirror" to mirror,
                                            "fps" to fpsRange.upper,
                                            "cameraId" to cameraId,
                                            "facing" to lensFacingName(
                                                characteristics.get(
                                                    CameraCharacteristics.LENS_FACING,
                                                ),
                                            ),
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
        val oldProcessingHandler = processingHandler
        val oldProcessingThread = processingThread
        val oldReader = imageReader
        val oldPreviewSurface = previewSurface
        val oldTextureEntry = textureEntry
        try {
            oldReader?.setOnImageAvailableListener(null, null)
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
        imageReader = null
        previewSurface = null
        textureEntry = null
        pendingImage.getAndSet(null)?.close()
        processorScheduled.set(false)
        handler = null
        thread = null
        processingHandler = null
        processingThread = null

        // Fence BOTH loopers. An ImageReader callback can already have handed
        // an Image to the copy looper when stop() invalidates engineAddress;
        // the media engine may be destroyed only after that copy call returns.
        val resourcesReleased = AtomicBoolean(false)
        val releaseResources = {
            if (resourcesReleased.compareAndSet(false, true)) {
                try {
                    oldReader?.close()
                } catch (_: Exception) {}
                try {
                    oldPreviewSurface?.release()
                } catch (_: Exception) {}
                try {
                    oldTextureEntry?.release()
                } catch (_: Exception) {}
                done?.invoke()
            }
        }
        val finishProcessing = {
            if (oldProcessingHandler != null && oldProcessingThread != null &&
                oldProcessingThread.isAlive &&
                Looper.myLooper() != oldProcessingHandler.looper
            ) {
                val posted = oldProcessingHandler.post {
                    oldProcessingThread.quitSafely()
                    releaseResources()
                }
                if (!posted) {
                    oldProcessingThread.quitSafely()
                    releaseResources()
                }
            } else {
                oldProcessingThread?.quitSafely()
                releaseResources()
            }
        }
        if (oldHandler != null && oldThread != null && oldThread.isAlive &&
            Looper.myLooper() != oldHandler.looper
        ) {
            val posted = oldHandler.post {
                oldThread.quitSafely()
                finishProcessing()
            }
            if (posted) return
        }
        oldThread?.quitSafely()
        finishProcessing()
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
            "camera_processing_replaced" to replacedFrames,
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
        replacedFrames = 0
    }

    private fun onImage(source: ImageReader, rotation: Int) {
        val image = source.acquireLatestImage() ?: return
        if (engineAddress == 0L || image.planes.size < 3) {
            image.close()
            return
        }
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

        // One image may be in nativePush and one pending. Replacing the latter
        // keeps latency bounded while maxImages=3 leaves one slot for Camera2;
        // no FIFO is allowed to accumulate behind a slow copy/conversion.
        pendingImage.getAndSet(image)?.let { replaced ->
            replaced.close()
            synchronized(statsLock) { replacedFrames++ }
        }
        scheduleProcessor(rotation)
    }

    private fun scheduleProcessor(rotation: Int) {
        if (!processorScheduled.compareAndSet(false, true)) return
        val target = processingHandler
        if (target == null || !target.post { drainImages(rotation) }) {
            processorScheduled.set(false)
            pendingImage.getAndSet(null)?.close()
        }
    }

    private fun drainImages(rotation: Int) {
        while (true) {
            val image = pendingImage.getAndSet(null)
            if (image != null) processImage(image, rotation)

            processorScheduled.set(false)
            if (pendingImage.get() == null ||
                !processorScheduled.compareAndSet(false, true)
            ) return
        }
    }

    private fun processImage(image: android.media.Image, rotation: Int) {
        try {
            val address = engineAddress
            val planes = image.planes
            if (address == 0L || planes.size < 3) return
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

    fun devices(): List<Map<String, Any?>> {
        return cameraManager.cameraIdList.mapIndexed { index, id ->
            val facing = lensFacingName(
                cameraManager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING),
            )
            mapOf(
                "id" to id,
                "label" to when (facing) {
                    "front" -> "Front camera ${index + 1}"
                    "back" -> "Back camera ${index + 1}"
                    else -> "Camera ${index + 1}"
                },
                "kind" to "camera",
                "facing" to facing,
            )
        }
    }

    private fun chooseCamera(requestedCameraId: String?): String {
        if (!requestedCameraId.isNullOrEmpty() &&
            cameraManager.cameraIdList.contains(requestedCameraId)
        ) {
            return requestedCameraId
        }
        return cameraManager.cameraIdList.firstOrNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_FRONT
        } ?: cameraManager.cameraIdList.firstOrNull()
        ?: throw IllegalStateException("No camera is available")
    }

    private fun lensFacingName(value: Int?): String = when (value) {
        CameraCharacteristics.LENS_FACING_FRONT -> "front"
        CameraCharacteristics.LENS_FACING_BACK -> "back"
        CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
        else -> "unknown"
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
