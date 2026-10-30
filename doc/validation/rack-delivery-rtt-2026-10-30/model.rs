#![allow(dead_code, unused_imports)]

use veil_onion_stream::engine::{Config, Event, StreamEngine};
use veil_onion_stream::wire::{Frame, reset_reason};

/// Tiny deterministic PRNG (SplitMix64) — no external dep.
struct Rng(u64);
impl Rng {
    fn new(seed: u64) -> Self {
        Rng(seed)
    }
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    /// Uniform in [0,1).
    fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }
    fn range(&mut self, lo: u64, hi: u64) -> u64 {
        if hi <= lo {
            return lo;
        }
        lo + self.next_u64() % (hi - lo)
    }
}

#[derive(Clone, Copy)]
struct Channel {
    loss: f64,       // per-cell drop probability
    dup: f64,        // per-cell duplication probability
    base_delay: u64, // one-way propagation (ms)
    jitter: u64,     // extra uniform [0,jitter] ms → reordering
    /// Per-packet keyed choice between two one-way delays. Overrides
    /// base_delay and deliberately reorders cells in both directions.
    two_path: Option<(u64, u64)>,
}
impl Channel {
    fn perfect() -> Self {
        Channel {
            loss: 0.0,
            dup: 0.0,
            base_delay: 25,
            jitter: 0,
            two_path: None,
        }
    }
    fn lossy(loss: f64) -> Self {
        Channel {
            loss,
            dup: 0.0,
            base_delay: 25,
            jitter: 0,
            two_path: None,
        }
    }
}

/// A cell in flight toward one endpoint.
struct InFlight {
    arrive: u64,
    bytes: Vec<u8>,
}

/// One directional pipe: applies loss/dup/jitter and times delivery.
struct Pipe {
    ch: Channel,
    flight: Vec<InFlight>,
    /// Total cells the sender handed in (incl. ones later dropped) — the wire
    /// send count, for measuring retransmit overhead.
    injected: u64,
    seed: u64,
    attempts: std::collections::HashMap<Vec<u8>, u64>,
}
impl Pipe {
    fn new(ch: Channel, seed: u64) -> Self {
        Pipe {
            ch,
            flight: Vec::new(),
            injected: 0,
            seed,
            attempts: std::collections::HashMap::new(),
        }
    }
    fn inject(&mut self, now: u64, bytes: &[u8], rng: &mut Rng) {
        self.inject_with_drop(now, bytes, rng, false);
    }

    fn inject_with_drop(&mut self, now: u64, bytes: &[u8], _rng: &mut Rng, force_drop: bool) {
        self.injected += 1;
        // Stable per-frame/per-attempt impairment: a new ACK elsewhere must
        // not move the loss/jitter draws for the same original or repair.
        let attempt = self.attempts.entry(bytes.to_vec()).or_default();
        let mut key = self.seed ^ attempt.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        *attempt += 1;
        for &byte in bytes {
            key = (key ^ u64::from(byte)).wrapping_mul(0x100_0000_01B3);
        }
        let mut stable = Rng::new(key);
        let rng = &mut stable;
        if force_drop {
            return;
        }
        // Drop?
        if rng.unit() < self.ch.loss {
            return;
        }
        let deliver = |p: &mut Pipe, r: &mut Rng| {
            let base = match p.ch.two_path {
                // Stable keyed choice across the two simulated routes.
                Some((fast, slow)) => {
                    if r.next_u64().is_multiple_of(2) {
                        fast
                    } else {
                        slow
                    }
                }
                None => p.ch.base_delay,
            };
            let arrive = now + base + r.range(0, p.ch.jitter + 1);
            p.flight.push(InFlight {
                arrive,
                bytes: bytes.to_vec(),
            });
        };
        deliver(self, rng);
        if rng.unit() < self.ch.dup {
            deliver(self, rng); // duplicate copy
        }
    }
    /// Earliest pending arrival.
    fn next_arrival(&self) -> Option<u64> {
        self.flight.iter().map(|f| f.arrive).min()
    }
    /// Remove + return all cells due by `now`, in arrival order.
    fn drain_due(&mut self, now: u64) -> Vec<Vec<u8>> {
        let mut due: Vec<(u64, Vec<u8>)> = Vec::new();
        let mut keep: Vec<InFlight> = Vec::new();
        for f in self.flight.drain(..) {
            if f.arrive <= now {
                due.push((f.arrive, f.bytes));
            } else {
                keep.push(f);
            }
        }
        self.flight = keep;
        due.sort_by_key(|(a, _)| *a);
        due.into_iter().map(|(_, b)| b).collect()
    }
}

struct Outcome {
    received: Vec<u8>,
    max_cwnd_a: u32,
    max_inflight_a: u32,
    final_a: String,
    final_b: String,
    a_events: Vec<Event>,
    b_events: Vec<Event>,
    steps: u64,
    elapsed_ms: u64,
    payload_received_ms: Option<u64>,
    completed: bool,
    /// Cells A (the sender) put on the wire, incl. retransmits.
    tx_cells: u64,
    /// Largest number of cells A emitted at a single virtual-time instant — the
    /// burst size pacing is meant to keep small.
    max_burst_a: u64,
}

