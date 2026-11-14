package network.veil.xveil

import android.os.Looper
import com.veil.veil_flutter.VeilDaemonService
import java.util.UUID

/** Native Wi-Fi holders and their admission, independently of Dart caches. */
internal object CallNetworkResources {
    private val gate = CallNetworkRetirementGate { UUID.randomUUID().toString() }
    private fun requireMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "network thread unavailable" }
    }
    private fun sealedDaemon(): Long {
        check(VeilDaemonService.startTicket() == null) { "daemon retirement required" }
        return VeilDaemonService.commandGeneration()
    }
    fun admits(): Boolean {
        requireMainThread()
        return gate.admits(VeilDaemonService.startTicket())
    }
    fun retire(): String {
        requireMainThread()
        val token = gate.begin(sealedDaemon())
        CallNetworkLocks.releaseAllOwners()
        verifyRetirement(token)
        return token
    }
    fun verifyRetirement(token: String) {
        requireMainThread()
        gate.confirm(token, sealedDaemon(), CallNetworkLocks.hasUnreleasedResources())
    }
    fun releaseRetirement(token: String) {
        requireMainThread()
        gate.release(token, sealedDaemon(), CallNetworkLocks.hasUnreleasedResources())
    }
}
