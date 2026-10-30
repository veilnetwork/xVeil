package network.veil.xveil

fun main() {
    var checks = 0
    fun test(block: () -> Unit) { block(); checks++ }
    test {
        val launched = mutableListOf<String>()
        val results = mutableListOf<Pair<String, Boolean>>()
        val queue = MediaPermissionQueue({ false }, { launched.add(it) })
        queue.request("audio") { results.add("audio" to it) }
        queue.request("video") { results.add("video" to it) }
        check(launched == listOf("audio"))
        check(results.isEmpty()) { "concurrent camera was falsely reported denied" }
        queue.complete(true)
        check(launched == listOf("audio", "video"))
        check(results == listOf("audio" to true))
        queue.complete(true)
        check(results == listOf("audio" to true, "video" to true))
        check(queue.activePermission == null)
    }
    test {
        val launched = mutableListOf<String>(); val results = mutableListOf<Boolean>()
        val queue = MediaPermissionQueue({ false }, { launched.add(it) })
        queue.request("audio") { results.add(it) }; queue.request("video") { results.add(it) }
        queue.complete(false)
        check(queue.activePermission == "video") { "mic denial suppressed camera prompt" }
        queue.complete(true)
        check(results == listOf(false, true))
    }
    test {
        val launched = mutableListOf<String>(); val results = mutableListOf<Boolean>()
        val queue = MediaPermissionQueue({ false }, { launched.add(it) })
        repeat(2) { queue.request("audio") { results.add(it) } }
        check(launched.size == 1 && results.isEmpty())
        queue.complete(true); check(results == listOf(true, true))
    }
    test {
        val granted = mutableSetOf("video"); val launched = mutableListOf<String>()
        val results = mutableListOf<Boolean>()
        val queue = MediaPermissionQueue({ it in granted }, { launched.add(it) })
        queue.request("video") { results.add(it) }
        check(results == listOf(true) && launched.isEmpty())
        queue.request("audio") { results.add(it) }; granted.remove("video")
        queue.request("video") { results.add(it) }; granted.add("video")
        queue.complete(false)
        check(launched == listOf("audio") && results == listOf(true, false, true))
    }
    test {
        val launched = mutableListOf<String>(); val results = mutableListOf<Boolean>()
        val queue = MediaPermissionQueue({ false }, { launched.add(it) })
        queue.request("audio") { results.add(it) }; queue.request("video") { results.add(it) }
        queue.close(); queue.close(); queue.complete(true)
        queue.request("audio") { results.add(it) }
        check(results == listOf(false, false, false))
        check(launched == listOf("audio") && queue.activePermission == null)
    }
    test {
        val launched = mutableListOf<String>(); val results = mutableListOf<Boolean>()
        val queue = MediaPermissionQueue({ false }, { if (it == "audio") error("launcher unavailable") else launched.add(it) })
        queue.request("audio") { results.add(it) }; queue.request("video") { results.add(it) }
        check(results == listOf(false) && launched == listOf("video"))
        queue.complete(true); check(results == listOf(false, true))
    }
    test {
        val results = mutableListOf<Boolean>()
        val queue = MediaPermissionQueue({ false }, {})
        repeat(17) { queue.request("audio") { results.add(it) } }
        check(results == listOf(false)) { "permission waiters are not bounded" }
        queue.close(); check(results.size == 17 && results.none { it })
    }
    test {
        val order = mutableListOf<String>()
        val queue = MediaPermissionQueue({ false }, { order.add("launch-$it") })
        queue.request("audio") { queue.request("video") { }; order.add("audio-1") }
        queue.request("audio") { order.add("audio-2") }
        queue.complete(true)
        check(order == listOf("launch-audio", "audio-1", "audio-2", "launch-video"))
        queue.close()
    }
    test {
        var completed = 0
        val queue = MediaPermissionQueue({ false }, {})
        queue.request("audio") { error("detached listener") }
        queue.request("audio") { completed++ }
        queue.complete(true); check(completed == 1)
    }
    println("$checks media permission queue checks passed")
}
