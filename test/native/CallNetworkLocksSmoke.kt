package network.veil.xveil

private class Port : CallNetworkLock {
    var held = false
    var grant = true
    var loseAcquireReply = false
    var refuseRelease = false
    var stickyRelease = false
    var refuseObservation = false
    var releases = 0
    override val isHeld: Boolean get() {
        check(!refuseObservation) { "synthetic observation refusal" }
        return held
    }
    override fun acquire() {
        held = grant
        check(!loseAcquireReply) { "synthetic grant reply lost" }
    }
    override fun release() {
        releases++
        check(!refuseRelease) { "synthetic release refusal" }
        if (!stickyRelease) held = false
    }
}

private class Fixture {
    val ports = mutableListOf<Port>()
    val owners = mutableListOf<CallNetworkLocks>()
    var setup: (Boolean, Port) -> Unit = { _, _ -> }
    var refuseCreate = false
    fun owner(background: Boolean = true): CallNetworkLocks =
        CallNetworkLocks(background, mayAcquire = { true }) { secondary ->
            check(!refuseCreate) { "synthetic factory refusal" }
            Port().also { setup(secondary, it); ports.add(it) }
        }.also { owners.add(it) }
    fun cleanup() {
        ports.forEach {
            it.refuseRelease = false
            it.stickyRelease = false
            it.refuseObservation = false
        }
        owners.forEach { it.retire() }
        check(ports.none { it.held }) { "synthetic native grant remains" }
        check(!CallNetworkLocks.hasUnreleasedResources())
    }
}

fun main() {
    var passed = 0
    fun scenario(block: Fixture.() -> Unit) {
        check(!CallNetworkLocks.hasUnreleasedResources())
        val fixture = Fixture()
        try { fixture.block(); passed++ } finally { fixture.cleanup() }
    }
    scenario {
        val owner = owner()
        check(owner.setActive(true))
        check(ports.size == 2 && ports.all { it.held })
        check(!owner.setActive(false))
        check(ports.none { it.held })
        check(!owner.retire())
        check(ports.all { it.releases == 1 })
    }
    scenario {
        val owner = owner(false)
        check(owner.setActive(true))
        check(ports.size == 1)
        check(!owner.setActive(false))
    }
    scenario {
        val owner = owner()
        check(owner.setActive(true))
        ports.first().refuseRelease = true
        check(owner.setActive(false))
        check(ports.first().held)
        check(!ports.last().held) // Failure of one must not skip the other.
        check(CallNetworkLocks.hasUnreleasedResources())
        ports.first().refuseRelease = false
        check(!owner.setActive(false))
        check(ports.first().releases == 2)
    }
    scenario {
        val owner = owner(false)
        check(owner.setActive(true))
        ports.single().stickyRelease = true
        check(owner.setActive(false)) // A return without release is not absence.
        check(CallNetworkLocks.hasUnreleasedResources())
        ports.single().stickyRelease = false
        check(!owner.setActive(false))
    }
    scenario {
        val owner = owner(false)
        check(owner.setActive(true))
        ports.single().refuseObservation = true
        check(owner.setActive(false))
        check(ports.single().releases == 0)
        check(CallNetworkLocks.hasUnreleasedResources())
        ports.single().refuseObservation = false
        check(!owner.setActive(false))
    }
    scenario {
        setup = { secondary, port ->
            port.refuseRelease = true
            port.loseAcquireReply = secondary
            port.grant = !secondary
        }
        val owner = owner()
        check(!owner.setActive(true))
        check(ports.size == 2 && ports.first().held && !ports.last().held)
        check(!owner.setActive(true)) // No replacement over uncertain grants.
        check(ports.size == 2)
        ports.forEach { it.refuseRelease = false }
        check(!owner.setActive(false))
    }
    scenario {
        setup = { secondary, port -> port.loseAcquireReply = secondary }
        val owner = owner()
        check(!owner.setActive(true))
        check(ports.none { it.held })
        check(!CallNetworkLocks.hasUnreleasedResources())
        setup = { _, _ -> }
        check(owner.setActive(true))
    }
    scenario {
        val old = owner(false)
        check(old.setActive(true))
        check(!old.retire())
        val count = ports.size
        check(!old.setActive(true))
        check(ports.size == count)
        val fresh = owner(false)
        check(fresh.setActive(true))
        check(!old.setActive(false))
        check(fresh.isActive())
    }
    scenario {
        val old = owner(false)
        check(old.setActive(true))
        val oldPort = ports.single()
        oldPort.refuseRelease = true
        check(old.retire())
        val fresh = owner(false)
        check(fresh.setActive(true))
        val freshPort = ports.last()
        oldPort.refuseRelease = false
        CallNetworkLocks.retryRetiredOwners()
        check(!oldPort.held)
        check(freshPort.held && freshPort.releases == 0)
        check(CallNetworkLocks.hasUnreleasedResources()) // The fresh live owner.
    }
    scenario {
        val owner = owner(false)
        check(owner.setActive(true))
        CallNetworkLocks.retryRetiredOwners()
        check(owner.isActive() && ports.single().releases == 0)
    }
    scenario {
        refuseCreate = true
        val owner = owner()
        check(!owner.setActive(true))
        check(ports.isEmpty())
        check(!CallNetworkLocks.hasUnreleasedResources())
    }
    scenario {
        setup = { _, port -> port.grant = false }
        val owner = owner(false)
        check(!owner.setActive(true))
        check(!CallNetworkLocks.hasUnreleasedResources())
    }
    println("$passed call network native ownership scenarios passed")
}
