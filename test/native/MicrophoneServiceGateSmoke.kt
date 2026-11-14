package network.veil.xveil

fun main() {
    var issued = 0
    val gate = MicrophoneServiceGate { "synthetic-${++issued}" }
    val first = checkNotNull(gate.request("first-engine", 5))
    check(gate.accepts(first, 5))
    check(!gate.accepts(first, null))
    check(!gate.accepts(first, 6))
    check(gate.request("next-engine", 5) == null)
    check(!gate.stop("next-engine"))
    check(gate.accepts(first, 5))
    check(gate.stop("first-engine"))
    check(!gate.accepts(first, 5))
    val next = checkNotNull(gate.request("next-engine", 5))
    check(!gate.stop("first-engine"))
    check(gate.accepts(next, 5))
    check(gate.stop("next-engine"))
    val sameOwner = checkNotNull(gate.request("next-engine", 5))
    check(!gate.accepts(next, 5))
    check(gate.accepts(sameOwner, 5))
    val token = gate.begin(6)
    check(gate.begin(6) == token)
    check(!gate.accepts(next, 5))
    check(gate.request("next-engine", 6) == null)
    fun refuses(block: () -> Unit) {
        check(runCatching(block).isFailure)
    }
    refuses { gate.confirm(token, 6, true) }
    refuses { gate.release(token, 6, false) }
    refuses { gate.confirm(token, 7, false) }
    refuses { gate.confirm("foreign", 6, false) }
    gate.confirm(token, 6, false)
    gate.release(token, 6, false)
    gate.release(token, 6, false)
    check(!gate.accepts(first, 5))
    check(!gate.accepts(next, 5))
    val fresh = checkNotNull(gate.request("next-engine", 7))
    check(gate.accepts(fresh, 7))
    refuses { gate.release(token, 6, true) }
    val newer = gate.begin(8)
    check(newer != token)
    refuses { gate.release(token, 8, false) }
    refuses { gate.release(token, 6, false) }
    gate.confirm(newer, 8, false)
    gate.release(newer, 8, false)
    check(!gate.accepts(fresh, 7))
    println("microphone admission and retirement checks passed")
}
