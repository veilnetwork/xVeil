#!/usr/bin/env python3
"""Separate SDK/network delivery from native drain in a same-process codec stand.

Only bounded RTP metadata is read. Sequence/timestamp pairs match send attempts
to ingress; no payload, key, address or identity is emitted. The explicit clock
flag is required: device clocks cannot establish absolute one-way latency.
Unmatched capped trace rows are NOT evidence of packet loss.
"""
import argparse
import collections
import json
import re
from pathlib import Path


def distribution(values):
    if not values:
        return None
    values = sorted(values)
    return {
        "count": len(values),
        "min_ms": round(values[0], 3),
        "p50_ms": round(values[len(values) // 2], 3),
        "p95_ms": round(values[min(len(values) - 1, int(len(values) * .95))], 3),
        "p99_ms": round(values[min(len(values) - 1, int(len(values) * .99))], 3),
        "max_ms": round(values[-1], 3),
    }


def analyze(log, summary, duration_seconds=None):
    blocks = {"send": [], "ingress": []}
    for line in log.splitlines():
        match = re.match(r"audio\.rtp\.(send|ingress)\.begin count=(\d+)$", line)
        if match:
            blocks[match[1]].append({"expected": int(match[2]), "rows": []})
            continue
        match = re.match(r"audio\.rtp\.(send|ingress) (.+)$", line)
        if match:
            kind = match[1]
            if not blocks[kind]:
                raise ValueError("trace row without its bounded block header")
            row = {k: int(v) for k, v in re.findall(r"(\w+)=(-?\d+)", match[2])}
            blocks[kind][-1]["rows"].append(row)
    for group in blocks.values():
        for block in group:
            if len(block["rows"]) != block["expected"]:
                raise ValueError("incomplete diagnostic block")
    if not blocks["send"] or not blocks["ingress"]:
        raise ValueError("send and ingress traces are both required")
    sends = collections.defaultdict(list)
    for block, records in enumerate(blocks["send"]):
        for row in records["rows"]:
            if row["accepted"]:
                sends[(row["sequence"] if "sequence" in row else row["seq"],
                       row["timestamp"])].append((block, row))
    start = summary["stand_start_monotonic_us"]
    recorded_duration = summary.get("duration_seconds")
    if duration_seconds is not None and recorded_duration is not None and duration_seconds != recorded_duration:
        raise ValueError("supplied duration differs from the recorded stand duration")
    if duration_seconds is None:
        duration_seconds = recorded_duration
    if duration_seconds is None or duration_seconds <= 20:
        raise ValueError("stand duration must be recorded or supplied with --duration-seconds")
    phases = [("audio-only", 5, 20), ("competing-local-sources", 20,
                                        duration_seconds)]
    result = {"same_host_clock": True, "capped_trace_rows_are_not_loss": True,
              "video_requested": summary["video_requested"],
              "duration_seconds": duration_seconds,
              "independent_control_ipc": summary.get("independent_control_ipc"),
              "feedback_interval_seconds": summary.get("feedback_interval_seconds"),
              "send_trace_counts": [len(b["rows"]) for b in blocks["send"]],
              "directions": []}
    for receiver, records in enumerate(blocks["ingress"]):
        matched = []
        ambiguous = unmatched = 0
        for row in records["rows"]:
            if not row["payload_bytes"]:
                continue
            candidates = sends.get((row["seq"], row["timestamp"]), [])
            if not candidates:
                unmatched += 1
                continue
            if len(candidates) != 1:
                ambiguous += 1
                continue
            sender, send = candidates[0]
            flight = row["arrived_us"] - send["attempted_us"]
            admission = send["admitted_us"] - send["attempted_us"]
            drain = row["drained_us"] - row["arrived_us"]
            if min(flight, admission, drain) < 0:
                raise ValueError("negative stage duration: check clock domain and trace matching")
            t = (send["attempted_us"] - start) / 1_000_000
            if not -5 <= t <= duration_seconds + 5:
                raise ValueError("native and stand clocks do not share an origin")
            matched.append((t, sender, flight / 1000, admission / 1000, drain / 1000))
        result["directions"].append({
            "receiver_block": receiver,
            "receive_trace_count": len(records["rows"]),
            "sender_blocks": sorted({row[1] for row in matched}),
            "matched_nonempty_packets": len(matched),
            "first_matched_send_seconds": round(min(r[0] for r in matched), 3) if matched else None,
            "last_matched_send_seconds": round(max(r[0] for r in matched), 3) if matched else None,
            "unmatched_trace_rows": unmatched, "ambiguous_trace_rows": ambiguous,
            "largest_flights": [
                {"send_at_seconds": round(row[0], 3),
                 "sdk_and_network_ms": round(row[2], 3),
                 "sdk_admission_ms": round(row[3], 3),
                 "native_drain_ms": round(row[4], 3)}
                for row in sorted(matched, key=lambda row: row[2], reverse=True)[:5]
            ],
            "phases": [{"name": name,
                        "sdk_and_network": distribution([r[2] for r in matched if lo <= r[0] < hi]),
                        "sdk_admission": distribution([r[3] for r in matched if lo <= r[0] < hi]),
                        "native_drain": distribution([r[4] for r in matched if lo <= r[0] < hi]),
                        "largest_flights": [
                            {"send_at_seconds": round(r[0], 3),
                             "sdk_and_network_ms": round(r[2], 3)}
                            for r in sorted((r for r in matched if lo <= r[0] < hi),
                                            key=lambda r: r[2], reverse=True)[:5]]}
                       for name, lo, hi in phases],
        })
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-log", type=Path, required=True)
    parser.add_argument("--stand", type=Path, required=True)
    parser.add_argument("--same-host-clock", action="store_true", required=True)
    parser.add_argument("--duration-seconds", type=float,
                        help="duration for older summaries that do not record it")
    args = parser.parse_args()
    summary = json.loads((args.stand / "summary.json").read_text())
    result = analyze(args.native_log.read_text(), summary, args.duration_seconds)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
