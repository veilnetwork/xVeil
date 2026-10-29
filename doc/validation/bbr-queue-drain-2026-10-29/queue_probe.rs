use std::collections::VecDeque;
use veil_onion_stream::{Config, Event, StreamEngine};

struct Pipe {
    rate: u64,
    tail_us: u64,
    flight: VecDeque<(u64, Vec<u8>)>,
    max_queue_us: u64,
    steady_max_queue_us: u64,
    steady_sum_queue_us: u64,
    steady_cells: u64,
    cells: u64,
}
impl Pipe {
    fn new(rate: u64) -> Self {
        Self {
            rate,
            tail_us: 0,
            flight: VecDeque::new(),
            max_queue_us: 0,
            steady_max_queue_us: 0,
            steady_sum_queue_us: 0,
            steady_cells: 0,
            cells: 0,
        }
    }
    fn send(&mut self, now: u64, bytes: &[u8], steady: bool) {
        let now_us = now * 1000;
        let queued = self.tail_us.saturating_sub(now_us);
        self.max_queue_us = self.max_queue_us.max(queued);
        if steady {
            self.steady_max_queue_us = self.steady_max_queue_us.max(queued);
            self.steady_sum_queue_us += queued;
            self.steady_cells += 1;
        }
        // All frames pay the same fixed circuit-cell wire size, no role priority.
        self.tail_us = self.tail_us.max(now_us) + (2048u64 * 1_000_000).div_ceil(self.rate);
        let arrival_ms = (self.tail_us + 25_000).div_ceil(1000);
        self.flight.push_back((arrival_ms, bytes.to_vec()));
        self.cells += 1;
    }
    fn deliver(&mut self, now: u64, to: &mut StreamEngine) {
        while self.flight.front().is_some_and(|(at, _)| *at <= now) {
            to.on_cell(&self.flight.pop_front().unwrap().1, now);
        }
    }
    fn next(&self) -> Option<u64> {
        self.flight.front().map(|(at, _)| *at)
    }
}

fn run(rate: u64, warm: bool, bytes: usize) {
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
        bbr: true,
        rack: true,
        warm_btl_bw: if warm { rate / 2 } else { 0 },
        warm_rtt_min_ms: if warm { 200 } else { 0 },
        ..Config::default()
    };
    let mut a = StreamEngine::connect(7, cfg, 0, 100);
    let mut b = StreamEngine::accept(7, cfg, 0, 500);
    let payload: Vec<u8> = (0..bytes).map(|i| (i ^ (i >> 8)) as u8).collect();
    a.write(&payload);
    a.finish();
    let mut ab = Pipe::new(rate);
    let mut ba = Pipe::new(rate);
    let mut received = Vec::new();
    let mut scratch = [0; 65536];
    let mut frame = Vec::new();
    let mut now = 0;
    let mut rtos = 0;
    let mut max_flight = 0;
    let mut finished = false;
    let mut max_piece_gap = 0;
    let mut last_piece_at = 0;
    let mut next_piece = 262144;
    let mut steps = 0;
    while now < 900_000 && steps < 2_000_000 {
        steps += 1;
        ab.deliver(now, &mut b);
        ba.deliver(now, &mut a);
        loop {
            let n = b.read(&mut scratch);
            if n == 0 {
                break;
            }
            received.extend_from_slice(&scratch[..n]);
        }
        if received.len() >= next_piece {
            if last_piece_at != 0 {
                max_piece_gap = max_piece_gap.max(now - last_piece_at);
            }
            last_piece_at = now;
            next_piece += 262144;
        }
        if received.len() == payload.len() && !finished {
            b.finish();
            finished = true;
        }
        a.on_timeout(now);
        b.on_timeout(now);
        let steady = received.len() >= 1024 * 1024;
        for _ in 0..512 {
            if !a.poll_transmit(now, &mut frame) {
                break;
            }
            ab.send(now, &frame, steady);
        }
        for _ in 0..512 {
            if !b.poll_transmit(now, &mut frame) {
                break;
            }
            ba.send(now, &frame, steady);
        }
        max_flight = max_flight.max(a.inflight_bytes());
        while let Some(e) = a.poll_event() {
            if matches!(e, Event::DataRto { .. }) {
                rtos += 1;
            }
        }
        if a.is_send_complete() && b.is_send_complete() && a.is_eof() && b.is_eof() {
            break;
        }
        if a.is_closed() || b.is_closed() {
            break;
        }
        let next = [ab.next(), ba.next(), a.next_timeout(), b.next_timeout()]
            .into_iter()
            .flatten()
            .min();
        let Some(next) = next else {
            break;
        };
        now = next.max(now + 1);
    }
    println!(
        "rate={rate} warm={warm} virtual_ms={now} bytes_ok={} complete={} max_queue_ms={} steady_max_queue_ms={} steady_avg_queue_ms={} max_flight={max_flight} rtos={rtos} max_piece_gap_ms={max_piece_gap} cells={} steps={steps}",
        received == payload,
        a.is_send_complete() && b.is_send_complete(),
        ab.max_queue_us / 1000,
        ab.steady_max_queue_us / 1000,
        ab.steady_sum_queue_us / ab.steady_cells.max(1) / 1000,
        ab.cells
    );
    println!("final {}", a.debug_summary());
}
fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    let long = match args.as_slice() {
        [] => false,
        [arg] if arg == "--long" => true,
        _ => {
            eprintln!("usage: queue_probe [--long]");
            std::process::exit(2);
        }
    };
    let bytes = if long {
        16 * 1024 * 1024 + 251
    } else {
        3 * 1024 * 1024 + 251
    };
    let rates: &[u64] = if long {
        &[32 * 1024]
    } else {
        &[32 * 1024, 128 * 1024, 1024 * 1024]
    };
    for &rate in rates {
        for warm in [false, true] {
            run(rate, warm, bytes);
        }
    }
}
