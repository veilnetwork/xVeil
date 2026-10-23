// Historical source-copy regression for the RACK delivery-accounting issue.
// On parent SDK 6875a88a the assertion fails: reordering gap 90 instead of 0.
// The corrected regression is now maintained in engine.rs's regular test module:
// cargo test -p veil-onion-stream --lib rack_delivery_counted_once
// Keep this original fixture as evidence of the previously open finding.
#[test]
fn pending_rack_delivery_counted_once() {
    let mut e = repeated_sack_holes(true);
    e.cfg.rack = true;
    for s in &mut e.tx.segs {
        s.sacked = false;
        s.retransmitted = false;
        s.local_pending = true;
        s.handed_off = false;
        s.sent_ms = 0;
    }
    // Accept the original head and next original in distinct real local
    // handoffs. Other reserved cells have not left yet.
    for (index, at) in [(0, 1), (1, 10)] {
        let token = LocalTransmit::for_segment(&e.tx.segs[index]);
        e.local_handoff(&HashMap::from([(token, 1)]), at);
    }
    let mut cell = Vec::new();
    let mut sacks = SackVec::new();
    assert!(sacks.push(SackRange { start: 117, end: 133 }));
    Frame::Ack { stream_id: 9, ack: 101, win: 4096, sacks }.encode_into(&mut cell);
    e.on_cell(&cell, 20);
    assert_eq!(e.tx.rack_reo_max_ms, 0);
    // The head repair leaves later; another original is accepted afterwards.
    assert!(e.poll_transmit(90, &mut cell));
    assert!(matches!(Frame::decode(&cell), Some(Frame::Data { seq: 101, .. })));
    let head_repair = LocalTransmit::from_cell(&cell).unwrap();
    e.local_handoff(&HashMap::from([(head_repair, 1)]), 90);
    let later_original = LocalTransmit::for_segment(&e.tx.segs[3]);
    e.local_handoff(&HashMap::from([(later_original, 1)]), 100);
    let mut sacks = SackVec::new();
    assert!(sacks.push(SackRange { start: 149, end: 165 }));
    Frame::Ack { stream_id: 9, ack: 101, win: 4096, sacks }.encode_into(&mut cell);
    e.on_cell(&cell, 110);
    assert_eq!(e.tx.rack_reo_max_ms, 0);
    // This cumulative ACK adds only the repaired head. The original at 10ms
    // was already reported at 20ms; it has not just arrived late at 120ms.
    Frame::Ack { stream_id: 9, ack: 133, win: 4096, sacks: SackVec::new() }.encode_into(&mut cell);
    e.on_cell(&cell, 120);
    assert_eq!(e.tx.rack_reo_max_ms, 0,
        "previously SACKed original was counted again as a newly late delivery");
}
