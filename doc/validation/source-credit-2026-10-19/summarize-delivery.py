from pathlib import Path
import collections,json,re,sys
root=Path(sys.argv[1]); groups={}; total=0
for log in sorted(set(root.rglob('native.log')) | set(root.rglob('runtime.log'))):
 for line in log.open(errors='replace'):
  if 'session.rt_trace.datagram_admission' not in line or 'confirmed_delivery_supported=true' not in line:continue
  f=dict(re.findall(r'([a-z_]+)=([^ ]+)',line.strip()))
  if not all(x in f for x in ['connection_trace_id','local_slot','confirmed_delivery_epoch']):continue
  total+=1
  key=(str(log.relative_to(root)),int(f['connection_trace_id']),int(f['local_slot']),f.get('independent')=='true')
  g=groups.setdefault(key,dict(rows=0,epochs=set(),progress_rows=0,cached_rows=0,empty_rows=0,validation_pending_rows=0,counter_regressions=0,incoherent_rows=0,min_positive_ack_age_us=None,max_ack_age_us=0,last=None))
  epoch=int(f['confirmed_delivery_epoch']); b=int(f['confirmed_delivery_bytes']);p=int(f['confirmed_delivery_packets']);age=int(f['confirmed_delivery_ack_age_us']);span=int(f['confirmed_delivery_send_span_us']);sent_age=int(f['confirmed_delivery_sent_age_us'])
  g['rows']+=1;g['epochs'].add(epoch)
  if f['confirmed_delivery_validation_pending']=='true':g['validation_pending_rows']+=1
  if b==0 or p==0:g['empty_rows']+=1
  elif min(age,span,sent_age)<0 or sent_age<age:g['incoherent_rows']+=1
  if age>=0:g['max_ack_age_us']=max(age,g['max_ack_age_us']);g['min_positive_ack_age_us']=age if g['min_positive_ack_age_us'] is None else min(age,g['min_positive_ack_age_us'])
  old=g['last']
  if old is not None and old[0]==epoch:
   if b<old[1] or p<old[2]:g['counter_regressions']+=1
   elif b>old[1] and p>old[2]:g['progress_rows']+=1
   else:g['cached_rows']+=1
  g['last']=(epoch,b,p)
rows=[]
for key,g in sorted(groups.items()):
 log,connection,slot,independent=key;g['epochs']=sorted(g['epochs']);g['last_epoch'],g['last_bytes'],g['last_packets']=g.pop('last')
 rows.append(dict(log=log,connection_trace_id=connection,local_slot=slot,independent=independent,**g))
out=dict(observation_only=True,capacity_grant=False,scope='Explicit ACKed retained current-route congestion-counted QUIC Data; includes connection control. No sum across peers or allocation inferred.',rows=total,connections=rows)
(root/'confirmed-delivery-observations.json').write_text(json.dumps(out,indent=2)+'\n')
print(json.dumps(dict(rows=total,connection_slot_groups=len(rows),progress_rows=sum(g['progress_rows'] for g in rows),cached_rows=sum(g['cached_rows'] for g in rows),counter_regressions=sum(g['counter_regressions'] for g in rows),incoherent_rows=sum(g['incoherent_rows'] for g in rows))))
