package network.veil.xveil

import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * Owns the Flutter texture used by the decoded remote call video.
 *
 * libveil_media posts decoded RGBA buffers straight into this Surface from
 * WebRTC's decode thread. Dart only polls small cadence counters; no video
 * pixels or per-frame platform-channel messages cross the Flutter isolate.
 */
class NativeCallVideoRenderer(private val textures: TextureRegistry) {
    private var textureEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surface: Surface? = null

    @Volatile private var engineAddress: Long = 0

    companion object {
        init {
            System.loadLibrary("veil_media")
        }
    }

    private external fun nativeAttachRemoteSurface(engineAddress: Long, surface: Surface): Int
    private external fun nativeDetachRemoteSurface(engineAddress: Long): Int
    private external fun nativeRemoteVideoStats(engineAddress: Long): LongArray

    fun start(engineAddress: Long): Map<String, Any> {
        stop()
        require(engineAddress != 0L) { "media engine is not available" }
        val entry = textures.createSurfaceTexture()
        entry.surfaceTexture().setDefaultBufferSize(640, 360)
        val target = Surface(entry.surfaceTexture())
        val rc = nativeAttachRemoteSurface(engineAddress, target)
        if (rc != 0) {
            target.release()
            entry.release()
            throw IllegalStateException("native remote surface attach failed: $rc")
        }
        textureEntry = entry
        surface = target
        this.engineAddress = engineAddress
        return mapOf("textureId" to entry.id())
    }

    /** Native detach waits on the sink mutex, so return means no decode thread
     * can still access the Surface or engine through this renderer. */
    fun stop() {
        val address = engineAddress
        engineAddress = 0
        if (address != 0L) {
            try {
                nativeDetachRemoteSurface(address)
            } catch (_: Exception) {}
        }
        try {
            surface?.release()
        } catch (_: Exception) {}
        surface = null
        try {
            textureEntry?.release()
        } catch (_: Exception) {}
        textureEntry = null
    }

    fun stats(): Map<String, Any> {
        val address = engineAddress
        if (address == 0L) return mapOf("video_texture_running" to false)
        val values = nativeRemoteVideoStats(address)
        if (values.size < 7) return mapOf("video_texture_running" to true)
        val frames = values[0]
        val firstNs = values[3]
        val lastNs = values[4]
        val elapsedNs = lastNs - firstNs
        val fps = if (frames >= 2 && elapsedNs > 0) {
            (frames - 1).toDouble() * 1_000_000_000.0 / elapsedNs.toDouble()
        } else {
            0.0
        }
        val result = mutableMapOf<String, Any>(
            "video_texture_running" to true,
            "video_texture_id" to (textureEntry?.id() ?: -1L),
            "video_texture_frames" to frames,
            "video_texture_width" to values[1],
            "video_texture_height" to values[2],
            "video_texture_fps" to ((fps * 10.0).toInt() / 10.0),
            "video_texture_max_gap_ms" to values[5] / 1_000_000,
            "video_texture_holds_75ms" to values[6],
        )
        if (values.size >= 15) {
            val decodedFrames = values[7]
            val decodedElapsedNs = values[9] - values[8]
            val decodedFps = if (decodedFrames >= 2 && decodedElapsedNs > 0) {
                (decodedFrames - 1).toDouble() * 1_000_000_000.0 / decodedElapsedNs.toDouble()
            } else {
                0.0
            }
            result += mapOf(
                "video_decoded_frames" to decodedFrames,
                "video_decoded_fps" to ((decodedFps * 10.0).toInt() / 10.0),
                "video_decoded_max_gap_ms" to values[10] / 1_000_000,
                "video_decoded_holds_75ms" to values[11],
                "video_texture_coalesced_frames" to maxOf(0L, decodedFrames - frames),
                "video_texture_max_work_ms" to values[12].toDouble() / 1_000_000.0,
                "video_texture_work_holds_16ms" to values[13],
                "video_texture_work_holds_33ms" to values[14],
            )
        }
        return result
    }
}
