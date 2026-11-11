#!/usr/bin/env python3
# xVeil node-connect helper v1
"""Temporary, QR-paired HTTPS transport for the app's node-management scripts.

The QR grants the authority of the account running this helper. It is a secret,
not a public node advertisement. Nothing here installs a permanent service or
changes the Veil binary. Python 3.8+ on Linux; standard library only.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import secrets
import selectors
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

PROTOCOL = "xveil-node-connect/1"
MAX_BODY = 1024 * 1024
MAX_SCRIPT = 128 * 1024
MAX_STREAM = 1024 * 1024
MAX_SESSION_OUTPUT = 8 * 1024 * 1024
MAX_JOBS = 64
MAX_JOB_MS = 6 * 60 * 1000
RESULT_GRACE = 30
SAFE_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
COMPONENTS = ("veil-cli", "ogate", "oproxy-client", "oproxy-server")
TOKEN = re.compile(r"[A-Za-z0-9_-]{43}\Z")
JOB_ID = re.compile(r"[a-f0-9]{32}\Z")


class Rejected(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code
        super().__init__(code)  # Never include request bodies, tokens or paths.


def _token(value):
    if not isinstance(value, str) or not TOKEN.fullmatch(value):
        raise Rejected(400, "invalid_token")
    raw = base64.urlsafe_b64decode(value + "=")
    if base64.urlsafe_b64encode(raw).decode().rstrip("=") != value:
        raise Rejected(400, "invalid_token")
    return value


def _exact_keys(value, expected):
    if type(value) is not dict or set(value) != set(expected):
        raise Rejected(400, "invalid_fields")


def _unique_object(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise Rejected(400, "duplicate_field")
        out[key] = value
    return out


class Job:
    """One accepted operation; a retry with the same id never runs it twice."""

    def __init__(self, runtime, job_id, script, timeout_ms):
        self.runtime, self.id = runtime, job_id
        self.fingerprint = hashlib.sha256(
            script.encode("utf-8") + b"\0" + str(timeout_ms).encode()
        ).digest()
        self.started = runtime.now()
        self.deadline = self.started + timeout_ms / 1000
        self.finished = None
        self.exit_code = None
        self.timed_out = False
        self.cancelled = False
        self.truncated = False
        self.stdout, self.stderr = bytearray(), bytearray()
        self.stop = threading.Event()
        self.done = threading.Event()
        self.script, self.timeout_ms = script, timeout_ms

    def snapshot(self):
        with self.runtime.lock:
            return {
                "id": self.id,
                "done": self.finished is not None,
                "exit_code": self.exit_code,
                "timed_out": self.timed_out,
                "cancelled": self.cancelled,
                "truncated": self.truncated,
                "stdout_b64": base64.b64encode(self.stdout).decode(),
                "stderr_b64": base64.b64encode(self.stderr).decode(),
            }

    def _append(self, block, destination):
        with self.runtime.lock:
            size = min(
                len(block), MAX_STREAM - len(destination),
                MAX_SESSION_OUTPUT - self.runtime.output_bytes,
            )
            destination.extend(block[:size])
            self.runtime.output_bytes += size
            self.truncated |= size != len(block)

    def _pump(self, poller, timeout=0.02):
        for key, _ in poller.select(timeout):
            try:
                block = os.read(key.fd, 16 * 1024)
            except BlockingIOError:
                continue
            if block:
                self._append(block, key.data)
            else:
                poller.unregister(key.fd)

    def run(self):
        process = None
        writer = None
        poller = selectors.DefaultSelector()
        code = 125
        script_bytes = self.script.encode("utf-8")
        try:
            process = subprocess.Popen(
                ["/bin/bash", "-s"], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True, bufsize=0,
                env={"PATH": SAFE_PATH, "LANG": "C.UTF-8"},
            )
            for pipe, destination in (
                (process.stdout, self.stdout), (process.stderr, self.stderr),
            ):
                os.set_blocking(pipe.fileno(), False)
                poller.register(pipe, selectors.EVENT_READ, destination)

            def write_input():
                try:
                    remaining = memoryview(script_bytes)
                    while remaining:
                        count = process.stdin.write(remaining)
                        if not count:
                            break
                        remaining = remaining[count:]
                except (BrokenPipeError, OSError):
                    pass
                finally:
                    try:
                        process.stdin.close()
                    except OSError:
                        pass
                    self.script = ""

            writer = threading.Thread(target=write_input, daemon=True)
            writer.start()
            # Keep the leader unreaped until its entire process group is shut
            # down. Its pid cannot be recycled into an unrelated host process
            # between observing exit and killpg (including background children).
            while True:
                info = os.waitid(
                    os.P_PID, process.pid,
                    os.WEXITED | os.WNOHANG | os.WNOWAIT,
                )
                if info is not None:
                    code = info.si_status if info.si_code == os.CLD_EXITED else -info.si_status
                    break
                if self.stop.is_set():
                    self.cancelled, code = True, 130
                    break
                if self.runtime.now() >= self.deadline:
                    self.timed_out, code = True, 124
                    break
                self._pump(poller)
        except Exception:
            # A spawn/host failure is an outcome, not an excuse to leave a
            # claimed job id reusable or echo secrets through an exception.
            code = 125
        finally:
            try:
                self._cleanup(process, writer, poller)
            except Exception:
                code = 125
            finally:
                poller.close()
                self.script = ""
                with self.runtime.lock:
                    self.exit_code = code
                    self.finished = self.runtime.now()
                self.done.set()

    def _cleanup(self, process, writer, poller):
        if process is None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            if sig == signal.SIGTERM:
                time.sleep(0.05)
        process.wait(timeout=2)
        try:
            drain_until = time.monotonic() + 0.5
            while poller.get_map() and time.monotonic() < drain_until:
                self._pump(poller)
            if poller.get_map():
                self.truncated = True
        finally:
            for pipe in (process.stdout, process.stderr):
                pipe.close()
            if writer is not None:
                writer.join(timeout=1)


class Runtime:
    def __init__(self, *, ttl=600, now=time.monotonic, inventory=None):
        self.now, self.expires = now, now() + ttl
        self.lock = threading.RLock()
        self.bootstrap = secrets.token_urlsafe(32)
        self.session = None
        self.client = None
        self.jobs = {}
        self.output_bytes = 0
        self.inventory = inventory or {}
        self.closing = False

    def _auth(self, supplied, expected):
        return (isinstance(supplied, str) and TOKEN.fullmatch(supplied) is not None
                and expected is not None and hmac.compare_digest(supplied, expected))

    def claim(self, token, body):
        _exact_keys(body, ("client",))
        client = _token(body["client"])
        with self.lock:
            if self.closing or self.now() >= self.expires:
                raise Rejected(410, "expired")
            if not self._auth(token, self.bootstrap):
                raise Rejected(401, "unauthorized")
            if self.client is not None and self.client != client:
                raise Rejected(409, "already_claimed")
            # An identical retry recovers the same answer after a lost reply.
            if self.session is None:
                self.client, self.session = client, secrets.token_urlsafe(32)
            return {"session": self.session, "remaining_seconds": max(0, int(self.expires - self.now()))}

    def authorize(self, token, *, job=None):
        with self.lock:
            if self.closing or not self._auth(token, self.session):
                raise Rejected(401, "unauthorized")
            limit = self.expires
            if job is not None:
                finished = job.finished if job.finished is not None else job.deadline
                limit = max(limit, finished + RESULT_GRACE)
            if self.now() >= limit:
                raise Rejected(410, "expired")

    def submit(self, token, body):
        _exact_keys(body, ("id", "script", "timeout_ms"))
        job_id, script, timeout = body["id"], body["script"], body["timeout_ms"]
        if not isinstance(job_id, str) or not JOB_ID.fullmatch(job_id):
            raise Rejected(400, "invalid_job_id")
        if not isinstance(script, str) or "\0" in script or not (0 < len(script.encode("utf-8")) <= MAX_SCRIPT):
            raise Rejected(400, "invalid_script")
        if type(timeout) is not int or not 0 < timeout <= MAX_JOB_MS:
            raise Rejected(400, "invalid_timeout")
        with self.lock:
            self.authorize(token)
            previous = self.jobs.get(job_id)
            candidate = Job(self, job_id, script, timeout)
            if previous is not None:
                if not hmac.compare_digest(previous.fingerprint, candidate.fingerprint):
                    raise Rejected(409, "job_conflict")
                return previous
            if any(job.finished is None for job in self.jobs.values()):
                raise Rejected(429, "busy")
            if len(self.jobs) >= MAX_JOBS:
                raise Rejected(429, "job_limit")
            # No receipt eviction in this lease: replaying an older id must
            # never execute it a second time after its output was discarded.
            self.jobs[job_id] = candidate
            threading.Thread(target=candidate.run, daemon=True).start()
            return candidate

    def lookup(self, token, job_id):
        with self.lock:
            # Authenticate even for an unknown id; do not turn lookup into an
            # unauthenticated receipt oracle.
            if not self._auth(token, self.session):
                raise Rejected(401, "unauthorized")
            job = self.jobs.get(job_id)
            self.authorize(token, job=job)
            if job is None:
                raise Rejected(404, "not_found")
            return job

    def stop(self):
        with self.lock:
            self.closing = True
            for job in self.jobs.values():
                job.stop.set()
            accepted = list(self.jobs.values())
        for job in accepted:
            job.done.wait(5)

    def may_exit(self):
        with self.lock:
            if self.now() < self.expires:
                return False
            return all(
                job.finished is not None and self.now() >= job.finished + RESULT_GRACE
                for job in self.jobs.values()
            )


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass  # In particular, no addresses, request targets or credentials.

    def _send(self, status, body):
        payload = json.dumps(body, ensure_ascii=True, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        self.wfile.write(payload)

    def _body(self):
        length = self.headers.get("Content-Length", "")
        if (len(self.headers.get_all("Content-Length", [])) != 1
                or self.headers.get("Transfer-Encoding") is not None
                or not re.fullmatch(r"[0-9]{1,7}", length)):
            raise Rejected(400, "invalid_length")
        length = int(length)
        if not 0 < length <= MAX_BODY:
            raise Rejected(413, "body_too_large")
        raw = self.rfile.read(length)
        if len(raw) != length:
            raise Rejected(400, "incomplete_body")
        try:
            return json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_object)
        except (UnicodeError, ValueError):
            raise Rejected(400, "invalid_json") from None

    def _dispatch(self):
        try:
            auth = self.headers.get("Authorization", "")
            if (len(self.headers.get_all("Authorization", [])) != 1
                    or not auth.startswith("Bearer ") or len(auth) != 50):
                raise Rejected(401, "unauthorized")
            token = _token(auth[7:])
            runtime = self.server.runtime
            if self.command == "POST" and self.path == "/v1/claim":
                result = runtime.claim(token, self._body())
            elif self.command == "GET" and self.path == "/v1/info":
                runtime.authorize(token)
                result = runtime.inventory
            elif self.command == "POST" and self.path == "/v1/jobs":
                runtime.authorize(token)
                result = runtime.submit(token, self._body()).snapshot()
            elif self.command == "GET" and re.fullmatch(r"/v1/jobs/[a-f0-9]{32}", self.path):
                result = runtime.lookup(token, self.path.rsplit("/", 1)[1]).snapshot()
            else:
                raise Rejected(404, "not_found")
            self._send(200, {"schema": PROTOCOL, **result})
        except Rejected as error:
            self._send(error.status, {"schema": PROTOCOL, "error": error.code})
        except (OSError, TimeoutError):
            self.close_connection = True
        except Exception:
            self._send(500, {"schema": PROTOCOL, "error": "internal"})

    do_GET = _dispatch
    do_POST = _dispatch


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, context, runtime):
        self.context, self.runtime = context, runtime
        self.slots = threading.BoundedSemaphore(8)
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, Handler)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            request.close()
            raise

    def process_request_thread(self, request, address):
        secure = None
        try:
            # TLS handshakes happen in bounded workers, never in accept(). One
            # silent TLS client must not block every other phone's request.
            request.settimeout(5)
            secure = self.context.wrap_socket(request, server_side=True)
            self.finish_request(secure, address)
        except Exception:
            pass
        finally:
            self.shutdown_request(secure or request)
            self.slots.release()

    def handle_error(self, *args):
        pass


def inventory(config):
    # Public inventory only: never embed a TOML file (which holds private keys)
    # in a QR or response. Full inventory runs through the app's existing
    # bounded, authenticated management-script path after pairing.
    return {
        "host_os": platform.system().lower(),
        "host_arch": platform.machine()[:32],
        "administrator": os.geteuid() == 0,
        "config_present": Path(config).is_file(),
        "components": [name for name in COMPONENTS if shutil.which(name, path=SAFE_PATH)],
    }


def make_invite(endpoint, fingerprint, bootstrap, expires):
    return "xveil:node?" + urllib.parse.urlencode({
        "v": "1", "endpoint": endpoint, "pin": fingerprint,
        "token": bootstrap, "expires": str(expires),
    })


def choose_host():
    try:
        result = subprocess.run(
            ["ip", "-j", "address", "show", "up"], capture_output=True,
            check=True, timeout=3, env={"PATH": SAFE_PATH},
        )
        addresses = []
        for interface in json.loads(result.stdout):
            for entry in interface.get("addr_info", []):
                value = ipaddress.ip_address(entry["local"])
                if value.is_global and not value.is_multicast:
                    addresses.append(value)
        return str(sorted(addresses, key=lambda a: (a.version, int(a)))[0])
    except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
        raise ValueError("specify --host with the server's reachable address") from None


def install_helper(source):
    """Install code only, never a service; refuse unrelated files or links."""
    target = Path("/usr/local/bin/veil-connect")
    parent = target.parent
    for directory in (Path("/usr"), Path("/usr/local"), parent):
        try:
            directory.mkdir(mode=0o755)
        except FileExistsError:
            pass
        else:
            directory.chmod(0o755)  # umask 077 protects secrets, not /usr/local.
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError("helper install directory is not private to root")
    previous = None
    if target.exists() or target.is_symlink():
        info = target.lstat()
        if (target.is_symlink() or not target.is_file() or info.st_uid != 0
                or info.st_mode & 0o022):
            raise ValueError("refusing to replace an unrelated helper")
        marker = b"#!/usr/bin/env python3\n# xVeil node-connect helper v1\n"
        with target.open("rb") as existing:
            recognized = existing.read(len(marker)) == marker
        if not recognized:
            raise ValueError("refusing to replace an unrelated helper")
        previous = (info.st_dev, info.st_ino)
    with tempfile.NamedTemporaryFile(dir=parent, prefix=".veil-connect-", delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(source)
            output.flush()
            os.fsync(output.fileno())
            temporary.chmod(0o755)
            if previous is None:
                os.link(temporary, target)  # O_EXCL-style publication.
            else:
                current = target.lstat()
                if (current.st_dev, current.st_ino) != previous:
                    raise ValueError("helper changed during installation")
                os.replace(temporary, target)
        finally:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", help="reachable IP or DNS name; otherwise read local interfaces")
    parser.add_argument("--listen-host", help="bind address (default: all interfaces)")
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--advertise-port", type=int)
    parser.add_argument("--ttl", type=int, default=600, help="pairing lifetime, 60..900 seconds")
    parser.add_argument("--invite-file", help="also write invite to a NEW owner-only file")
    parser.add_argument("--bootstrap", action="store_true", help="install the additional helper script")
    args = parser.parse_args(argv)
    if sys.platform != "linux" or not hasattr(os, "WNOWAIT"):
        parser.error("the server helper requires Linux")
    if not (0 <= args.port <= 65535 and 60 <= args.ttl <= 900):
        parser.error("invalid port or lifetime")
    if args.advertise_port is not None and not 1 <= args.advertise_port <= 65535:
        parser.error("invalid advertised port")
    os.umask(0o077)
    if args.bootstrap:
        if os.geteuid() != 0:
            parser.error("bootstrap must run as root")
        install_helper(Path(__file__).read_bytes())
    host = args.host or choose_host()
    try:
        host = str(ipaddress.ip_address(host))
        if "%" in host:
            raise ValueError()
    except ValueError:
        if (not host or len(host) > 253 or not all(
                re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", part)
                for part in host.split("."))):
            parser.error("--host must be a plain IP or DNS name")
    authority = "[" + host + "]" if ":" in host else host
    listen = args.listen_host or ("::" if ":" in host else "0.0.0.0")
    runtime = Runtime(ttl=args.ttl, inventory=inventory("/var/lib/veil/node.toml"))
    with tempfile.TemporaryDirectory(prefix="veil-connect-") as directory:
        cert, key = Path(directory) / "cert.pem", Path(directory) / "key.pem"
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
            "ec_paramgen_curve:prime256v1", "-sha256", "-nodes", "-days", "1",
            "-subj", "/CN=veil-connect", "-keyout", str(key), "-out", str(cert),
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(cert, key)
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
        server = Server((listen, args.port), context, runtime)
        port = args.advertise_port or server.server_address[1]
        invite = make_invite("https://" + authority + ":" + str(port), fingerprint,
                             runtime.bootstrap, int(time.time()) + args.ttl)
        saved = None
        old_signals = {}
        try:
            if args.invite_file:
                with open(args.invite_file, "xb") as output:
                    saved = os.fstat(output.fileno())
                    output.write(invite.encode())
                    output.flush()
                    os.fsync(output.fileno())
            print("Temporary node control. Scan in xVeil > My nodes > Connect QR.", flush=True)
            subprocess.run(["qrencode", "-t", "UTF8", "-m", "4"], input=invite.encode(), check=True)
            print("Manual entry: " + invite, flush=True)
            print("Keep this QR private. Ctrl+C closes access. Expires in %d seconds." % args.ttl, flush=True)
            stopped = threading.Event()
            for sig in (signal.SIGINT, signal.SIGTERM):
                old_signals[sig] = signal.signal(sig, lambda *_: stopped.set())
            server.timeout = 0.25
            while not stopped.is_set() and not runtime.may_exit():
                server.handle_request()
        finally:
            runtime.stop()
            server.server_close()
            for sig, previous in old_signals.items():
                signal.signal(sig, previous)
            if saved is not None:
                try:
                    current = os.lstat(args.invite_file)
                    if (current.st_dev, current.st_ino) == (saved.st_dev, saved.st_ino):
                        os.unlink(args.invite_file)
                except FileNotFoundError:
                    pass



if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError):
        raise SystemExit("veil-connect could not start; check dependencies, address and permissions") from None
