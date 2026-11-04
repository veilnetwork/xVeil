"""Install timing-only edits in a detached, private HVS worktree; never main."""
from pathlib import Path
import subprocess, sys

BASE = 'eceb9158015bd391494d91acc6fca00d44b7938a'

def require(condition, message):
    if not condition: raise ValueError(message)

def install(repo):
    repo = repo.resolve()
    require(subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip() == BASE, 'unsupported baseline')
    require(subprocess.run(['git','symbolic-ref','-q','HEAD'],cwd=repo,stdout=subprocess.PIPE,stderr=subprocess.PIPE).returncode == 1, 'requires detached checkout')
    require((repo/'.git').is_file(), 'requires a linked private worktree')
    gitdir=subprocess.check_output(['git','rev-parse','--absolute-git-dir'],cwd=repo,text=True).strip()
    common=subprocess.check_output(['git','rev-parse','--path-format=absolute','--git-common-dir'],cwd=repo,text=True).strip()
    require(gitdir != common, 'refuses primary checkout')
    require(not repo.is_relative_to(Path(__file__).resolve().parents[3]), 'refuses application tree')
    require(subprocess.check_output(['git','status','--porcelain'],cwd=repo) == b'', 'requires clean checkout')
    core = repo/'crates/hidden-volume/src'
    staged={}
    def edit(relative, replacements):
        p=core/relative; text=p.read_text()
        for old,new in replacements:
            require(text.count(old)==1, 'source anchor mismatch: '+relative)
            text=text.replace(old,new)
        staged[p]=text
    edit('lib.rs', [('pub mod chunk;', 'pub(crate) mod commit_probe;\npub mod chunk;')])
    staged[core/'commit_probe.rs']=Path(__file__).with_name('probe.rs').read_text()
    edit('container/file.rs', [('        self.file.sync_all()?;\n        Ok(())\n    }\n}', '        let _probe_sync = crate::commit_probe::SyncGuard::new();\n        self.file.sync_all()?;\n        Ok(())\n    }\n}')])
    edit('space/commit.rs', [
      ('''    ) -> Result<u64> {
        // Audit pass 7 (C1)''', '''    ) -> Result<u64> {
        let mut probe = crate::commit_probe::CommitProbe::new(pending.values().map(Vec::len).sum(), pending_log.values().map(Vec::len).sum());
        // Audit pass 7 (C1)'''),
      ('            return Ok(self.state.superblock.seq);', '            probe.success();\n            return Ok(self.state.superblock.seq);'),
      ('        // Phase 0: Flush', '        probe.mark(0);\n        // Phase 0: Flush'),
      ('        // 1. For each touched namespace', '        probe.mark(1);\n        // 1. For each touched namespace'),
      ('        new_roots.sort_by_key(|r| r.namespace.0);\n\n        self.file.fsync()?;', '        new_roots.sort_by_key(|r| r.namespace.0);\n        probe.mark(2);\n        self.file.fsync()?;\n        probe.mark(3);'),
      ('        let commit_slot = self.place_chunk(ChunkKind::Commit, new_seq, &cp_bytes)?;\n        self.file.fsync()?;', '        let commit_slot = self.place_chunk(ChunkKind::Commit, new_seq, &cp_bytes)?;\n        probe.mark(4);\n        self.file.fsync()?;\n        probe.mark(5);'),
      ('        self.publish_superblock(&new_sb, "committing")?;', '        self.publish_superblock(&new_sb, "committing")?;\n        probe.mark(6);'),
      ('        // One churned decoy per slot this commit reused.', '        probe.mark(7);\n        // One churned decoy per slot this commit reused.'),
      ('        // One fsync for whatever landed,', '        probe.mark(8);\n        // One fsync for whatever landed,'),
      ('        // First failure reported WITH THE STEP IT CAME FROM,', '        probe.mark(9);\n        probe.hardening(padding_result.is_ok() && churn_result.is_ok() && sync_result.is_ok(), self.file.slot_count().saturating_sub(pad_from), reused as u64);\n        // First failure reported WITH THE STEP IT CAME FROM,'),
      ('        Ok(new_seq)\n    }\n}', '        probe.success();\n        Ok(new_seq)\n    }\n}'),
    ])
    for path,text in staged.items(): path.write_text(text)

if __name__ == '__main__': install(Path(sys.argv[1]))
