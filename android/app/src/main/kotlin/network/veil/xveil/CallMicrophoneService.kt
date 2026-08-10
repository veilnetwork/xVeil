package network.veil.xveil

import android.Manifest
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
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START) {
            stopSelf()
            return START_NOT_STICKY
        }
        createNotificationChannel()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID,
                    buildNotification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification())
            }
        } catch (error: Exception) {
            // Revoked RECORD_AUDIO or a start-time restriction: the call keeps
            // running without the keep-alive grant instead of crashing.
            XVeilLog.w(this, TAG) { "startForeground failed: $error" }
            stopSelf()
        }
        return START_NOT_STICKY
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

        /**
         * True when the service reached startForegroundService. The typed
         * grant additionally requires RECORD_AUDIO, checked here so a denied
         * permission degrades to "no keep-alive" instead of a SecurityException
         * inside the 5-second startForeground window.
         */
        fun start(context: Context): Boolean {
            val micGranted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
            if (!micGranted) {
                XVeilLog.w(context, TAG) { "not starting: RECORD_AUDIO not granted" }
                return false
            }
            return try {
                val intent = Intent(context, CallMicrophoneService::class.java)
                    .setAction(ACTION_START)
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (error: Exception) {
                // ForegroundServiceStartNotAllowedException when invoked from
                // the background — the call proceeds without the grant.
                XVeilLog.w(context, TAG) { "startForegroundService failed: $error" }
                false
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, CallMicrophoneService::class.java))
            } catch (_: Exception) {
            }
        }
    }
}
