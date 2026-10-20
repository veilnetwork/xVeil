package network.veil.xveil

import kotlin.math.abs
import kotlin.math.ln

internal data class CallCameraCaptureSize(val width: Int, val height: Int) {
    val area: Long get() = width.toLong() * height.toLong()
}

/** Select from sizes supported by both preview and YUV capture. */
internal object CallCameraSizePolicy {
    fun choose(
        sizes: List<CallCameraCaptureSize>,
        requestedWidth: Int,
        requestedHeight: Int,
    ): CallCameraCaptureSize? {
        require(requestedWidth > 0 && requestedHeight > 0)
        val targetArea = requestedWidth.toLong() * requestedHeight.toLong()
        val targetRatio = requestedWidth.toDouble() / requestedHeight.toDouble()
        return sizes.filter { it.width > 0 && it.height > 0 }.minWithOrNull(
            compareBy<CallCameraCaptureSize> { size ->
                // Equal scale factors above/below the requested area have
                // equal cost. Linear relative error saturated below 1 for
                // tiny modes, preferring 192x108 over 960x540 at 640x360.
                val areaError = abs(ln(size.area.toDouble() / targetArea.toDouble()))
                val ratioError = abs(size.width.toDouble() / size.height.toDouble() - targetRatio)
                ratioError * 8.0 + areaError
            }.thenBy { it.area }.thenBy { it.width },
        )
    }
}
