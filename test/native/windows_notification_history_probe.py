"""Native portable-Windows toast regression, without launching the app.

Run with Python on Windows: --dll <plugin DLL> --result <new JSON file>.
Posts silent synthetic notifications in a fresh QA namespace. Does not activate
windows or touch xVeil's registration. A supervisor cleans history, scheduled
notifications and QA registration even if the FFI child fails or times out.
Not an oracle for banner visibility, clicking actions, or COM cold activation.
"""

import argparse
import base64
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

NO_WINDOW = 0x08000000
TAG = 2018919233


def history(aumid, clear=False):
    # Independent Windows observer: the plugin's portable getActiveNotifications
    # returns an empty list regardless of the actual Action Center history.
    script = (
        "[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new();"
        "$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';"
        "$m=[Windows.UI.Notifications.ToastNotificationManager,"
        "Windows.UI.Notifications,ContentType=WindowsRuntime];"
        "$h=$m::History;$n=$m::CreateToastNotifier('" + aumid + "');"
    )
    if clear:
        script += (
            "foreach($t in @($n.GetScheduledToastNotifications()))"
            "{$n.RemoveFromSchedule($t)};$h.Clear('" + aumid + "');"
        )
    script += (
        "$v=@($h.GetHistory('" + aumid + "'));"
        "$q=@($n.GetScheduledToastNotifications());"
        "@{shown=$v.Count;scheduled=$q.Count;"
        "matching=@($v|Where-Object {$_.Tag -eq '" + str(TAG) + "'}).Count;"
        "matchingScheduled=@($q|Where-Object {$_.Tag -eq '" + str(TAG)
        + "'}).Count}|ConvertTo-Json -Compress"
    )
    value = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-EncodedCommand",
         base64.b64encode(script.encode("utf-16le")).decode()],
        capture_output=True, creationflags=NO_WINDOW, timeout=10,
    )
    if value.returncode:
        raise RuntimeError("Windows history observer failed")
    return json.loads(value.stdout.decode("utf-8-sig"))


def remove_registration(aumid, guid):
    import winreg

    def remove(path):
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path, 0,
                                winreg.KEY_ALL_ACCESS) as key:
                children = []
                while True:
                    try:
                        children.append(winreg.EnumKey(key, len(children)))
                    except OSError:
                        break
            for child in children:
                remove(path + "\\" + child)
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, path)
        except FileNotFoundError:
            pass

    # All names derive from the fresh supervisor-generated UUID, never from
    # production configuration or command-line user input.
    for prefix, suffix in [
        (r"Software\Classes\AppUserModelId", aumid),
        (r"Software\Microsoft\Windows\CurrentVersion\PushNotifications\Backup", aumid),
        (r"Software\Microsoft\Windows\CurrentVersion\Notifications\Settings", aumid),
        (r"Software\Classes\CLSID", "{" + guid + "}"),
    ]:
        remove(prefix + "\\" + suffix)


