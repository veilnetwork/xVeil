from pathlib import Path
import subprocess,os,json,time,hashlib
r=Path(__file__).parent; clean=r/'sdk-src'; sdk=Path('/Users/<user>/Projects/veilnetwork/xVeil/third_party/veil')
env=dict(os.environ,TMPDIR='/private/tmp/',CARGO_TARGET_DIR='/Users/<user>/.cache/codex/veil-qos-target-20261016')
def run(label,args,expected=0):
 start=time.monotonic()
 with (r/(label+'.log')).open('w') as log:p=subprocess.run(['cargo',*args],cwd=clean,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 row={'exit_code':p.returncode,'elapsed_s':round(time.monotonic()-start,3)};(r/(label+'-status.json')).write_text(json.dumps(row)+'\n');print(json.dumps({label:row}),flush=True)
 assert p.returncode==expected; return (r/(label+'.log')).read_text()
f=clean/'third_party/quinn-proto/src/connection/pacing.rs'; original=f.read_text()
old=subprocess.check_output(['git','show','HEAD:third_party/quinn-proto/src/connection/pacing.rs'],cwd=sdk,text=True)
a=old.index('    pub(super) fn delay(');b=old.index('\n    }\n}',a)+len('\n    }')
x=original.index('    pub(super) fn delay(');y=original.index('    /// A controller-specified',x)
try:
 f.write_text(original[:x]+old[a:b]+'\n\n'+original[y:])
 log=run('negative-old-credit',['test','--manifest-path','third_party/quinn-proto/Cargo.toml','--lib','connection::pacing::tests::'],101)
 for name in ['idle_time_cannot_fund_two_bursts_at_the_same_instant','frequent_driver_polls_preserve_sub_byte_credit','old_timestamps_cannot_replay_a_settled_refill_interval']:assert name+' ... FAILED' in log
finally:f.write_text(original)
f=clean/'third_party/quinn-proto/src/connection/mod.rs'; original=f.read_text();assert original.count('self.path.congestion.metrics().pacing_rate,')==1
try:
 f.write_text(original.replace('self.path.congestion.metrics().pacing_rate,','None,',1))
 log=run('negative-ignored-rate',['test','--manifest-path','third_party/quinn-proto/Cargo.toml','--lib','controller_rate_reaches_the_real_encrypted_datagram_sender'],101)
 assert 'controller_rate_reaches_the_real_encrypted_datagram_sender ... FAILED' in log
finally:f.write_text(original)
run('proto-restored',['test','--manifest-path','third_party/quinn-proto/Cargo.toml','--lib'])
run('session-tests',['test','-p','veil-session','--lib'])
run('release-build',['build','--release','-p','veilclient-ffi','--features','production-seeds,node-embedded,packet-tunnel'])
