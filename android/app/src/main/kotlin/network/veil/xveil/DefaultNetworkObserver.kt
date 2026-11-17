package network.veil.xveil

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Engine-owned observer; no windows, permissions, network requests or identifiers. */
internal class DefaultNetworkObserver(context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val manager = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val handler = Handler(Looper.getMainLooper())
    private val methods = MethodChannel(messenger, "xveil/default_network")
    private val events = EventChannel(messenger, "xveil/default_network/events")
    private var sink: EventChannel.EventSink? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    private var state: DefaultNetworkState<Network>? = null
    private var disposed = false

    init {
        events.setStreamHandler(this)
        methods.setMethodCallHandler { call, result ->
            if (call.method != "current") result.notImplemented()
            else try {
                result.success(watch().snapshot())
            } catch (_: Exception) {
                stop()
                result.error("network_observation", "Default network observation unavailable", null)
            }
        }
    }

    private fun kind(capabilities: NetworkCapabilities?): String = when {
        capabilities == null -> "unknown"
        // Preserve the app's existing precedence; VPN metadata is not exported.
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        else -> "unknown"
    }

    private fun watch(): DefaultNetworkState<Network> {
        check(!disposed && Build.VERSION.SDK_INT >= 26)
        state?.let { return it }
        val owner = DefaultNetworkState<Network> { value -> sink?.success(value) }
        val listener = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { owner.available(network) }
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                owner.capabilities(network, kind(caps))
            }
            override fun onLost(network: Network) { owner.lost(network) }
        }
        state = owner
        callback = listener
        try {
            // All callbacks, snapshots and disposal share the main looper. Do
            // not query ConnectivityManager from callbacks: their arguments
            // carry the ordered capabilities for that exact default Network.
            manager.registerDefaultNetworkCallback(listener, handler)
            val initial = manager.activeNetwork
            owner.seed(initial, kind(initial?.let(manager::getNetworkCapabilities)))
        } catch (error: Exception) {
            stop()
            throw error
        }
        return owner
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        try { events.success(watch().snapshot()) }
        catch (_: Exception) {
            stop()
            events.error("network_observation", "Default network observation unavailable", null)
        }
    }

    override fun onCancel(arguments: Any?) { sink = null; stop() }

    private fun stop() {
        state?.close() // Queued callbacks from this registration become inert.
        state = null
        callback?.let { try { manager.unregisterNetworkCallback(it) } catch (_: Exception) {} }
        callback = null
    }

    fun dispose() {
        disposed = true
        sink = null
        stop()
        methods.setMethodCallHandler(null)
        events.setStreamHandler(null)
    }
}
