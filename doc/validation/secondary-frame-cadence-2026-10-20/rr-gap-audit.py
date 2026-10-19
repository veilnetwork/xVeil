"""Exact receiver gaps in the report that triggered an app video cut.

Run from the xVeil root. Uses validated owned same-host metadata, no payloads.
Cumulative RR loss counts cannot identify missing payloads by themselves.
"""
from pathlib import Path
from collections import defaultdict
import json, sys
sys.path.insert(0, str(Path.cwd()/'scripts'))
from analyze_video_loss import read_trace, direction, unwrap, report_key

p=Path(sys.argv[1]);native=read_trace(p/'native.log')
summary=json.loads((p/'summary.json').read_text())
assert summary['loopback_only'], 'This audit is for the owned same-host fixture'
rows=json.loads((p/'codec-samples.json').read_text());result=[]
for x in rows:
 d=x['policy']['audioAdaptation']['latest']
 if not (d['level_after']>d['level_before'] and d['video_network_loss']):continue
 event=x['stats']['video_persistent_loss_report_us']
 arrived=[r for r in native['rr'] if r['stage']=='r' and r['at_us']==event and r['result']==0]
 assert len(arrived)==1, 'Missing/ambiguous exact source report'
 received=arrived[0];ssrc=received['ssrc']
 emitted=[r for r in native['rr'] if r['stage']=='s' and r['result']==0 and report_key(r)==report_key(received)]
 assert len(emitted)==1, 'Missing/ambiguous exact receiver report'
 report=emitted[0]
 filtered={k:[r for r in v if r['ssrc']==ssrc] for k,v in native.items()}
 direction(filtered,filtered)  # Validate the extended RR sequence space.
 sends=unwrap([r for r in filtered['rtp'] if r['stage']=='s'])
 delivered=unwrap([r for r in filtered['rtp'] if r['stage']=='d'],sends[0]['extended'])
 first=min((r for r in filtered['rr'] if r['stage']=='s' and r['result']==0),key=lambda r:r['at_us'])
 anchors=[r for r in delivered if r['seq']==first['highest']%65536 and r['at_us']<=first['at_us']]
 assert anchors
 offset=first['highest']-anchors[-1]['extended']
 attempts=defaultdict(list);seen=set()
 for r in sends:attempts[r['extended']+offset].append(r)
 for r in delivered:
  if r['at_us']<=report['at_us']:seen.add(r['extended']+offset)
 low=min(r['extended']+offset for r in delivered)
 assert 0<=report['highest']-low<65536, 'Sequence range exceeds this bounded audit'
 gaps=[]
 for sequence in range(low,report['highest']+1):
  if sequence in seen:continue
  sent=attempts[sequence];sizes=sorted({r['payload'] for r in sent})
  kind='unknown' if not sizes or (0 in sizes and len(sizes)>1) else 'padding' if sizes==[0] else 'image_payload'
  gaps.append(dict(sequence=sequence,kind=kind,payload_sizes=sizes,successful_native_attempts=sum(r['result']==0 for r in sent)))
 result.append(dict(side=x['side'],cut_seconds=x['t'],source_ssrc=ssrc,
  exact_source_report_us=event,exact_receiver_report_us=report['at_us'],
  reported_cumulative_lost=report['lost'],highest_sequence=report['highest'],gaps_at_receiver_report=gaps))
print(json.dumps(dict(scope='Receiver gaps at exact RTCP confirmation, not a deployable sender-only loss classifier.',cuts=result),indent=2))
