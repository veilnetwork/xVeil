package network.veil.xveil

/** A lease is local to one consent attempt and one Flutter engine. Queued
 * work must retain the lease, never resolve a replacement by channel name. */
internal class ScreenCaptureSessionGate<T : Any> {
    class Lease<T : Any>(val session: String, val owner: T)
    private var active: Lease<T>? = null

    @Synchronized fun begin(session: String, owner: T): Boolean {
        if (!validSession(session) || active != null) return false
        active = Lease(session, owner)
        return true
    }

    @Synchronized fun current(session: String): Lease<T>? =
        active?.takeIf { it.session == session }

    @Synchronized fun owns(lease: Lease<T>): Boolean = active === lease

    @Synchronized fun end(session: String, owner: T? = null): Lease<T>? {
        val lease = active ?: return null
        if (lease.session != session || (owner != null && lease.owner !== owner)) return null
        active = null
        return lease
    }

    companion object {
        fun validSession(value: String): Boolean =
            value.length == 32 && value.all { it in '0'..'9' || it in 'a'..'f' }
    }
}
