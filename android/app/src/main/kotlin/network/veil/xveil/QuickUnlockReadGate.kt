package network.veil.xveil

/** Main-thread ownership: late callbacks cannot complete a replacement read. */
internal class QuickUnlockReadGate<T : Any> {
    private var current: T? = null
    private var closed = false
    fun begin(request: T): Boolean {
        if (closed || current != null) return false
        current = request
        return true
    }
    fun owns(request: T): Boolean = !closed && current === request
    fun finish(request: T): Boolean {
        if (!owns(request)) return false
        current = null
        return true
    }
    fun cancel(): T? = current.also { current = null }
    fun close(): T? {
        closed = true
        return cancel()
    }
}
