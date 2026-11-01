"""Validate a private six-node capture; emit no addresses or node IDs.

python3 verify_core_topology.py /private/capture/root
The capture must include deployment manifest, original production state,
artifact SHA and the six probe files selected by last-probe-private.json.
This validates the core graph only, not client attachment or media transit.
"""
import json
import sys
from pathlib import Path


def verify(root, include_clients=False):
    manifest = json.loads((root / "deployment-manifest-private.json").read_text())
    tag = json.loads((root / "last-probe-private.json").read_text())["tag"]
    servers = manifest["servers"]
    assert set(servers) == {str(i) for i in range(1, 7)}, "six servers required"
    labels = {row["nodeId"]: int(i) for i, row in servers.items()}
    assert len(labels) == 6, "identities must be distinct"
    expected = {(i, j) for i in range(1, 7) for j in (i - 1, i + 1) if 1 <= j <= 6}
    arcs = set()
    clients = {}
    if include_clients:
        peers = json.loads((root / "client-attachments-private.json").read_text())
        for role, seed in [("mac", 1), ("phone", 6)]:
            record = peers[role]
            assert record["nodeId"] not in labels, "client collides with core"
            assert record["rows"], "empty client snapshot"
            assert all(row["state"] == 1 for row in record["rows"])
            assert {row["nodeId"] for row in record["rows"]} == {servers[str(seed)]["nodeId"]}
            clients[record["nodeId"]] = seed
        assert len(clients) == 2, "client identities must be distinct"
    client_arcs = set()
    artifact = json.loads((root / "linux-artifact-private.json").read_text())
    for i in range(1, 7):
        capture = json.loads((root / f"server-{i}-probe-{tag}-private.json").read_text())
        assert capture["exit"] == 0
        d = capture["result"]
        assert d["service"]["ActiveState"] == "active", f"S{i} inactive"
        assert d["health"]["exit"] == d["sessions"]["exit"] == 0
        assert d["binarySha256"] == artifact["binarySha256"]
        assert d["loadedConfigSha256"] == servers[str(i)]["configSha256"]
        before = json.loads((root / f"server-{i}-preflight-private.json").read_text())["state"]
        assert d["production"]["ActiveState"] == "active"
        assert d["production"]["MainPID"] == before["service"]["MainPID"]
        assert d["productionBinarySha256"] == before["binarySha256"]
        assert d["productionConfigSha256"] == before["configSha256"]
        assert d["memAvailableKb"] >= 49152
        # CLI jsonl preserves terminal table escapes inside its message.
        message = json.loads(d["sessions"]["stdout"])["message"]
        lines = message.replace("\\t", "\t").replace("\\n", "\n").splitlines()
        assert lines[0].split("\t") == ["link_id", "node_id", "source", "transport", "state", "loss_pct", "samples"]
        links = set()
        for line in lines[1:]:
            if not line:
                continue
            fields = line.split("\t")
            assert len(fields) == 7 and fields[4] == "active", f"S{i} invalid session row"
            assert fields[0] not in links, f"S{i} duplicate link"
            links.add(fields[0])
            if fields[1] in clients:
                assert clients[fields[1]] == i, f"S{i} wrong client attachment"
                client_arcs.add((i, fields[1]))
                continue
            assert fields[1] in labels, f"S{i} unexpected peer"
            edge = (i, labels[fields[1]])
            assert edge in expected, f"S{i} non-neighbor session"
            arcs.add(edge)
    assert arcs == expected, "missing directed core edge"
    if include_clients:
        assert client_arcs == {(seed, node) for node, seed in clients.items()}, "missing client attachment"
    return {"schema": "xveil-linear-core-topology/1", "servers": 6,
            "bidirectionalEdges": [[i, i + 1] for i in range(1, 6)],
            "directedEdges": len(arcs), "unexpectedActivePeers": 0,
            "productionPreserved": True,
            "clientsChecked": len(clients),
            "scope": "snapshot graph only; media transit is not qualified"}


if __name__ == "__main__":
    print(json.dumps(verify(Path(sys.argv[1]), "--clients" in sys.argv[2:]), indent=2))
