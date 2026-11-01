package com.veil.veil_flutter
import android.content.Intent
import android.os.Bundle
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.app.Activity
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference
import android.os.Handler
import android.os.Looper
import android.widget.TextView
class Harness : Activity(), CallScreenActivity.Host {
 private val session = "fixture-call-scope"
 override fun onCreate(state: Bundle?) {
  super.onCreate(state)
  CallScreenActivity.attachHost(this)
  setContentView(TextView(this).apply { text="QA: waiting for incoming notification" })
  startForegroundService(Intent(this, VeilDaemonService::class.java).setAction(VeilDaemonService.ACTION_START))
  Handler(Looper.getMainLooper()).postDelayed({ signal(true) }, 7000)
 }
 private fun signal(ring: Boolean) {
  CallScreenActivity.prepare(session)
  if (ring) {
   val bitmap=Bitmap.createBitmap(64,64,Bitmap.Config.ARGB_8888)
   bitmap.eraseColor(Color.rgb(61,155,133))
   Canvas(bitmap).drawCircle(32f,26f,14f,Paint().apply { color=Color.WHITE })
   val bytes=ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG,70,it) }.toByteArray()
   bitmap.recycle()
   check(CallScreenActivity.updateCaller(session,"Тестовый контакт",if(intent.getBooleanExtra("avatar",true)) bytes else null))
   check(!CallScreenActivity.updateCaller("obsolete-session","STALE",null))
   Handler(Looper.getMainLooper()).postDelayed({ capturePreview() },2000)
  }
  startForegroundService(Intent(this, VeilDaemonService::class.java).apply {
   action=VeilDaemonService.ACTION_START
   putExtra(VeilDaemonService.EXTRA_NOTIFICATION_TITLE,getString(if(ring) R.string.veil_call_screen_incoming else R.string.veil_call_screen_ongoing))
   putExtra(VeilDaemonService.EXTRA_HANGUP_ACTION,true)
   putExtra(VeilDaemonService.EXTRA_RINGING,ring)
   putExtra(CallActionCapability.EXTRA_CALL_SESSION,session)
  })
 }
 override fun dispatchCallScreenAction(intent: Intent): Boolean {
  val action=intent.getStringExtra(CallActionCapability.EXTRA_CALL_ACTION) ?: return false
  val token=intent.getStringExtra(CallActionCapability.EXTRA_CALL_TOKEN)
  val scope=intent.getStringExtra(CallActionCapability.EXTRA_CALL_SESSION)
  if (scope != session || !CallActionCapability.consume(action,token,scope)) return false
  getSharedPreferences("proof",0).edit().putBoolean(action,true).commit()
  if(action=="accept") signal(false)
  else {
   CallScreenActivity.clear()
   check(!CallScreenActivity.updateCaller(session,"ENDED",null))
   getSharedPreferences("proof",0).edit().putBoolean("latePresentationRejected",true).commit()
   startService(Intent(this,VeilDaemonService::class.java).setAction(VeilDaemonService.ACTION_STOP))
  }
  return true
 }
 // Test-only render of synthetic data; no screenshot path exists in the SDK.
 private fun capturePreview() {
  val field=CallScreenActivity::class.java.getDeclaredField("visible").apply { isAccessible=true }
  val activity=(field.get(null) as WeakReference<*>).get() as? Activity ?: return
  val view=activity.window.decorView
  if(view.width==0 || view.height==0) return
  val image=Bitmap.createBitmap(view.width,view.height,Bitmap.Config.ARGB_8888)
  view.draw(Canvas(image))
  openFileOutput("call-screen.png",0).use { image.compress(Bitmap.CompressFormat.PNG,100,it) }
  image.recycle()
 }

}