def worker(config, output):
    class Pair(C.Structure):
        _fields_ = [("key", C.c_char_p), ("value", C.c_char_p)]

    class Map(C.Structure):
        _fields_ = [("entries", C.POINTER(Pair)), ("size", C.c_int)]

    class Launch(C.Structure):
        _fields_ = [("launched", C.c_bool), ("kind", C.c_int),
                    ("payload", C.c_char_p), ("data", Map)]

    callback_type = C.CFUNCTYPE(None, Launch)
    C.windll.kernel32.SetErrorMode(0x8003)
    plugin = None
    com_ready = False
    result = {"passed": False}
    try:
        hr = C.windll.ole32.CoInitializeEx(None, 0)
        assert hr in (0, 1), "COM initialization failed"
        com_ready = True
        dll = C.CDLL(config["dll"])
        dll.createPlugin.restype = C.c_void_p
        dll.hasPackageIdentity.restype = C.c_bool
        dll.init.argtypes = [C.c_void_p, C.c_char_p, C.c_char_p, C.c_char_p,
                             C.c_char_p, callback_type]
        dll.init.restype = C.c_bool
        dll.showNotification.argtypes = [C.c_void_p, C.c_int, C.c_char_p, Map]
        dll.showNotification.restype = C.c_bool
        dll.scheduleNotification.argtypes = [C.c_void_p, C.c_int, C.c_char_p, C.c_int]
        dll.scheduleNotification.restype = C.c_bool
        dll.updateNotification.argtypes = [C.c_void_p, C.c_int, Map]
        dll.updateNotification.restype = C.c_int
        dll.cancelNotification.argtypes = [C.c_void_p, C.c_int]
        dll.cancelAll.argtypes = [C.c_void_p]
        dll.disposePlugin.argtypes = [C.c_void_p]
        assert not dll.hasPackageIdentity(), "Run in an unpackaged Python process"
        callback = callback_type(lambda _: None)
        plugin = dll.createPlugin()
        assert plugin
        assert dll.init(plugin, b"xVeil notification QA", config["aumid"].encode(),
                        config["guid"].encode(), None, callback)
        assert history(config["aumid"])["shown"] == 0
        xml = (
            b'<toast><visual><binding template="ToastGeneric">'
            b'<text>xVeil notification QA</text><text>Cleanup check</text>'
            b'</binding></visual><audio silent="true"/></toast>'
        )
        for tag in [TAG, TAG + 1]:
            assert dll.showNotification(plugin, tag, xml, Map(None, 0))
        result["beforeCancel"] = history(config["aumid"])
        assert result["beforeCancel"]["shown"] == 2
        result["updateResult"] = dll.updateNotification(plugin, TAG, Map(None, 0))
        dll.cancelNotification(plugin, TAG)
        result["afterCancel"] = history(config["aumid"])
        # Record the scheduled checks even when cancellation is broken.
        for tag in [TAG, TAG + 1]:
            assert dll.scheduleNotification(plugin, tag, xml, int(time.time()) + 3600)
        assert history(config["aumid"])["scheduled"] == 2
        dll.cancelNotification(plugin, TAG)
        result["afterScheduleCancel"] = history(config["aumid"])
        assert result["afterScheduleCancel"]["scheduled"] == 1
        assert result["afterScheduleCancel"]["matchingScheduled"] == 0
        assert result["updateResult"] == 0
        assert result["afterCancel"]["shown"] == 1
        assert result["afterCancel"]["matching"] == 0
        dll.cancelAll(plugin)
        result["afterClear"] = history(config["aumid"])
        assert result["afterClear"]["shown"] == 0
        assert result["afterClear"]["scheduled"] == 0
        result["passed"] = True
    except BaseException as error:
        result["failureType"] = type(error).__name__
    finally:
        if plugin:
            dll.disposePlugin(plugin)
        if com_ready:
            C.windll.ole32.CoUninitialize()
        output.write_text(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path)
    parser.add_argument("--result", type=Path, required=True)
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("This native test requires Windows")
    if args.worker:
        return worker(json.loads(args.worker.read_text()), args.result)
    if not args.dll or not args.dll.is_file() or args.result.exists():
        parser.error("Provide an existing DLL and a new result path")
    namespace = "call-qa-" + uuid.uuid4().hex[:12]
    aumid = "VeilNetwork.xVeil." + namespace
    guid = str(uuid.uuid5(uuid.NAMESPACE_URL,
                         "urn:veilnetwork:xveil:notifications:" + namespace))
    digest = hashlib.sha256(args.dll.read_bytes()).hexdigest()
    result = {"passed": False, "pluginSha256": digest}
    try:
        with tempfile.TemporaryDirectory(prefix="xveil-toast-qa-") as work:
            config = Path(work) / "config.json"
            output = Path(work) / "result.json"
            config.write_text(json.dumps(dict(dll=str(args.dll.resolve()),
                                              aumid=aumid, guid=guid)))
            child = subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), "--worker",
                 str(config), "--result", str(output)],
                capture_output=True, creationflags=NO_WINDOW, timeout=60,
            )
            result["childExit"] = child.returncode
            if output.is_file():
                result["native"] = json.loads(output.read_text())
            result["passed"] = child.returncode == 0
    except BaseException as error:
        result["failureType"] = type(error).__name__
    finally:
        try:
            result["afterCleanup"] = history(aumid, clear=True)
            assert result["afterCleanup"]["shown"] == 0
            assert result["afterCleanup"]["scheduled"] == 0
            remove_registration(aumid, guid)
            result["registrationRemoved"] = True
        except BaseException as error:
            result["passed"] = False
            result["cleanupFailureType"] = type(error).__name__
        result["pluginUnchanged"] = hashlib.sha256(args.dll.read_bytes()).hexdigest() == digest
        result["passed"] &= result["pluginUnchanged"]
        args.result.write_text(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
