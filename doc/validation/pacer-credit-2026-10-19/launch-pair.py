from pathlib import Path
import subprocess,os,json,signal,sys,time
os.umask(0o077)
b=Path(__file__).parent
v=Path('/Users/vart/.cache/codex/xveil-video-framing-20261019')
repo=Path('/Users/vart/Projects/veilnetwork/xVeil')
label='rtp-lag-full'
d=b/('pair-'+label);assert not d.exists()
media=Path('/Users/vart/.cache/codex/xveil-rtp-lag-20261019/media-hooks/libveil_media.dylib')
cmd=['python3',str(repo/'scripts/relay-codec-control.py'),'--sdk','/Users/vart/.cache/codex/xveil-pacer-credit-20261019/sdk/libveilclient_ffi.dylib','--media',str(media),'--directory',str(d),'--duration',('360' if label.endswith('-full') else '180'),'--rate-kbps','1024','--adaptive-audio','--audio-overhead-bytes','360','--max-rtp-packet-size','1000','--compact-media','--compact-call-health','--local-source-feedback','--compete-file','--tone-period-ms','1010','--native-pcm-priority','deadline','--native-timing-trace','--playout-trace','--native-trace-capacity','32768','--source-cell-trace','--shaper-trace']
if label.endswith('-full'):cmd+=['--live-video-framing']
fixture=helper=None
try:
 with (b/('pair-'+label+'.log')).open('w') as log:
  fixture=subprocess.Popen(cmd,cwd=repo,env=dict(os.environ,TMPDIR='/private/tmp/'),stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  helper=subprocess.Popen(['caffeinate','-i','-w',str(fixture.pid)])
  (b/('pair-'+label+'-ownership.json')).write_text(json.dumps({'launcher_pid':os.getpid(),'fixture_pid':fixture.pid,'helper_pid':helper.pid,'command':cmd},indent=2))
  print(json.dumps({'fixture_pid':fixture.pid,'helper_pid':helper.pid,'label':label}),flush=True)
  try:code=fixture.wait(timeout=70)
  except subprocess.TimeoutExpired:
   rows=[]
   for line in subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines():
    fields=line.strip().split(None,2)
    if len(fields)==3:rows.append((int(fields[0]),int(fields[1]),fields[2]))
   owned={os.getpid(),fixture.pid,helper.pid}
   for _ in range(8):owned.update(pid for pid,ppid,cmd in rows if ppid in owned)
   (b/'pair-processes-live.json').write_text(json.dumps([dict(pid=pid,ppid=ppid,command=cmd) for pid,ppid,cmd in rows if pid in owned],indent=2))
   code=fixture.wait(timeout=520)
  print(json.dumps({'fixture_exit_code':code}),flush=True)
finally:
 if fixture and fixture.poll() is None:
  os.killpg(fixture.pid,signal.SIGTERM)
  try:fixture.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(fixture.pid,signal.SIGKILL);fixture.wait(timeout=5)
 if helper:
  try:helper.wait(timeout=5)
  except subprocess.TimeoutExpired:helper.terminate();helper.wait(timeout=5)
 (b/('pair-'+label+'-cleanup.json')).write_text(json.dumps({'fixture_absent':fixture is None or fixture.poll() is not None,'helper_absent':helper is None or helper.poll() is not None,'exit_code':None if fixture is None else fixture.returncode},indent=2))
