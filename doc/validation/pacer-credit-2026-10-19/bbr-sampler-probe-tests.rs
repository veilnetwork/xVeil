
#[cfg(test)]
mod bandwidth_estimation_probes {
    use super::*;
    fn delivered(e: &mut BandwidthEstimation, at: &mut Instant, n: u64, round: u64, limited: bool) {
        let sent = *at; e.on_sent(sent, n); *at += Duration::from_millis(10);
        e.on_ack(*at, sent, n, round, limited);
    }
    #[test]
    fn app_limited_delivery_can_establish_a_nonzero_lower_bound() {
        let mut e=BandwidthEstimation::default(); let mut at=Instant::now();
        delivered(&mut e,&mut at,1000,1,true); delivered(&mut e,&mut at,1000,2,true);
        assert_eq!(e.get_estimate(),100_000);
    }
    #[test]
    fn a_lower_backlogged_rate_expires_an_old_maximum() {
        let mut e=BandwidthEstimation::default(); let mut at=Instant::now();
        for round in 1..=2 { delivered(&mut e,&mut at,10_000,round,false); }
        assert_eq!(e.get_estimate(),1_000_000);
        for round in 3..=25 { delivered(&mut e,&mut at,1000,round,false); }
        assert_eq!(e.get_estimate(),100_000);
    }
    #[test]
    fn low_demand_cannot_claim_that_capacity_dropped() {
        let mut e=BandwidthEstimation::default(); let mut at=Instant::now();
        for round in 1..=2 { delivered(&mut e,&mut at,10_000,round,false); }
        for round in 3..=25 { delivered(&mut e,&mut at,1000,round,true); }
        assert_eq!(e.get_estimate(),1_000_000);
    }
    #[test]
    fn compressed_old_acks_cannot_use_an_unrelated_new_send_burst() {
        let mut e=BandwidthEstimation::default(); let start=Instant::now(); let mut at=start;
        for round in 1..=2 { delivered(&mut e,&mut at,1000,round,false); }
        e.on_sent(start+Duration::from_millis(20),1000);
        e.on_sent(start+Duration::from_millis(30),1000);
        e.on_sent(start+Duration::from_millis(40),1000);
        e.on_sent(start+Duration::from_millis(40)+Duration::from_micros(1),1000);
        e.on_ack(start+Duration::from_millis(100),start+Duration::from_millis(20),1000,3,false);
        e.on_ack(start+Duration::from_millis(100)+Duration::from_micros(1),start+Duration::from_millis(30),1000,3,false);
        assert!(e.get_estimate()<=100_000,"old confirmations must not fund the unrelated burst: {}",e.get_estimate());
    }
}
