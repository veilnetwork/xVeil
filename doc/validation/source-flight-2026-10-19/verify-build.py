from pathlib import Path
import subprocess,os,json,time
r=Path(__file__).parent;clean=r/'sdk-src'
env=dict(os.environ,TMPDIR='/private/tmp/',CARGO_TARGET_DIR='/Users/<user>/.cache/codex/veil-qos-target-20261016')
def run(label,args,expected=0):
 start=time.monotonic()
 with (r/(label+'.txt')).open('w') as log:p=subprocess.run(['cargo',*args],cwd=clean,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=600)
 row={'exit_code':p.returncode,'elapsed_s':round(time.monotonic()-start,3)};(r/(label+'-status.json')).write_text(json.dumps(row)+'\n');print(json.dumps({label:row}),flush=True)
 assert p.returncode==expected;return (r/(label+'.txt')).read_text()
def negative(label,file,old,new,args,message):
 p=clean/file;original=p.read_text();assert old in original
 try:
  p.write_text(original.replace(old,new,1));log=run(label,args,101);assert message in log
 finally:p.write_text(original)
proto='third_party/quinn-proto/src/connection/mod.rs';original=(clean/proto).read_text();a=original.index('    fn local_congestion_window(&self, now: Instant) -> u64 {');b=original.index('\n    /// Whether we have 1-RTT data to send',a)
negative('negative-ignored-pool',proto,original[a:b],'    fn local_congestion_window(&self, _now: Instant) -> u64 { self.path.congestion.window() }\n',['test','--manifest-path','third_party/quinn-proto/Cargo.toml','--lib','a_local_budget_limits_real_packets'],'GSO preparation exceeded the shared flight limit')
negative('negative-ignored-idle',proto,'budget.0.app_limited(now);','/* deliberately omitted idle propagation */',['test','--manifest-path','third_party/quinn-proto/Cargo.toml','--lib','a_local_budget_limits_real_packets'],'drained sender must retire old budget demand')
flight='crates/veil-session/src/local_source_flight.rs'
negative('negative-old-window-witness',flight,'used == window','true',['test','-p','veil-session','--lib','a_new_window_requires_a_new_blocked_send_not_old_waiting_history'],'old waiting history cannot spend an unfilled new window')
negative('negative-old-reserve-witness',flight,'reserved == reserve','true',['test','-p','veil-session','--lib','changing_primary_reserve_cannot_reprice_old_credit'],'a larger primary reserve must invalidate the old waiting/credit scope')
run('protocol-tests',['test','--manifest-path','third_party/quinn-proto/Cargo.toml','--lib'])
run('session-tests',['test','-p','veil-session','--lib'])
run('release-build',['build','--release','-p','veilclient-ffi','--features','production-seeds,node-embedded,packet-tunnel'])
