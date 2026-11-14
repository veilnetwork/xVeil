package network.veil.xveil

import android.Manifest
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.Looper
import com.veil.veil_flutter.VeilDaemonService
import java.util.UUID
import androidx.core.content.ContextCompat

/**
 * Microphone-typed foreground service held only while a call is active.
 *
 * Android grants continued microphone access to a backgrounded/locked app
 * only through a microphone-typed foreground service that was started while
 * the app was visible; otherwise the "while in use" appops mode makes
 * AudioRecord deliver silently MUTED frames the moment the screen locks
 * (Opus keeps emitting ~2.5 DTX packets/s, so nothing errors). This service
 * captures nothing itself — the veil audio engine owns the AAudio stream —
 * it only carries the foreground-service grant and the ongoing-call
 * notification for the duration of the 1:1 or group call.
 */
class CallMicrophoneService : Service() {
    private var foregroundActive = false
    private var foregroundUncertain = false
    private var ticket: MicrophoneServiceGate.Ticket? = null

    override fun onCreate() {
        super.onCreate()
        instances.add(this)
    }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requested = if (intent?.action == ACTION_START) {
            val owner = intent.getStringExtra(EXTRA_OWNER)
            if (owner == null) null else MicrophoneServiceGate.Ticket(
                owner, intent.getLongExtra(EXTRA_GENERATION, -1),
                intent.getLongExtra(EXTRA_DAEMON, -1),
            )
        } else null
        if (requested == null || !gate.accepts(requested, VeilDaemonService.startTicket())) {
            // A stale queued START must not kill a replacement already using
            // this service instance. An empty instance has nothing to retain.
            if (!foregroundActive && !foregroundUncertain) stopSelfResult(startId)
            return START_NOT_STICKY
        }
        ticket = requested
        try {
            createNotificationChannel()
            foregroundUncertain = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID, buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
            foregroundActive = true
            foregroundUncertain = false
        } catch (_: Exception) {
            // Keep the uncertain owner until explicit cleanup succeeds. A
            // channel acknowledgement alone is never a resource-absence proof.
            XVeilLog.w(this, TAG) { "microphone foreground unavailable" }
            try { stopOwnedResources() } catch (_: Exception) {}
            stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }

    private fun stopOwnedResources() {
        if (!foregroundActive && !foregroundUncertain) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        foregroundActive = false
        foregroundUncertain = false
    }

    override fun onDestroy() {
        try {
            stopOwnedResources()
            instances.remove(this)
        } finally {
            super.onDestroy()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                getString(R.string.call_mic_channel_name),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = getString(R.string.call_mic_channel_description)
            },
        )
    }

    private fun buildNotification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("xVeil")
            .setContentText(getString(R.string.call_mic_notification_text))
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_CALL)
            .setContentIntent(openApp)
            .build()
    }

    companion object {
        private const val ACTION_START = "network.veil.xveil.call_mic.START"
        private const val NOTIFICATION_CHANNEL = "xveil_call_mic"
        private const val NOTIFICATION_ID = 0x434D53 // 'CMS'
        private const val TAG = "xVeilCallMic"

        private const val EXTRA_OWNER = "microphoneOwner"
        private const val EXTRA_GENERATION = "microphoneGeneration"
        private const val EXTRA_DAEMON = "daemonGeneration"
        private val gate = MicrophoneServiceGate { UUID.randomUUID().toString() }
        // Preserve failed cleanup owners even if Android destroys the service.
        private val instances = mutableSetOf<CallMicrophoneService>()

        private fun requireMainThread() {
            check(Looper.myLooper() == Looper.getMainLooper()) { "microphone thread unavailable" }
        }
        private fun sealedDaemon(): Long {
            check(VeilDaemonService.startTicket() == null) { "daemon retirement required" }
            return VeilDaemonService.commandGeneration()
        }
        private fun foregroundRemains(context: Context): Boolean {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                ?: error("microphone observation unavailable")
            @Suppress("DEPRECATION")
            val running = manager.getRunningServices(Int.MAX_VALUE)
                ?: error("microphone observation unavailable")
            return instances.any { it.foregroundActive || it.foregroundUncertain } ||
                running.any {
                    it.service.packageName == context.packageName &&
                        it.service.className == CallMicrophoneService::class.java.name && it.foreground
                }
        }

        /** Acknowledges queue admission, not delivery or actual capture. */
        fun start(context: Context, owner: String): Boolean {
            requireMainThread()
            if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) !=
                PackageManager.PERMISSION_GRANTED) return false
            if (instances.any {
                (it.foregroundActive || it.foregroundUncertain) && it.ticket?.owner != owner
            }) return false
            val ticket = gate.request(owner, VeilDaemonService.startTicket()) ?: return false
            return try {
                val intent = Intent(context, CallMicrophoneService::class.java)
                    .setAction(ACTION_START)
                    .putExtra(EXTRA_OWNER, ticket.owner)
                    .putExtra(EXTRA_GENERATION, ticket.generation)
                    .putExtra(EXTRA_DAEMON, ticket.daemon)
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (_: Exception) {
                // Invalidate the failed attempt too: an ambiguous platform
                // failure must not permit a late queued start to reappear.
                gate.stop(owner)
                false
            }
        }

        fun stop(context: Context, owner: String) {
            requireMainThread()
            val held = instances.filter { it.ticket?.owner == owner }
            val pending = gate.stop(owner)
            val hadResources = held.any { it.foregroundActive || it.foregroundUncertain }
            held.forEach { it.stopOwnedResources() }
            if (pending || hadResources) {
                // On the main thread no replacement can be admitted between
                // invalidation and this stop request.
                context.stopService(Intent(context, CallMicrophoneService::class.java))
            }
        }

        fun retire(context: Context): String {
            requireMainThread()
            val token = gate.begin(sealedDaemon())
            instances.toList().forEach { it.stopOwnedResources() }
            context.stopService(Intent(context, CallMicrophoneService::class.java))
            verifyRetirement(context, token)
            return token
        }
        fun verifyRetirement(context: Context, token: String) {
            requireMainThread()
            gate.confirm(token, sealedDaemon(), foregroundRemains(context))
        }
        fun releaseRetirement(context: Context, token: String) {
            requireMainThread()
            gate.release(token, sealedDaemon(), foregroundRemains(context))
        }

    }
}
