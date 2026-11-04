//! Private stand-only module. Installer copies it into an isolated HVS tree.
//! Never linked by the project's normal dependency or release build.
use std::{cell::Cell, sync::{OnceLock, atomic::{AtomicUsize, Ordering}}, time::Instant};

const PHASES: [&str; 11] = ["setup", "log", "index", "data_sync", "commit_write", "intent_sync", "publish", "padding", "churn", "hardening_sync", "tail"];
static ENABLED: OnceLock<bool> = OnceLock::new();
static RECORDS: AtomicUsize = AtomicUsize::new(0);
thread_local! { static SYNCS: Cell<(u64, u64)> = const { Cell::new((0, 0)) }; }
fn enabled() -> bool {
    *ENABLED.get_or_init(|| {
        let wanted = std::env::var("XVEIL_PRIVATE_HV_COMMIT_PROFILE").unwrap_or_default();
        let active = wanted == "1" || (!wanted.is_empty() && std::env::var("XVEIL_E2E_WORKER_LABEL").ok().as_deref() == Some(wanted.as_str()));
        if active { eprintln!("xv_hv_commit_probe_begin v=1"); }
        active
    })
}

pub(crate) struct SyncGuard(Option<Instant>);
impl SyncGuard {
    pub(crate) fn new() -> Self { Self(enabled().then(Instant::now)) }
}
impl Drop for SyncGuard {
    fn drop(&mut self) {
        if let Some(start) = self.0 {
            SYNCS.with(|s| { let (n, ns) = s.get(); s.set((n + 1, ns + start.elapsed().as_nanos() as u64)); });
        }
    }
}
struct Active {
    start: Instant, last: u64, phases: [u64; 11], kv: usize, logs: usize,
    ok: bool, hardening_ok: bool, pad_slots: u64, reused: u64,
}
pub(crate) struct CommitProbe(Option<Active>);
impl CommitProbe {
    pub(crate) fn new(kv: usize, logs: usize) -> Self {
        Self(if enabled() {
            SYNCS.with(|s| s.set((0, 0)));
            Some(Active { start: Instant::now(), last: 0, phases: [0; 11], kv, logs, ok: false, hardening_ok: false, pad_slots: 0, reused: 0 })
        } else { None })
    }
    pub(crate) fn mark(&mut self, i: usize) {
        if let Some(a) = &mut self.0 { let at = a.start.elapsed().as_nanos() as u64; a.phases[i] += at - a.last; a.last = at; }
    }
    pub(crate) fn hardening(&mut self, ok: bool, pad_slots: u64, reused: u64) {
        if let Some(a) = &mut self.0 { a.hardening_ok = ok; a.pad_slots = pad_slots; a.reused = reused; }
    }
    pub(crate) fn success(&mut self) { if let Some(a) = &mut self.0 { a.ok = true; } }
}
impl Drop for CommitProbe {
    fn drop(&mut self) {
        let Some(a) = &mut self.0 else { return; };
        let total = a.start.elapsed().as_nanos() as u64;
        a.phases[10] += total - a.last;
        let (sync_count, sync_ns) = SYNCS.with(Cell::get);
        let n = RECORDS.fetch_add(1, Ordering::Relaxed);
        if n >= 25000 {
            if n == 25000 { eprintln!("xv_hv_commit_probe_capped v=1"); }
            return;
        }
        // Durations/counts only: no keys, IDs, paths, payloads or namespaces.
        let mut row = format!("xv_hv_commit_probe v=1 total_ns={total} sync_ns={sync_ns} sync_count={sync_count} kv_ops={} log_records={} ok={} hardening_ok={} pad_slots={} reused={}", a.kv, a.logs, u8::from(a.ok), u8::from(a.hardening_ok), a.pad_slots, a.reused);
        for (name, ns) in PHASES.iter().zip(a.phases) { row.push_str(&format!(" {name}_ns={ns}")); }
        eprintln!("{row}");
    }
}
