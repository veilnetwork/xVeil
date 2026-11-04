import hashlib, subprocess, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
import install

class InstallerSafety(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='xv-probe-tool-',dir='/private/tmp' if Path('/private/tmp').is_dir() else None)
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.main=self.root/'main';self.main.mkdir()
        self.git(self.main,'init','--initial-branch=main')
        source=self.main/'crates/hidden-volume/src';(source/'container').mkdir(parents=True)
        (source/'lib.rs').write_text('pub mod chunk;\n')
        (source/'container/file.rs').write_text('unsupported source shape\n')
        self.git(self.main,'add','.')
        self.git(self.main,'-c','commit.gpgsign=false','-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','fixture')
        self.head=self.git(self.main,'rev-parse','HEAD').strip()
        self.work=self.root/'work'
        self.git(self.main,'worktree','add','--detach',str(self.work),self.head)
        self.base=patch.object(install,'BASE',self.head);self.base.start();self.addCleanup(self.base.stop)
    def git(self,where,*args):
        result=subprocess.run(['git',*args],cwd=where,capture_output=True,text=True,check=True)
        return result.stdout
    def snapshot(self,path):
        return {str(p.relative_to(path)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (path/'crates').rglob('*') if p.is_file()}
    def test_primary_checkout_is_never_changed(self):
        before=self.snapshot(self.main)
        with self.assertRaisesRegex(ValueError,'detached'): install.install(self.main)
        self.assertEqual(self.snapshot(self.main),before)
    def test_detached_primary_and_dirty_linked_are_refused(self):
        self.git(self.main,'checkout','--detach')
        with self.assertRaisesRegex(ValueError,'linked private'): install.install(self.main)
        (self.work/'untracked-user-file').write_text('preserve')
        before=self.snapshot(self.work)
        with self.assertRaisesRegex(ValueError,'clean'): install.install(self.work)
        self.assertEqual(self.snapshot(self.work),before)
    def test_all_source_anchors_are_checked_before_any_write(self):
        before=self.snapshot(self.work)
        with self.assertRaisesRegex(ValueError,'source anchor mismatch'): install.install(self.work)
        self.assertEqual(self.snapshot(self.work),before)
        self.assertEqual(self.git(self.work,'status','--porcelain'),'')

if __name__=='__main__': unittest.main()
