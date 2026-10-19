from pathlib import Path
import subprocess,os,json,signal,time,hashlib
os.umask(0o077)
r=Path(__file__).parent;repo=Path('/Users/vart/Projects/veilnetwork/xVeil');d=r/'group-final-360';assert not d.exists()
assert not os.environ.get('VEIL_MEDIA_TEST_GROUP_PTIME')
env=dict(os.environ,TMPDIR='/private/tmp/',VEIL_RT_TRACE_SEALED_EVERY='1',VEIL_DIAG_SOURCE_CELLS='1',VEIL_MEDIA_RTP_TRACE_LIMIT='32768')
cmd=['python3',str(repo/'scripts/group-process-preflight.py'),'--sdk','/Users/vart/.cache/codex/xveil-source-flight-demand-20261019/sdk/libveilclient_ffi.dylib','--media','/Users/vart/.cache/codex/xveil-rtp-lag-20261019/media-hooks/libveil_media.dylib','--directory',str(d),'--duration','360','--rate-kbps','1024','--adaptive','--full-load','--playout-trace','--opaque-forward-trace','--source-framing-trace','--wire-trace-capacity','250000']
fixture=helper=None
try:
 with (r/'group-final-360.log').open('w') as log:
  fixture=subprocess.Popen(cmd,cwd=repo,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
  helper=subprocess.Popen(['caffeinate','-i','-w',str(fixture.pid)])
  proof={'launcher_pid':os.getpid(),'fixture_pid':fixture.pid,'helper_pid':helper.pid,'command':cmd}
  (r/'group-final-ownership.json').write_text(json.dumps(proof,indent=2));print(json.dumps(proof),flush=True)
  until=time.monotonic()+120
  while not (d/'capture-origin.json').exists() and fixture.poll() is None and time.monotonic()<until:time.sleep(.2)
  if d.is_dir():
   (d/'native-build.json').write_bytes(Path('/Users/vart/.cache/codex/xveil-rtp-lag-20261019/native-source-proof.json').read_bytes())
   for f in ['lib/state/veil_group_call_media.dart','lib/state/veil_call_media.dart','lib/domain/call_signal.dart']:
    (d/('supplemental-'+f.replace('/','-'))).write_bytes((repo/f).read_bytes())
  processes=[]
  for line in subprocess.check_output(['ps','-axo','pid=,ppid=,command='],text=True).splitlines():
   a=line.strip().split(None,2)
   if len(a)==3:processes.append((int(a[0]),int(a[1]),a[2]))
  owned={os.getpid(),fixture.pid,helper.pid}
  for _ in range(8):owned.update(pid for pid,parent,cmd in processes if parent in owned)
  (r/'group-final-processes-live.json').write_text(json.dumps([dict(pid=pid,ppid=parent,command=cmd) for pid,parent,cmd in processes if pid in owned],indent=2))
  print(json.dumps({'fixture_exit_code':fixture.wait(timeout=600)}),flush=True)
finally:
 if fixture and fixture.poll() is None:
  os.killpg(fixture.pid,signal.SIGTERM)
  try:fixture.wait(timeout=10)
  except subprocess.TimeoutExpired:os.killpg(fixture.pid,signal.SIGKILL);fixture.wait(timeout=5)
 if helper:
  try:helper.wait(timeout=5)
  except subprocess.TimeoutExpired:helper.terminate();helper.wait(timeout=5)
 (r/'group-final-launcher-cleanup.json').write_text(json.dumps({'fixture_absent':fixture is None or fixture.poll() is not None,'helper_absent':helper is None or helper.poll() is not None}))
