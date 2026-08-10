package network.veil.xveil

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log

/**
 * Diagnostic logging for the Android host code, silent in a release build.
 *
 * The Dart side has had this since the beginning: `devLog` is compiled out by
 * the AOT compiler and its message is a thunk, so a release build neither
 * prints nor even builds the string. The reason is stated there and applies
 * here word for word — xVeil's diagnostics carry the metadata an anonymity
 * tool must not emit anywhere an adversary can read it.
 *
 * `logcat` is exactly such a place, and the host code went straight to it
 * (report9 X-07). What a release build was announcing there, timestamped:
 * that screen sharing had started and at what resolution, the size of the
 * first captured frame, that a call had asked for the microphone and been
 * refused. None of it went through the Dart gate, because none of it is Dart.
 *
 * The gate is `FLAG_DEBUGGABLE` rather than `BuildConfig.DEBUG`: this module
 * does not generate a `BuildConfig`, and turning that on means touching an
 * AGP 9 configuration that is deliberate about what it enables. The flag is
 * read at the call rather than at compile time, so the branch survives into
 * the release binary — but nothing is emitted, and the message is a lambda,
 * so the string with the resolution in it is never built.
 *
 * It fails CLOSED by construction: anything that cannot see an application
 * info stays silent.
 */
internal object XVeilLog {
    fun i(context: Context, tag: String, message: () -> String) {
        if (debuggable(context)) Log.i(tag, message())
    }

    fun w(context: Context, tag: String, message: () -> String) {
        if (debuggable(context)) Log.w(tag, message())
    }

    private fun debuggable(context: Context): Boolean = try {
        (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    } catch (_: Exception) {
        false
    }
}
