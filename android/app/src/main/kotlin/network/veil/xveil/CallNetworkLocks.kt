package network.veil.xveil

import java.util.Collections
import java.util.IdentityHashMap

/** One actual native Wi-Fi lock, retained until its release is observed. */
internal interface CallNetworkLock {
    val isHeld: Boolean
    fun acquire()
    fun release()
}

/** Per-engine native ownership. A failed release never discards its handle. */
internal class CallNetworkLocks(
    private val needsBackground: Boolean,
    private val create: (background: Boolean) -> CallNetworkLock,
) {
    private var primary: CallNetworkLock? = null
    private var background: CallNetworkLock? = null
    private var retired = false

    @Synchronized
    fun isActive(): Boolean = try {
        primary?.isHeld == true && (!needsBackground || background?.isHeld == true)
    } catch (_: RuntimeException) {
        false
    }

    /** true on activation means fully acquired; on deactivation means not released. */
    @Synchronized
    fun setActive(active: Boolean): Boolean {
        if (!active) return deactivate()
        if (retired) return false
        if (isActive()) return true
        // A partial set cannot be replaced while any old handle is uncertain.
        if (deactivate()) return false
        retained.add(this)
        return try {
            primary = create(false)
            primary!!.acquire()
            if (needsBackground) {
                background = create(true)
                background!!.acquire()
            }
            if (isActive()) true else {
                deactivate()
                false
            }
        } catch (_: RuntimeException) {
            deactivate()
            false
        }
    }

    @Synchronized
    fun retire(): Boolean {
        retired = true
        return deactivate()
    }

    private fun release(lock: CallNetworkLock?): CallNetworkLock? {
        if (lock == null) return null
        return try {
            if (lock.isHeld) lock.release()
            // release() returning is not evidence that the grant is gone.
            if (lock.isHeld) lock else null
        } catch (_: RuntimeException) {
            lock
        }
    }

    private fun deactivate(): Boolean {
        primary = release(primary)
        background = release(background)
        val pending = primary != null || background != null
        if (!pending) retained.remove(this)
        return pending
    }

    @Synchronized
    private fun retryIfRetired() {
        if (retired) deactivate()
    }

    companion object {
        // Retain uncertain native handles after their Activity/engine is gone.
        // This is a process-local inventory, not a completed erasure receipt.
        private val retained = Collections.synchronizedSet(
            Collections.newSetFromMap(IdentityHashMap<CallNetworkLocks, Boolean>()),
        )
        fun hasUnreleasedResources(): Boolean = retained.isNotEmpty()

        fun retryRetiredOwners() {
            // Never hold the inventory mutex while entering an owner mutex.
            val owners = synchronized(retained) { retained.toList() }
            owners.forEach { it.retryIfRetired() }
        }
    }
}
