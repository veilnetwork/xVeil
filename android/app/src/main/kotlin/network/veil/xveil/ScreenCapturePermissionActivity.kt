package network.veil.xveil

import android.app.Activity
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Bundle
import java.lang.ref.WeakReference
import java.util.UUID

/**
 * Owns only the OS projection consent, in a task separate from the Flutter UI.
 * Selecting xVeil brings its existing launcher task forward without clearing
 * the selector's result recipient or constructing another Flutter engine.
 * Permission results stay process-local and expire with the requesting engine.
 */
class ScreenCapturePermissionActivity : Activity() {
    private var requestToken: String? = null

    companion object {
        private const val TOKEN = "requestToken"
        private const val CONSENT = 0x5343
        private class Pending(
            val token: String,
            val reply: (Int, Intent?) -> Unit,
            var activity: WeakReference<ScreenCapturePermissionActivity>? = null,
        )
        // All access is on Android's main thread.
        private var pending: Pending? = null

        fun launch(owner: Activity, reply: (Int, Intent?) -> Unit): String {
            check(pending == null) { "Screen consent is already pending" }
            val token = UUID.randomUUID().toString()
            pending = Pending(token, reply)
            try {
                owner.startActivity(
                    Intent(owner, ScreenCapturePermissionActivity::class.java)
                        .putExtra(TOKEN, token)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (error: Exception) {
                pending = null
                throw error
            }
            return token
        }

        fun cancel(token: String?) {
            val request = pending?.takeIf { it.token == token } ?: return
            pending = null
            request.activity?.get()?.let { activity ->
                @Suppress("DEPRECATION")
                activity.finishActivity(CONSENT)
                activity.finish()
            }
        }

        private fun complete(token: String?, resultCode: Int, data: Intent?) {
            val request = pending?.takeIf { it.token == token } ?: return
            pending = null
            request.reply(resultCode, data)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestToken = intent.getStringExtra(TOKEN)
        val request = pending?.takeIf { it.token == requestToken }
        if (request == null) {
            finish()
            return
        }
        request.activity = WeakReference(this)
        if (savedInstanceState == null) {
            try {
                val manager = getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                @Suppress("DEPRECATION")
                startActivityForResult(manager.createScreenCaptureIntent(), CONSENT)
            } catch (_: Exception) {
                complete(requestToken, RESULT_CANCELED, null)
                finish()
            }
        }
    }

    @Deprecated("MediaProjection consent uses the platform activity-result contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == CONSENT) {
            complete(requestToken, resultCode, data)
            // Removing a task explicitly also stops the package's
            // stopWithTask services, including the ongoing call microphone.
            // Ordinary activity completion leaves those call-owned services live.
            finish()
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        if (isFinishing) complete(requestToken, RESULT_CANCELED, null)
        super.onDestroy()
    }
}
