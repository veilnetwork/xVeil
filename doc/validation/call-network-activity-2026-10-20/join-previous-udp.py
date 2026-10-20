from pathlib import Path
import json,re,statistics,sys
# Usage: python3 join-previous-udp.py PRIVATE_BASELINE_DIRECTORY OUTPUT_JSON
r=Path(sys.argv[1]); output=Path(sys.argv[2])
result=json.loads((r/'result.json').read_text());origins={n:result['pcm_stopped'][n]['probes'][0]['origin'] for n in ['mac','phone']}
lines={n:(r/f).read_text(errors='replace').splitlines() for n,f in [('mac','mac-runtime.log'),('phone','phone-logcat.log')]}
def fields(line):return dict(re.findall(r'(\w+)=([^\s]+)',line))
zeros={}
for n in lines:
 values=[fields(x) for x in lines[n] if 'media.cell.sample' in x]
 z=[int(v['at_ms'])/1000-int(v['monotonic_us'])/1e6+origins[n] for v in values]
 zeros[n]=statistics.median(z)
cs={n:[c for c in result['clock_calibrations'] if c['name']==n] for n in lines}
shift={n:origins[n]+cs[n][0]['mid'] for n in lines}
clocklo=(min(c['low'] for c in cs['mac'])-cs['mac'][0]['mid'])-(max(c['high'] for c in cs['phone'])-cs['phone'][0]['mid'])
clockhi=(max(c['high'] for c in cs['mac'])-cs['mac'][0]['mid'])-(min(c['low'] for c in cs['phone'])-cs['phone'][0]['mid'])
sent={};received={}
for n in lines:
 for line in lines[n]:
  if 'quic.udp_wire.sample' not in line:continue
  v=fields(line)
  if n=='phone' and v.get('stage')=='send' and v.get('connection_trace_id')=='37':sent[(v['digest'],v['bytes'])]=v
  if n=='mac' and v.get('stage')=='receive':received[(v['digest'],v['bytes'])]=v
joined=[]
for key,s in sent.items():
 t=int(s['at_ms'])/1000-zeros['phone']
 if not 47<=t<=53 or key not in received:continue
 v=received[key];recv=int(v['at_ms'])/1000-zeros['mac'];kernel=int(v['kernel_recv_ns'])/1e9-zeros['mac']
 delay=(recv-t+shift['mac']-shift['phone'])*1000;kdelay=(kernel-t+shift['mac']-shift['phone'])*1000
 joined.append({'digest':key[0],'bytes':int(key[1]),'phone_elapsed':t,'mac_receive_elapsed':recv,'receive_delay_ms':delay,'kernel_receive_delay_ms':kdelay,'kernel_receive_delay_interval_ms':[kdelay+clocklo*1000,kdelay+clockhi*1000],'kernel_to_userspace_ms':(recv-kernel)*1000})
joined.sort(key=lambda v:v['receive_delay_ms'],reverse=True)
proof={'baseline':'physical-call-pcm-close-final','method':'ciphertext digest+bytes; source37; sender47-53s; sampled native clock envelope','origins':origins,'wall_zero':zeros,'joined':joined,'limitations':['UDP send log does not prove NIC departure','Sampled clock envelope does not bound unsampled drift','Not an acoustic measurement or identification of power-management cause']}
output.write_text(json.dumps(proof,indent=2));print(json.dumps({'matched':len(joined),'worst':joined[0] if joined else None},indent=2))
