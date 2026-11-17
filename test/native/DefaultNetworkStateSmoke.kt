package network.veil.xveil

fun main() {
    val events = mutableListOf<Map<String, Any>>()
    val state = DefaultNetworkState<String> { events.add(it) }
    check(state.snapshot() == mapOf("kind" to "offline", "revision" to 0L))
    state.seed("first", "wifi")
    check(events.size == 1)
    state.available("first")
    repeat(20) { state.capabilities("first", "wifi") }
    check(events.size == 1) // Capability churn must not tear down sessions.

    state.available("second")
    state.capabilities("second", "wifi")
    check(events.size == 2 && events.last()["revision"] == 2L)
    state.lost("first")
    state.capabilities("first", "cellular")
    check(events.size == 2) // A superseded network cannot undo the new route.

    state.available("third")
    state.lost("second")
    check(events.size == 2) // New best network announced before capabilities.
    state.capabilities("third", "cellular")
    check(events.size == 3 && events.last()["kind"] == "cellular")
    state.lost("third")
    state.lost("third")
    check(events.size == 4 && events.last()["kind"] == "offline")
    state.available("third")
    state.capabilities("third", "cellular")
    check(events.size == 5 && events.last()["revision"] == 5L)

    state.close()
    state.available("late")
    state.capabilities("late", "wifi")
    state.lost("third")
    state.seed("late", "wifi")
    check(events.size == 5) // Queued callbacks after detach are inert.
    check(events.all { it.keys == setOf("kind", "revision") })
    check(events.none { value -> value.values.any { it in setOf("first", "second", "third") } })
    println("DefaultNetworkState: replacement, duplicate, stale, offline, retirement and privacy checks passed")
}
