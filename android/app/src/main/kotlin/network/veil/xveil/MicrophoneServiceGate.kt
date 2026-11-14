package network.veil.xveil

/** Main-thread service admission, independent of an Android Service instance.
 * An accepted START retains both the requesting engine and daemon generation. */
internal class MicrophoneServiceGate(private val newToken: () -> String) {
    data class Ticket(val owner: String, val generation: Long, val daemon: Long)
    private var owner: String? = null
    private var generation = 0L
    private var token: String? = null
    private var daemonRetirement: Long? = null
    private var released: String? = null
    private var verified = false

    fun request(owner: String, daemon: Long?): Ticket? {
        if (daemon == null || token != null || owner.isEmpty()) return null
        if (this.owner != null && this.owner != owner) return null
        this.owner = owner
        return Ticket(owner, generation, daemon)
    }
    fun accepts(ticket: Ticket, daemon: Long?): Boolean =
        daemon != null && token == null && ticket.daemon == daemon &&
            ticket.owner == owner && ticket.generation == generation

    fun stop(owner: String): Boolean {
        if (this.owner != owner) return false
        this.owner = null
        generation++
        return true
    }

    fun begin(daemon: Long): String {
        if (token == null) {
            token = newToken().also { check(it.isNotEmpty()) }
            daemonRetirement = daemon
            owner = null
            generation++
        }
        check(daemonRetirement == daemon) { "microphone retirement unavailable" }
        verified = false
        return token!!
    }
    fun confirm(value: String, daemon: Long, foreground: Boolean) {
        requireCurrent(value, daemon)
        verified = false
        check(!foreground) { "microphone foreground remains" }
        verified = true
    }
    fun release(value: String, daemon: Long, foreground: Boolean) {
        // Repeating a lost successful release cannot release a newer owner.
        if (token == null && released == value && daemonRetirement == daemon) {
            check(!foreground) { "microphone foreground remains" }
            return
        }
        requireCurrent(value, daemon)
        check(verified && !foreground) { "microphone retirement unverified" }
        released = value
        token = null
        generation++
        verified = false
    }
    private fun requireCurrent(value: String, daemon: Long) {
        check(value.isNotEmpty() && token == value && daemonRetirement == daemon) {
            "microphone retirement unavailable"
        }
    }
}
