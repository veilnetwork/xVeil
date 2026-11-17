package network.veil.xveil

/** Network equality stays native. The channel receives only a local revision. */
internal class DefaultNetworkState<N : Any>(private val publish: (Map<String, Any>) -> Unit) {
    private var announced: N? = null
    private var observed: N? = null
    private var kind = "offline"
    private var revision = 0L
    private var closed = false

    fun snapshot(): Map<String, Any> = mapOf("kind" to kind, "revision" to revision)

    fun seed(network: N?, type: String) {
        if (closed) return
        announced = network
        update(network, if (network == null) "offline" else type)
    }

    fun available(network: N) {
        if (!closed) announced = network
    }

    fun capabilities(network: N, type: String) {
        if (!closed && announced == network) update(network, type)
    }

    fun lost(network: N) {
        if (closed || announced != network) return
        announced = null
        update(null, "offline")
    }

    private fun update(network: N?, type: String) {
        if (observed == network && kind == type) return
        observed = network
        kind = type
        revision++
        publish(snapshot())
    }

    fun close() { closed = true }
}
