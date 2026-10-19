from pathlib import Path
import json,subprocess,sys,datetime
r=Path(__file__).parent;kind=sys.argv[1];assert kind in ['group','pair']
folder='group-final-360' if kind=='group' else 'pair-rtp-lag-full'
procfile='group-final-processes-live.json' if kind=='group' else 'pair-processes-live.json'
rows=json.loads((r/procfile).read_text());current={int(s.split(None,1)[0]):s.split(None,1)[1] for s in subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines()};remaining=[v['pid'] for v in rows if current.get(v['pid'])==v['command']];assert not remaining,remaining
summary=json.loads((r/folder/'summary.json').read_text());assert all(x==0 for x in summary['node_stop_results'])
if kind=='group':
 assert summary['workers_exited'] and summary['remaining_sockets']==0
 assert all(v['file_thread_exited'] and v['policy_exit_code']==0 for v in summary['workers'])
 cleanup={k:summary[k] for k in ['workers_exited','node_stop_results','remaining_sockets']}
else:
 assert summary['remaining_fixture_sockets']==0
 assert all(summary[k] is True for k in ['audio_thread_exited','file_threads_exited','policy_exited'])
 cleanup={k:summary[k] for k in ['audio_thread_exited','file_threads_exited','policy_exited','node_stop_results','remaining_fixture_sockets']}
transient=[v for v in rows if v['command'].startswith('ps ')];proof={'checked_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'recorded_processes_checked':len(rows),'long_lived_processes_checked':len(rows)-len(transient),'transient_recorders_checked':len(transient),'remaining':remaining,**cleanup};(r/(kind+'-independent-cleanup.json')).write_text(json.dumps(proof,indent=2)+'\n');print(proof)
