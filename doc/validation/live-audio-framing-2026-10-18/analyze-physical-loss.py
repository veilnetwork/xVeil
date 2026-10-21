from pathlib import Path
import re,json,collections,statistics
base=Path('/Users/<user>/.cache/codex/xveil-playout-budget-20261018/qa-v2/physical-playout-budget-video');out={}
def parse(path,prefix):
 return [dict((k,int(v)) for k,v in re.findall(r'(\w+)=(-?\d+)',s)) for s in path.read_text().splitlines() if s.startswith(prefix)]
for sender,receiver in [('mac','phone'),('phone','mac')]:
 tx=parse(base/(sender+'-native.log'),'audio.rtp.send ');enc=parse(base/(sender+'-native.log'),'audio.encode ');rx=parse(base/(receiver+'-native.log'),'audio.rtp.ingress ')
 assert len(tx)<32768 and len(enc)<32768 and len(rx)<32768
 for peer,prefix,rows in [(sender,'audio.rtp.send.begin ',tx),(sender,'audio.encode.begin ',enc),(receiver,'audio.rtp.ingress.begin ',rx)]:
  begin=parse(base/(peer+'-native.log'),prefix)
  assert len(begin)==1 and begin[0]['count']==len(rows)
  if 'seen' in begin[0]:assert begin[0]['seen']==len(rows)
 assert len({(p['seq'],p['timestamp']) for p in tx})==len(tx)
 assert len({p['timestamp'] for p in enc})==len(enc)
 assert len({(p['seq'],p['timestamp']) for p in rx})==len(rx)
 offset=(tx[0]['timestamp']-enc[0]['timestamp'])%(2**32)
 enc_by_ts={(e['timestamp']+offset)%(2**32):e for e in enc};seen=set();classified=[];mismatch=[]
 received={(r['seq'],r['timestamp']):r for r in rx}
 for p in tx:
  e=enc_by_ts.get(p['timestamp']);is_payload=e is not None and p['timestamp'] not in seen and p['packet_bytes']==e['bytes']+20
  if is_payload:seen.add(p['timestamp'])
  r=received.get((p['seq'],p['timestamp']))
  if r and r['payload_bytes']!=(e['bytes'] if is_payload else 0):mismatch.append({'tx':p,'rx':r,'encoder':e,'classified_payload':is_payload})
  classified.append({'kind':'payload' if is_payload else 'padding','sent':p,'received':r,'encoder':e if is_payload else None,'relative_send_seconds':(p['attempted_us']-tx[0]['attempted_us'])/1e6})
 assert len(seen)==len(enc),(sender,len(seen),len(enc))
 assert not mismatch,(sender,mismatch[:2])
 def summarize(rows):
  counter=collections.Counter((r['kind'],'received' if r['received'] else 'missing') for r in rows)
  missing=[r for r in rows if not r['received']]
  return {'counts':{'/'.join(k):v for k,v in counter.items()},'missing_payloads':[{'seq':r['sent']['seq'],'timestamp':r['sent']['timestamp'],'relative_send_seconds':round(r['relative_send_seconds'],4),'packet_bytes':r['sent']['packet_bytes'],'encoded_blocks':r['encoder']['blocks']} for r in missing if r['kind']=='payload'],'all_locally_accepted':all(r['sent']['accepted'] for r in rows)}
 out[sender+'->'+receiver]={'rtp_clock_offset':offset,'encoded_packets':len(enc),'all_encoder_records_match_exactly_one_transmission':True,'classification_validated_against_every_received_payload_length':True,'whole':summarize(classified),'interior_1s_to_last_minus_1s':summarize([r for r in classified if 1<=r['relative_send_seconds']<=classified[-1]['relative_send_seconds']-1]),'tail_180_to_237s':summarize([r for r in classified if 180<=r['relative_send_seconds']<=237])}
 # Preserve private join to inspect exact missing sequence/encoder timing.
 Path(__file__).with_name(sender+'-joined.json').write_text(json.dumps(classified))
Path(__file__).with_name('loss-attribution.json').write_text(json.dumps(out,indent=2)+'\n')
for n,x in out.items():print(json.dumps({'direction':n,'encoded_packets':x['encoded_packets'],'whole':x['whole']['counts'],'interior':x['interior_1s_to_last_minus_1s']['counts'],'tail':x['tail_180_to_237s']['counts'],'missing_interior_payloads':x['interior_1s_to_last_minus_1s']['missing_payloads'][:8]}))
