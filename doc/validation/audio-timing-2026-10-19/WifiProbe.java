package network.veil.xveil.wifiprobe;
import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.os.Bundle;
import java.lang.reflect.Method;

// Private stand instrumentation. Starts no call, node, microphone or camera.
// Calls the exact platform implementation and always releases it before exit.
public class WifiProbe extends Instrumentation {
  private Activity activity;
  private Method active;
  private final boolean[] result = {false};
  @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
  private void set(boolean on) {
    runOnMainSync(() -> {
      try { result[0] = (Boolean) active.invoke(activity, on); }
      catch (ReflectiveOperationException e) { throw new RuntimeException(e); }
    });
  }
  private void phase(String value) {
    Bundle b = new Bundle(); b.putString("phase", value); sendStatus(1, b);
  }
  @Override public void onStart() {
    Bundle end = new Bundle();
    try {
      Intent launch = new Intent().setClassName("network.veil.xveil", "network.veil.xveil.MainActivity");
      launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
      activity = startActivitySync(launch);
      Thread.sleep(2000);
      active = activity.getClass().getDeclaredMethod("setCallNetworkActive", boolean.class);
      active.setAccessible(true);
      set(true); if (!result[0]) throw new AssertionError("Call network activation failed");
      set(true); if (!result[0]) throw new AssertionError("Idempotent activation failed");
      phase("foreground"); Thread.sleep(4000);
      phase("screen_off"); Thread.sleep(8000);
      set(false); if (result[0]) throw new AssertionError("Release returned held");
      set(false);
      phase("released"); Thread.sleep(1000);
      end.putString("result", "pass"); finish(0, end);
    } catch (Throwable e) {
      end.putString("failure", e.toString()); finish(1, end);
    } finally {
      if (activity != null && active != null) { try { set(false); } catch (Throwable ignored) {} }
    }
  }
}
