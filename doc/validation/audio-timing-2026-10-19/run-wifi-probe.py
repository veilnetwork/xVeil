from pathlib import Path
import subprocess,json,time,re,os,sys
os.umask(0o077)
b=Path(__file__).parent;label=sys.argv[1];d=b/('wifi-'+label);d.mkdir(exist_ok=False);serial='BV6600PRORU000182';target='network.veil.xveil';probe=target+'.wifiprobe';p=None

def adb(*args,check=True):return subprocess.run(['adb','-s',serial,*args],capture_output=True,text=True,timeout=35,check=check)
def power():
 s=adb('shell','dumpsys','power').stdout;m=re.search(r'^\s*mWakefulness=(\w+)',s,re.M);return m[1] if m else None
def snapshot(name):
 raw=adb('shell','dumpsys','wifi').stdout;(d/(name+'-wifi.txt')).write_text(raw);out={'power':power(),'own_locks':[line.strip() for line in raw.splitlines() if target+':call-' in line]}
 for key in ['high_perf_active_time_ms','low_latency_active_time_ms']:
  m=re.search(r'\b'+key+r':\s*(\d+)',raw);out[key]=int(m[1]) if m else None
 for key in ['acquired','released']:
  m=re.search('Locks '+key+r': (\d+) full high perf, (\d+) full low latency',raw);out[key]=list(map(int,m.groups())) if m else None
 return out
result={};seen=set();initial=None;started=False
try:
 q=adb('shell','pidof',target,check=False);assert q.returncode==1 and not q.stdout.strip(),'Target app is already running; do not interfere'
 initial=power();result['before']=snapshot('before');adb('install','-r',str(b/'wifi-probe-build/probe.apk'));adb('shell','input','keyevent','KEYCODE_WAKEUP')
 output=(d/'instrumentation.txt').open('w');p=subprocess.Popen(['adb','-s',serial,'shell','am','instrument','-w','-r',probe+'/.WifiProbe'],stdout=output,stderr=subprocess.STDOUT);started=True
 (d/'owned.json').write_text(json.dumps({'launcher':os.getpid(),'adb':p.pid}));deadline=time.monotonic()+90
 while p.poll() is None and time.monotonic()<deadline:
  content=(d/'instrumentation.txt').read_text()
  for phase in ['foreground','screen_off','released']:
   if 'phase='+phase in content and phase not in seen:
    seen.add(phase)
    if phase=='screen_off':adb('shell','input','keyevent','KEYCODE_SLEEP');time.sleep(1)
    result[phase]=snapshot(phase);print(json.dumps({'phase':phase,'own_locks':result[phase]['own_locks'],'power':result[phase]['power']}),flush=True)
  time.sleep(.2)
 assert p.poll() is not None,'Instrumentation timed out';assert 'result=pass' in (d/'instrumentation.txt').read_text(), 'Instrumentation failed; see private output'
 result['phases']=sorted(seen);assert seen=={'foreground','screen_off','released'}
 result['after']=snapshot('after');assert result['screen_off']['power'] in ['Asleep','Dozing'];assert not result['after']['own_locks']
 expected=2 if label=='fixed' else 1;assert len(result['foreground']['own_locks'])==expected;assert len(result['screen_off']['own_locks'])==expected
 for key in ['acquired','released']:
  delta=[x-y for x,y in zip(result['after'][key],result['before'][key])];result[key+'_delta']=delta;assert delta==([1,1] if label=='fixed' else [0,1]),(key,delta)
 result['active_ms_delta']={k:result['after'][k]-result['before'][k] for k in ['high_perf_active_time_ms','low_latency_active_time_ms']}
 if label=='fixed':assert result['active_ms_delta']['high_perf_active_time_ms']>=6000
 else:assert result['active_ms_delta']['high_perf_active_time_ms']==0
 result['ok']=True
except Exception as e:
 result['ok']=False;result['error']=str(e);raise
finally:
 if p and p.poll() is None:p.terminate();p.wait(timeout=5)
 if started:adb('shell','am','force-stop',target,check=False)
 result['target_process_absent']=adb('shell','pidof',target,check=False).returncode==1
 adb('uninstall',probe,check=False)
 result['probe_removed']=not adb('shell','pm','list','packages',probe).stdout.strip()
 if initial=='Awake':adb('shell','input','keyevent','KEYCODE_WAKEUP')
 else:adb('shell','input','keyevent','KEYCODE_SLEEP')
 (d/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items() if k not in ['before','foreground','screen_off','released','after']}),flush=True)
