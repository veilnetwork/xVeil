package network.veil.xveil

/** Native admission remains fenced until this exact verified retirement releases. */
internal class CallNetworkRetirementGate(private val newToken: () -> String) {
    private var token: String? = null
    private var daemonRetirement: Long? = null
    private var released: String? = null
    private var verified = false

    fun admits(daemon: Long?): Boolean = daemon != null && token == null
    fun begin(daemon: Long): String {
        if (token == null) {
            token = newToken().also { check(it.isNotEmpty()) }
            daemonRetirement = daemon
        }
        check(daemonRetirement == daemon) { "network retirement unavailable" }
        verified = false
        return token!!
    }
    fun confirm(value: String, daemon: Long, resources: Boolean) {
        requireCurrent(value, daemon)
        verified = false
        check(!resources) { "network resources remain" }
        verified = true
    }
    fun release(value: String, daemon: Long, resources: Boolean) {
        if (token == null && released == value && daemonRetirement == daemon) {
            check(!resources) { "network resources remain" }
            return
        }
        requireCurrent(value, daemon)
        check(verified && !resources) { "network retirement unverified" }
        released = value
        token = null
        verified = false
    }
    private fun requireCurrent(value: String, daemon: Long) {
        check(value.isNotEmpty() && token == value && daemonRetirement == daemon) {
            "network retirement unavailable"
        }
    }
}
