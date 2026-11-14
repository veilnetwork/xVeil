package network.veil.xveil

fun main() {
    var sequence = 0
    var daemon: Long? = 1
    val gate = CallNetworkRetirementGate { "synthetic-${++sequence}" }
    var held = false
    var refuseRelease = false
    val owner = CallNetworkLocks(false, mayAcquire = { gate.admits(daemon) }) {
        object : CallNetworkLock {
            override val isHeld: Boolean get() = held
            override fun acquire() { held = true }
            override fun release() {
                check(!refuseRelease) { "synthetic native release refusal" }
                held = false
            }
        }
    }
    fun refuses(block: () -> Unit) { check(runCatching(block).isFailure) }
    try {
        check(owner.setActive(true))
        daemon = null
        check(!owner.setActive(true))
        val first = gate.begin(2)
        check(gate.begin(2) == first)
        check(!gate.admits(1)) // A restarted daemon cannot bypass this gate.
        refuses { gate.release(first, 2, false) } // Unverified.
        refuses { gate.confirm(first, 2, true) }
        refuses { gate.confirm("foreign", 2, false) }
        refuses { gate.confirm(first, 3, false) }
        refuseRelease = true
        CallNetworkLocks.releaseAllOwners()
        check(held && CallNetworkLocks.hasUnreleasedResources())
        refuses { gate.confirm(first, 2, CallNetworkLocks.hasUnreleasedResources()) }
        refuseRelease = false
        CallNetworkLocks.releaseAllOwners()
        check(!held && !CallNetworkLocks.hasUnreleasedResources())
        gate.confirm(first, 2, false)
        gate.release(first, 2, false)
        gate.release(first, 2, false) // Exact lost-success retry.
        check(!owner.setActive(true)) // Daemon still sealed.
        daemon = 3
        check(owner.setActive(true)) // A live engine can serve the new profile.
        refuses { gate.release(first, 3, true) }
        check(held)
        daemon = null
        val next = gate.begin(4)
        check(next != first)
        refuses { gate.release(first, 2, false) }
        CallNetworkLocks.releaseAllOwners()
        gate.confirm(next, 4, false)
        gate.release(next, 4, false)
    } finally {
        refuseRelease = false
        owner.retire()
        check(!held && !CallNetworkLocks.hasUnreleasedResources())
    }
    println("call network native retirement/admission checks passed")
}
