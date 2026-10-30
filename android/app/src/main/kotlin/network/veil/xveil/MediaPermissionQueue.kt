package network.veil.xveil

/** Main-thread coordinator for independent mic/camera requests sharing one OS prompt. */
internal class MediaPermissionQueue(
    private val granted: (String) -> Boolean,
    private val launch: (String) -> Unit,
) {
    private data class Request(val permission: String, val results: MutableList<(Boolean) -> Unit>)
    private var active: Request? = null
    private val queued = linkedMapOf<String, Request>()
    private var closed = false
    private var pumping = false
    private var completing = false

    val activePermission: String? get() = active?.permission

    fun request(permission: String, result: (Boolean) -> Unit) {
        if (closed) { deliver(listOf(result), false); return }
        if (isGranted(permission)) { deliver(listOf(result), true); return }
        val existing = active?.takeIf { it.permission == permission } ?: queued[permission]
        if (existing != null) {
            if (existing.results.size < MAX_WAITERS) existing.results.add(result)
            else deliver(listOf(result), false)
            return
        }
        // MainActivity only maps to RECORD_AUDIO/CAMERA. Keep the bound here
        // too, so repeated starts while an OS sheet is open retain no unbounded work.
        if (queued.size + (if (active == null) 0 else 1) >= MAX_PERMISSIONS) {
            deliver(listOf(result), false)
            return
        }
        queued[permission] = Request(permission, mutableListOf(result))
        pump()
    }

    /** Called only after MainActivity verifies this prompt's actual OS grant. */
    fun complete(ok: Boolean) {
        val request = active ?: return
        active = null
        completing = true
        try { deliver(request.results.toList(), ok) }
        finally { completing = false }
        pump()
    }

    fun close() {
        if (closed) return
        closed = true
        val results = active?.results.orEmpty().toList() + queued.values.flatMap { it.results }
        active = null
        queued.clear()
        deliver(results, false)
    }

    private fun isGranted(permission: String) = try { granted(permission) } catch (_: Exception) { false }

    private fun pump() {
        if (closed || pumping || completing || active != null) return
        pumping = true
        try {
            while (!closed && active == null && queued.isNotEmpty()) {
                val entry = queued.entries.first()
                val request = entry.value
                queued.remove(entry.key)
                if (isGranted(request.permission)) {
                    deliver(request.results, true)
                } else {
                    active = request
                    try { launch(request.permission) }
                    catch (_: Exception) { complete(false) }
                }
            }
        } finally { pumping = false }
    }

    private fun deliver(results: List<(Boolean) -> Unit>, ok: Boolean) {
        for (result in results) {
            // A detached Flutter reply must not orphan the other waiters.
            try { result(ok) } catch (_: Exception) { }
        }
    }

    private companion object {
        const val MAX_PERMISSIONS = 2
        const val MAX_WAITERS = 16
    }
}