/// Drive a one-way transfer of `payload` from A→B over `ch` (both directions use
/// `ch`; the reverse carries ACKs). Returns what B received.
fn run_oneway(payload: &[u8], ch: Channel, seed: u64, cfg: Config) -> Outcome {
    let mut rng = Rng::new(seed);
    let mut a = StreamEngine::connect(1, cfg, 0, 1000);
    let mut b = StreamEngine::accept(1, cfg, 0, 7000);
    a.write(payload);
    a.finish();

    let mut a2b = Pipe::new(ch, seed ^ 1);
    let mut b2a = Pipe::new(ch, seed ^ 2);
    let mut received: Vec<u8> = Vec::new();
    let mut a_events = Vec::new();
    let mut b_events = Vec::new();
    let mut max_cwnd_a = 0u32;
    let mut max_inflight_a = 0u32;

    let mut now = 0u64;
    let mut steps = 0u64;
    let cap = 20_000_000u64;
    let mut completed = false;
    let mut max_burst_a = 0u64; // most cells A put on the wire at one instant
    let mut payload_received_ms = None;

    while steps < cap {
        steps += 1;
        // 1. Drain both engines' transmits at `now`.
        let mut buf = Vec::new();
        let before = a2b.injected;
        while a.poll_transmit(now, &mut buf) {
            a2b.inject(now, &buf, &mut rng);
        }
        max_burst_a = max_burst_a.max(a2b.injected - before);
        while b.poll_transmit(now, &mut buf) {
            b2a.inject(now, &buf, &mut rng);
        }
        max_cwnd_a = max_cwnd_a.max(a.cwnd());
        max_inflight_a = max_inflight_a.max(a.inflight_bytes());

        // 2. Pump reader on B + drain events.
        let mut tmp = [0u8; 4096];
        loop {
            let n = b.read(&mut tmp);
            if n == 0 {
                break;
            }
            received.extend_from_slice(&tmp[..n]);
            if received.len() == payload.len() && payload_received_ms.is_none() {
                payload_received_ms = Some(now);
            }
        }
        while let Some(e) = a.poll_event() {
            a_events.push(e);
        }
        while let Some(e) = b.poll_event() {
            b_events.push(e);
        }

        // 3. Done?
        if received.len() == payload.len() && b.is_eof() && a.is_send_complete() {
            completed = true;
            break;
        }
        // Abort early if either side reset.
        if a.is_closed() && a_events.iter().any(|e| matches!(e, Event::Reset(_))) {
            break;
        }
        if b.is_closed() && b_events.iter().any(|e| matches!(e, Event::Reset(_))) {
            break;
        }

        // 4. Advance the virtual clock to the next event.
        let mut next: Option<u64> = None;
        let mut merge = |x: Option<u64>| {
            if let Some(v) = x {
                next = Some(next.map_or(v, |c: u64| c.min(v)));
            }
        };
        merge(a2b.next_arrival());
        merge(b2a.next_arrival());
        merge(a.next_timeout());
        merge(b.next_timeout());
        let Some(t) = next else {
            break; // nothing scheduled — stuck
        };
        now = now.max(t);

        // 5. Deliver arrivals due by `now`.
        for cell in a2b.drain_due(now) {
            b.on_cell(&cell, now);
        }
        for cell in b2a.drain_due(now) {
            a.on_cell(&cell, now);
        }
        // 6. Fire timers.
        a.on_timeout(now);
        b.on_timeout(now);
    }

    Outcome {
        received,
        max_cwnd_a,
        max_inflight_a,
        final_a: a.debug_summary(),
        final_b: b.debug_summary(),
        a_events,
        b_events,
        steps,
        elapsed_ms: now,
        payload_received_ms,
        completed,
        tx_cells: a2b.injected,
        max_burst_a,
    }
}

fn payload(n: usize, seed: u64) -> Vec<u8> {
    let mut r = Rng::new(seed);
    (0..n).map(|_| (r.next_u64() & 0xff) as u8).collect()
}

fn main() {
    for bbr in [false, true] {
        for profile in 0..10 {
            for seed in [9, 42, 91] {
                let mut ch = Channel::perfect();
                match profile {
                    0 => {}
                    1 => ch.jitter = 20,
                    2 => ch.jitter = 80,
                    3 => ch.jitter = 200,
                    4 => ch.two_path = Some((25, 125)),
                    5 => ch.two_path = Some((25, 250)),
                    6 => ch.two_path = Some((100, 500)),
                    7 => ch.loss = 0.01,
                    8 => {
                        ch.loss = 0.05;
                        ch.jitter = 80;
                    }
                    9 => ch.loss = 0.20,
                    _ => unreachable!(),
                }
                let cfg = Config {
                    mss: 1982,
                    init_cwnd: 64 * 1982,
                    recv_window: 8 << 20,
                    max_pacing_batch: 256,
                    ack_every: 16,
                    ack_delay_ms: 5,
                    init_rto_ms: 2000,
                    min_rto_ms: 1000,
                    max_rto_ms: 10_000,
                    max_retransmits: 5,
                    loss_decrease_per_mille: 750,
                    rto_rewind_no_sack: true,
                    bbr,
                    rack: true,
                    handshake_rto_ms: 3000,
                    ..Config::default()
                };
                let data = payload(1024 * 1024 + 251, seed);
                let out = run_oneway(&data, ch, seed, cfg);
                let rtos = out
                    .a_events
                    .iter()
                    .filter(|e| matches!(e, Event::DataRto { .. }))
                    .count();
                println!(
                    "{profile},{bbr},{seed},{},{},{},{},{rtos},{}",
                    out.completed,
                    out.received == data,
                    out.elapsed_ms,
                    out.payload_received_ms.unwrap_or(0),
                    out.tx_cells
                );
            }
        }
    }
}
