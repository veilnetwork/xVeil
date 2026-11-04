import unittest
from analyze import analyze, PHASES

def row(**changes):
    values=dict(v=1,total_ns=110,sync_ns=60,sync_count=4,kv_ops=1,log_records=1,ok=1,hardening_ok=1,pad_slots=0,reused=0,**{p+'_ns':10 for p in PHASES})
    values.update(changes)
    return 'xv_hv_commit_probe '+' '.join(f'{k}={v}' for k,v in values.items())

class ProbeAnalysis(unittest.TestCase):
    def test_separates_boots_and_never_exports_other_logs(self):
        result=analyze(['raw user body /private/secret', 'Shell: xv_hv_commit_probe_begin v=1','Shell: '+row(),'xv_hv_commit_probe_begin v=1',row(pad_slots=64,reused=8)])
        first,second=result['sessions']
        self.assertEqual(first['completedRecords'],1)
        self.assertEqual(first['successfulCleanHardening'],1)
        self.assertEqual(second['successfulCleanHardening'],0)
        self.assertNotIn('secret',str(result))
        self.assertEqual(first['totalNs'],sum(first['phaseNs'].values()))
    def test_failed_and_noop_are_not_successful_real_commits(self):
        first=analyze(['xv_hv_commit_probe_begin v=1',row(ok=0),row(kv_ops=0,log_records=0,sync_count=0,sync_ns=0)])['sessions'][0]
        self.assertEqual(first['failedRecords'],1)
        self.assertEqual(first['realCommits'],0)
        bad=analyze(['xv_hv_commit_probe_begin v=1',row(hardening_ok=0)])['sessions'][0]
        self.assertEqual(bad['hardeningFailedRecords'],1)
        self.assertEqual(bad['successfulCleanHardening'],0)
    def test_refuses_incomplete_or_malformed_capture(self):
        for lines in [[],[row()],['xv_hv_commit_probe_begin v=2',row()],['xv_hv_commit_probe_begin v=1',row(),'xv_hv_commit_probe_capped v=1']]:
            with self.subTest(lines=lines):
                with self.assertRaises(ValueError): analyze(lines)
        for record in [row(total_ns=109),row(sync_ns=111),row(sync_count=0),row(ok=2),row()+' secret=/private/file',row()+' v=1',row().replace('kv_ops=1','kv_ops=-1'),row()+row()]:
            with self.subTest(record=record):
                with self.assertRaises(ValueError): analyze(['xv_hv_commit_probe_begin v=1',record])

if __name__=='__main__': unittest.main()
