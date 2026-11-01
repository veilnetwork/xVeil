"""Exercise the oracle against independent corruptions of a private capture."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile

spec = importlib.util.spec_from_file_location("oracle", Path(__file__).with_name("verify_core_topology.py"))
oracle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oracle)
source = Path(sys.argv[1])
tag = json.loads((source / "last-probe-private.json").read_text())["tag"]
files = ["deployment-manifest-private.json", "last-probe-private.json", "linux-artifact-private.json", "client-attachments-private.json"]
files += [f"server-{i}-{kind}-private.json" for i in range(1, 7) for kind in ("preflight", f"probe-{tag}")]
with tempfile.TemporaryDirectory(prefix="xvl-oracle-", dir="/private/tmp/") as folder:
    root = Path(folder)
    for name in files:
        shutil.copy2(source / name, root / name)
    assert oracle.verify(root, True)["clientsChecked"] == 2
    name = f"server-3-probe-{tag}-private.json"
    original = json.loads((root / name).read_text())

    def reject(mutator):
        data = copy.deepcopy(original)
        mutator(data["result"])
        (root / name).write_text(json.dumps(data))
        try:
            oracle.verify(root, True)
        except (AssertionError, KeyError, ValueError):
            return
        raise AssertionError("oracle accepted a corrupted capture")

    def clear_rows(d):
        msg = json.loads(d["sessions"]["stdout"])["message"]
        header = msg.replace("\\n", "\n").splitlines()[0]
        d["sessions"]["stdout"] = json.dumps({"message": header})

    reject(clear_rows)
    reject(lambda d: d.__setitem__("loadedConfigSha256", "wrong"))
    reject(lambda d: d.__setitem__("binarySha256", "wrong"))
    reject(lambda d: d["production"].__setitem__("MainPID", "0"))
    reject(lambda d: d["service"].__setitem__("ActiveState", "failed"))
    (root / name).write_text(json.dumps(original))
    attachments = json.loads((root / "client-attachments-private.json").read_text())
    attachments["phone"]["rows"] = []
    (root / "client-attachments-private.json").write_text(json.dumps(attachments))
    try:
        oracle.verify(root, True)
    except AssertionError:
        pass
    else:
        raise AssertionError("empty client snapshot accepted")
print("Positive capture and six negative controls passed")
