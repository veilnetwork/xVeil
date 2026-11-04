"""Aggregate private completed-commit records. No raw log text is re-exported."""
from pathlib import Path
import json, re, sys

TOKEN = 'xv_hv_commit_probe'
PHASES = ('setup','log','index','data_sync','commit_write','intent_sync','publish','padding','churn','hardening_sync','tail')
FIELDS = {'v','total_ns','sync_ns','sync_count','kv_ops','log_records','ok','hardening_ok','pad_slots','reused'} | {p+'_ns' for p in PHASES}

def fields(text, expected):
    result={}
    for item in text.split():
        pair=item.split('=')
        if len(pair)!=2 or pair[0] in result or not re.fullmatch(r'[0-9]{1,20}',pair[1]): raise ValueError('invalid probe fields')
        key,value=pair[0],int(pair[1])
        if value>2**64-1: raise ValueError('probe field exceeds u64')
        result[key]=value
    if set(result)!=expected or result['v']!=1: raise ValueError('unexpected probe schema')
    return result

def analyze(lines):
    sessions=[]
    for line in lines:
        if TOKEN not in line: continue
        if line.count(TOKEN)!=1: raise ValueError('joined probe records')
        text=line[line.index(TOKEN)+len(TOKEN):].strip()
        if text.startswith('_capped'): raise ValueError('capped probe is incomplete')
        if text.startswith('_begin '):
            fields(text[len('_begin '):],{'v'})
            sessions.append([])
            continue
        if not sessions: raise ValueError('record before probe begin')
        row=fields(text,FIELDS)
        if row['ok'] not in (0,1) or row['hardening_ok'] not in (0,1): raise ValueError('invalid outcome')
        if row['total_ns'] != sum(row[p+'_ns'] for p in PHASES): raise ValueError('phase coverage differs from total')
        if row['sync_ns']>row['total_ns']: raise ValueError('sync exceeds total')
        if row['sync_count']==0 and row['sync_ns']!=0: raise ValueError('sync duration without sync')
        sessions[-1].append(row)
    if not sessions or not any(sessions): raise ValueError('no completed commit records')
    summaries=[]
    for index,rows in enumerate(sessions):
        good=[r for r in rows if r['ok']]
        real=[r for r in good if r['kv_ops']+r['log_records']>0]
        clean=[r for r in real if r['hardening_ok'] and r['pad_slots']==0 and r['reused']==0]
        summaries.append({'boot':index+1,'completedRecords':len(rows),'successfulRecords':len(good),'failedRecords':len(rows)-len(good),
          'totalNs':sum(r['total_ns'] for r in good),'syncNs':sum(r['sync_ns'] for r in good),'syncCount':sum(r['sync_count'] for r in good),
          'phaseNs':{p:sum(r[p+'_ns'] for r in good) for p in PHASES},
          'hardeningFailedRecords':sum(not r['hardening_ok'] for r in real),'realCommits':len(real),'successfulCleanHardening':len(clean),'cleanHardeningSyncNs':sum(r['hardening_sync_ns'] for r in clean),
          'paddingSlots':sum(r['pad_slots'] for r in good),'reusedSlots':sum(r['reused'] for r in good)})
    return {'schema':'xveil-private-hv-commit-summary/1','sessions':summaries}

if __name__=='__main__': print(json.dumps(analyze(Path(sys.argv[1]).read_text().splitlines())))
