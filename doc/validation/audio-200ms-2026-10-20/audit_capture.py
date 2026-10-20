from pathlib import Path
import json,hashlib,sys,subprocess
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts'))
from group_pcm_timing import analyze_voice_path
from decoded_video_progress import decoded_counter_rate
from analyze_relay_audio_pipeline import fields

d=Path(sys.argv[1]);s=json.loads((d/'summary.json').read_text());inputs={}
def read(name):
 data=(d/name).read_bytes();inputs[name]=hashlib.sha256(data).hexdigest();return json.loads(data)
checks={};checks['raw_verdicts']=s['ok'] is True and s['contention_qualification'] is True
checks['full_workload']=s['duration_seconds']==360 and s['rate_kbps']==1024 and s['video_file_load'] is True and s['load_kind']=='both' and s['adaptive'] is True and s['test_ptime_requested'] is None
checks['separate_processes']=s['separate_sdk_processes'] is True and len(set(s['worker_pids']))==3
checks['neutral_relay']=s['neutral_relay_route_verified'] is True and s['end_topology']=={'verified':True,'active_session_counts':[3,1,1,1]}
pcm={i:read(f'worker-{i}/pcm-samples.json') for i in range(3)}
paths=[]
for path in s['voice_paths']:
 a,b=path['source'],path['receiver'];captures=[r for r in pcm[a] if r['side']==a*4];decoded=[r for r in pcm[b] if r['side']==b*3+a]
 actual=analyze_voice_path(decoded,360,captures)
 assert actual['phases']==path['phases'],('voice summary changed',a,b)
 paths.append({'source':a,'receiver':b,'matched':sum(r['matched'] for r in actual['phases']),'missing':sum(r['missing'] for r in actual['phases']),'max_ms':max(r['max_ms'] for r in actual['phases'])})
checks['six_ordinal_voice_paths']=len(paths)==6 and len({(r['source'],r['receiver']) for r in paths})==6 and sum(r['matched'] for r in paths)==2112 and all(r['missing']==0 and r['max_ms']<200 for r in paths)
checks['capture_coverage']=all(v['first_capture']<.1 and v['last_capture']>=359.9 for v in s['voice_paths'])
video=[]
for i in range(3):
 rows=read(f'worker-{i}/decoded-video-samples.json')
 for peer in range(3):
  if i==peer:continue
  selected=[r for r in rows if r['source']==peer and 20<=r['t']<=360];tail=[r for r in selected if r['t']>=345];changes=sum(a['sha256']!=b['sha256'] for a,b in zip(tail,tail[1:]))
  saved=next(r for r in s['video_paths'] if r['source']==peer and r['receiver']==i)
  assert changes==saved['tail_changes'] and saved['required_tail_content_changes']==14
  video.append({'source':peer,'receiver':i,'tail_changes':changes,'decoded_counter':decoded_counter_rate(selected)})
checks['six_video_tails']=len(video)==6 and all(r['tail_changes']>=14 for r in video)
checks['three_files']=len(s['files'])==3 and all(f['queued']==524288 and f['received']==524288 and f['hash_matches'] is True and f['missing_chunks']==0 and f['authentication_errors']==0 and f['duplicates']==0 and not f['async_failures'] and f['write_error'] is False and f['completion_seconds']<360 for f in s['files'])
checks['clock_integrity']=all(w['clock']['late_intervals']==0 and w['clock']['dropped_rows']==0 and not any(w['clock']['failures']) and w['clock']['deadline_active']==1 and w['clock']['deadline_misses']==0 and w['clock']['max_interval_ms']<40 for w in s['workers'])
quality=[]
for w in s['workers']:
 st=w['final_native_stats'];rs=list(st['audio_receivers'].values());quality.append({'worker':w['participant'],'sampled_at_seconds':w['final_native_stats_seconds'],'worker_stalled':st['worker_stalled'],'receivers':rs})
checks['complete_final_receiver_quality']=len(quality)==3 and all(q['sampled_at_seconds']>=361 and q['worker_stalled']==0 and len(q['receivers'])==2 and all(r['audio_interruption_count']==0 and r['audio_interruption_duration_ms']==0 and 0<=r['audio_rx_native_age_ms']<1000 and r['audio_rx_pkts']>0 and r['audio_output_emitted_samples']>=360*48000 for r in q['receivers']) for q in quality)
wire=read('wire-samples.json');last=[0.,0.];accurate=True
for r in wire:
 if r.get('dropped'):accurate=False;continue
 dr=r['direction'];ready=max(last[dr],r['at'])+r['bytes']*8/1024000
 if abs(ready-r['ready'])>1e-8:accurate=False
 last[dr]=r['ready']
checks['neutral_fifo_schedule']=accurate and not s['shaper']['trace_truncated'] and s['shaper']['trace_events']==len(wire) and s['shaper']['failure'] is None and all(r['drops']==0 for r in s['shaper']['stats'])
record={'checks':checks,'all_pass':all(checks.values()),'voice_paths':paths,'video_paths':video,'final_receiver_quality':quality,'input_sha256':inputs,'summary_sha256':hashlib.sha256((d/'summary.json').read_bytes()).hexdigest(),'scope':['Same-host synthetic PCM and decoded video, not acoustic delay','One shared neutral FIFO per direction, unchanged 1024-kbit/s load','No threshold relaxation, timestamp rephasing or shortened capture']}
Path(sys.argv[2]).write_text(json.dumps(record,indent=2)+'\n');print(json.dumps({'checks':checks,'all_pass':record['all_pass'],'max_voice_ms':max(r['max_ms'] for r in paths)},indent=2))
