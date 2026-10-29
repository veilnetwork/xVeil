use std::collections::VecDeque;

enum Side {
    Old(old::StreamEngine),
    New(new::StreamEngine),
}
macro_rules! call {
    ($e:expr, $m:ident $(, $arg:expr)*) => { match $e { Side::Old(e) => e.$m($($arg),*), Side::New(e) => e.$m($($arg),*) } };
}
macro_rules! config {
    ($kr:ident, $rack:expr) => {
        $kr::Config {
            mss: 64,
            init_cwnd: 128,
            recv_window: 128,
            ack_every: 1,
            bbr: true,
            rack: $rack,
            init_rto_ms: 2000,
            min_rto_ms: 1000,
            max_rto_ms: 10_000,
            ..$kr::Config::default()
        }
    };
}
fn side(updated: bool, initiator: bool, rack: bool) -> Side {
    let iss = if initiator { u32::MAX - 10 } else { 500 };
    match (updated, initiator) {
        (false, true) => Side::Old(old::StreamEngine::connect(7, config!(old, rack), 0, iss)),
        (false, false) => Side::Old(old::StreamEngine::accept(7, config!(old, rack), 0, iss)),
        (true, true) => Side::New(new::StreamEngine::connect(7, config!(new, rack), 0, iss)),
        (true, false) => Side::New(new::StreamEngine::accept(7, config!(new, rack), 0, iss)),
    }
}
struct Pipe {
    queue: VecDeque<(u64, Vec<u8>)>,
    last_zero: bool,
    drop_reopen: bool,
    dropped: u32,
    cells: u64,
}
impl Pipe {
    fn new(drop_reopen: bool) -> Self {
        Self {
            queue: VecDeque::new(),
            last_zero: false,
            drop_reopen,
            dropped: 0,
            cells: 0,
        }
    }
    fn enqueue(&mut self, bytes: &[u8], now: u64) {
        self.cells += 1;
        if let Some(new::Frame::Ack { win, .. }) = new::Frame::decode(bytes) {
            let reopening = self.last_zero && win > 0;
            self.last_zero = win == 0;
            if reopening && self.drop_reopen {
                self.drop_reopen = false;
                self.dropped += 1;
                return;
            }
        }
        self.queue.push_back((now + 3, bytes.to_vec()));
    }
    fn deliver(&mut self, side: &mut Side, now: u64) {
        while self.queue.front().is_some_and(|(at, _)| *at <= now) {
            let (_, bytes) = self.queue.pop_front().unwrap();
            call!(side, on_cell, &bytes, now);
        }
    }
}
fn run(a_new: bool, b_new: bool, rack: bool, drop_reopen: bool) {
    let mut a = side(a_new, true, rack);
    let mut b = side(b_new, false, rack);
    let pa: Vec<u8> = (0..4096).map(|i| (i ^ (i >> 8)) as u8).collect();
    let pb: Vec<u8> = pa.iter().map(|v| !v).collect();
    call!(&mut a, write, &pa);
    call!(&mut b, write, &pb);
    call!(&mut a, finish);
    call!(&mut b, finish);
    let mut ab = Pipe::new(drop_reopen);
    let mut ba = Pipe::new(drop_reopen);
    let mut received_a = Vec::new();
    let mut received_b = Vec::new();
    let mut cell = Vec::new();
    let mut buf = [0; 64];
    let mut completed = None;
    for now in 0..120_000 {
        if std::env::var_os("TRACE").is_some() && (now % 1000 == 0) { eprintln!("t={now} A {} B {}",call!(&a,debug_summary),call!(&b,debug_summary)); }
        ab.deliver(&mut b, now);
        ba.deliver(&mut a, now);
        // Both apps initially stop reading: a genuine full receive buffer in
        // each direction. Later, read at different cadences with no hint to CC.
        if now >= 25 {
            if now % 3 == 0 {
                let n = call!(&mut a, read, &mut buf);
                received_a.extend_from_slice(&buf[..n]);
            }
            if now % 5 == 0 {
                let n = call!(&mut b, read, &mut buf);
                received_b.extend_from_slice(&buf[..n]);
            }
        }
        call!(&mut a, on_timeout, now);
        call!(&mut b, on_timeout, now);
        for _ in 0..64 {
            if !call!(&mut a, poll_transmit, now, &mut cell) {
                break;
            }
            if std::env::var_os("TRACE").is_some() {
                match new::Frame::decode(&cell).unwrap() {
                    new::Frame::Data { seq, win, payload, .. } => eprintln!("t={now} A DATA seq={seq} n={} win={win}",payload.len()),
                    new::Frame::Ack { ack, win, .. } => eprintln!("t={now} A ACK ack={ack} win={win}"),
                    f => eprintln!("t={now} A {f:?}"),
                }
            }
            ab.enqueue(&cell, now);
        }
        for _ in 0..64 {
            if !call!(&mut b, poll_transmit, now, &mut cell) {
                break;
            }
            if std::env::var_os("TRACE").is_some() {
                match new::Frame::decode(&cell).unwrap() {
                    new::Frame::Data { seq, win, payload, .. } => eprintln!("t={now} B DATA seq={seq} n={} win={win}",payload.len()),
                    new::Frame::Ack { ack, win, .. } => eprintln!("t={now} B ACK ack={ack} win={win}"),
                    f => eprintln!("t={now} B {f:?}"),
                }
            }
            ba.enqueue(&cell, now);
        }
        if call!(&a, is_send_complete)
            && call!(&b, is_send_complete)
            && call!(&a, is_eof)
            && call!(&b, is_eof)
        {
            completed = Some(now);
            break;
        }
        assert!(
            !call!(&a, is_closed) && !call!(&b, is_closed),
            "stream reset"
        );
    }
    assert_eq!(received_a, pb);
    assert_eq!(received_b, pa);
    let virtual_ms = completed.expect("did not complete with EOF in both directions");
    if drop_reopen {
        assert!(ab.dropped + ba.dropped > 0, "loss branch was not exercised");
    }
    println!(
        "a_new={a_new} b_new={b_new} rack={rack} drop_reopen={drop_reopen} virtual_ms={virtual_ms} intact_bytes_each_way=4096 eof_both=true dropped_window_updates={} wire_cells={}",
        ab.dropped + ba.dropped,
        ab.cells + ba.cells
    );
}
fn main() {
    if std::env::var_os("TRACE").is_some() { run(true, false, true, true); return; }
    for a in [false, true] {
        for b in [false, true] {
            for rack in [false, true] {
                for loss in [false, true] {
                    run(a, b, rack, loss);
                }
            }
        }
    }
}
