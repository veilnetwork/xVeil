package network.veil.xveil

fun main() {
    fun size(width: Int, height: Int) = CallCameraCaptureSize(width, height)
    // Intersection of PRIVATE and YUV OUTPUT modes reported by Blackview's
    // front Camera2 device. Camera2 offers no 640x360 mode on this device.
    val blackview = listOf(
        size(3264,2448), size(3072,1728), size(2560,1920), size(2560,1440),
        size(2304,1296), size(2048,1536), size(1920,1440), size(1920,1088),
        size(1920,1080), size(1600,1200), size(1600,720), size(1560,720),
        size(1520,720), size(1440,1088), size(1440,1080), size(1440,720),
        size(1280,960), size(1280,720), size(1080,720), size(960,720),
        size(960,540), size(800,600), size(720,720), size(720,480),
        size(640,480), size(352,288), size(320,240), size(192,144),
        size(192,108), size(176,144), size(160,96),
    )
    fun choose(sizes: List<CallCameraCaptureSize>, w: Int, h: Int) =
        CallCameraSizePolicy.choose(sizes,w,h)
    check(choose(blackview,640,360) == size(960,540)) {
        "640x360 must not select the 192x108 thumbnail: ${choose(blackview,640,360)}"
    }
    check(choose(blackview + size(640,360),640,360) == size(640,360))
    check(choose(blackview,352,198) == size(192,108)) {
        "The low-bandwidth profile need not open an HD capture"
    }
    check(choose(listOf(size(640,480),size(320,240),size(160,120)),640,360) == size(640,480))
    check(choose(listOf(size(192,108)),640,360) == size(192,108))
    check(choose(listOf(size(1280,720),size(320,180)),640,360) == size(320,180)) {
        "Equal scale distances should prefer the cheaper capture"
    }
    check(choose(emptyList(),640,360) == null)
    check(choose(listOf(size(0,100),size(-1,10),size(640,360)),640,360) == size(640,360))
    println("8 camera size selection checks passed")
}
