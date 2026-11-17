package qa;
import android.app.Instrumentation;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.loader.FlutterLoader;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.MethodChannel;
public class Probe extends Instrumentation {
 FlutterEngine engine; boolean done;
 void complete(String text,int code) {
  if(done)return;done=true;
  if(engine!=null)engine.destroy();
  Bundle result=new Bundle();result.putString("probe",text);finish(code,result);
 }
 @Override public void onCreate(Bundle args){super.onCreate(args);start();}
 @Override public void onStart(){
  new Handler(Looper.getMainLooper()).post(()->{
   try{
    FlutterLoader loader=new FlutterLoader();loader.startInitialization(getTargetContext());loader.ensureInitializationComplete(getTargetContext(),new String[]{});
    engine=new FlutterEngine(getTargetContext(),null,false);
    new MethodChannel(engine.getDartExecutor().getBinaryMessenger(),"xveil/qa_result").setMethodCallHandler((call,result)->{
     if(!call.method.equals("result")){result.notImplemented();return;}
     result.success(null);
     new Handler(Looper.getMainLooper()).postDelayed(()->complete(String.valueOf(call.arguments),-1),100);
    });
    engine.getDartExecutor().executeDartEntrypoint(new DartExecutor.DartEntrypoint(loader.findAppBundlePath(),"main"));
    new Handler(Looper.getMainLooper()).postDelayed(()->complete("watchdog",0),30000);
   }catch(Throwable t){complete(t.toString(),0);}
  });
 }
}