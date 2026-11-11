"""Run on Linux: python3 -m unittest discover -s scripts -p test_veil_connect_agent.py."""
import base64
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import veil_connect_agent as agent
from build_veil_connect import build


class ProtocolTest(unittest.TestCase):
    def setUp(self):
        self.clock = [100.0]
        self.runtime = agent.Runtime(now=lambda: self.clock[0], ttl=60)
        self.client = secrets.token_urlsafe(32)
        self.claim = self.runtime.claim(self.runtime.bootstrap, {"client": self.client})
        self.token = self.claim["session"]
        self.addCleanup(self.runtime.stop)

    def reject(self, code, callback):
        with self.assertRaises(agent.Rejected) as raised:
            callback()
        self.assertEqual(raised.exception.code, code)

    def test_claim_retry_and_exclusive_owner(self):
        self.assertEqual(self.claim, self.runtime.claim(self.runtime.bootstrap, {"client": self.client}))
        self.assertNotEqual(self.token, self.runtime.bootstrap)
        self.reject("already_claimed", lambda: self.runtime.claim(self.runtime.bootstrap, {"client": secrets.token_urlsafe(32)}))
        self.reject("unauthorized", lambda: self.runtime.claim(self.token, {"client": self.client}))
        for token in (None, "é" * 43, "", self.runtime.bootstrap):
            self.reject("unauthorized", lambda: self.runtime.authorize(token))

    def test_expiry_and_accepted_result_grace(self):
        job = agent.Job(self.runtime, "a" * 32, "true", 10000)
        self.runtime.jobs[job.id] = job
        self.clock[0] = 160
        self.reject("expired", lambda: self.runtime.authorize(self.token))
        self.reject("expired", lambda: self.runtime.claim(self.runtime.bootstrap, {"client": self.client}))
        self.reject("expired", lambda: self.runtime.submit(self.token, {"id": "b" * 32, "script": "true", "timeout_ms": 1000}))
        self.reject("expired", lambda: self.runtime.lookup(self.token, job.id))
        job.finished = 159
        job.done.set()
        self.assertIs(self.runtime.lookup(self.token, job.id), job)
        self.assertFalse(self.runtime.may_exit())
        self.clock[0] = 189
        self.reject("expired", lambda: self.runtime.lookup(self.token, job.id))
        self.assertTrue(self.runtime.may_exit())

    def test_validation_and_duplicate_json_fields(self):
        valid = {"id": "b" * 32, "script": "true", "timeout_ms": 1000}
        for key, value, code in (
            ("id", "../bad", "invalid_job_id"), ("script", "\0", "invalid_script"),
            ("script", "é" * agent.MAX_SCRIPT, "invalid_script"),
            ("timeout_ms", True, "invalid_timeout"),
            ("timeout_ms", agent.MAX_JOB_MS + 1, "invalid_timeout"),
        ):
            self.reject(code, lambda: self.runtime.submit(self.token, {**valid, key: value}))
        self.reject("invalid_fields", lambda: self.runtime.submit(self.token, {**valid, "extra": 1}))
        self.reject("duplicate_field", lambda: json.loads('{"id":1,"id":2}', object_pairs_hook=agent._unique_object))
        self.reject("invalid_token", lambda: agent._token("a" * 43))

    def test_bootstrap_embeds_exact_source_without_secondary_download(self):
        source = Path(agent.__file__).read_text()
        script = build(source)
        self.assertEqual(script.count(source), 1)
        self.assertNotIn("curl", script)
        self.assertNotIn("wget", script)
        subprocess.run(["bash", "-n"], input=script.encode(), check=True)


@unittest.skipUnless(sys.platform == "linux", "process-group execution requires Linux")
class ProcessTest(unittest.TestCase):
    def setUp(self):
        self.runtime = agent.Runtime()
        self.token = self.runtime.claim(self.runtime.bootstrap, {"client": secrets.token_urlsafe(32)})["session"]
        self.addCleanup(self.runtime.stop)

    def submit(self, script, timeout=5000, job_id=None):
        return self.runtime.submit(self.token, {"id": job_id or secrets.token_hex(16), "script": script, "timeout_ms": timeout})

    def finish(self, job):
        self.assertTrue(job.done.wait(10), "accepted operation never completed")
        return job.snapshot()

    def test_binary_output_and_exit(self):
        result = self.finish(self.submit("printf '\\377\\000ok'; printf err >&2; exit 7"))
        self.assertEqual(base64.b64decode(result["stdout_b64"]), b"\xff\0ok")
        self.assertEqual(base64.b64decode(result["stderr_b64"]), b"err")
        self.assertEqual(result["exit_code"], 7)
        self.assertFalse(result["truncated"])

    def test_concurrent_idempotency_conflict_and_receipt_retention(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "count")
            script = "printf x >> '%s'" % path
            job_id = secrets.token_hex(16)
            with concurrent.futures.ThreadPoolExecutor(8) as pool:
                jobs = list(pool.map(lambda _: self.submit(script, job_id=job_id), range(20)))
            self.assertTrue(all(job is jobs[0] for job in jobs))
            self.finish(jobs[0])
            self.assertEqual(Path(path).read_bytes(), b"x")
            with self.assertRaises(agent.Rejected) as raised:
                self.submit("false", job_id=job_id)
            self.assertEqual(raised.exception.code, "job_conflict")
            self.assertIs(self.submit(script, job_id=job_id), jobs[0])

    def test_busy_and_output_caps(self):
        with patch.object(agent, "MAX_STREAM", 1024), patch.object(agent, "MAX_SESSION_OUTPUT", 1536):
            first = self.finish(self.submit("head -c 2048 /dev/zero; head -c 2048 /dev/zero >&2"))
            self.assertTrue(first["truncated"])
            self.assertLessEqual(len(base64.b64decode(first["stdout_b64"])), 1024)
            self.assertLessEqual(len(base64.b64decode(first["stderr_b64"])), 1024)
            self.assertEqual(self.runtime.output_bytes, 1536)
            second = self.finish(self.submit("echo not-retained"))
            self.assertEqual(second["stdout_b64"], "")
            self.assertTrue(second["truncated"])
        with patch.object(agent, "MAX_JOBS", 2):
            with self.assertRaises(agent.Rejected) as raised:
                self.submit("true")
            self.assertEqual(raised.exception.code, "job_limit")

    def test_timeout_and_shutdown_kill_group(self):
        for shutdown in (False, True):
            with self.subTest(shutdown=shutdown), tempfile.TemporaryDirectory() as directory:
                pidfile = Path(directory) / "child"
                # A background child holds stdout; completion must kill the
                # group, not block indefinitely draining its inherited pipe.
                job = self.submit("sleep 100 & echo $! > '%s'; wait" % pidfile, timeout=500 if not shutdown else 5000)
                deadline = threading.Event()
                for _ in range(100):
                    if pidfile.exists():
                        break
                    deadline.wait(0.01)
                self.assertTrue(pidfile.exists())
                pid = int(pidfile.read_text())
                with self.assertRaises(agent.Rejected) as raised:
                    self.submit("true")
                self.assertEqual(raised.exception.code, "busy")
                if shutdown:
                    self.runtime.stop()
                result = self.finish(job)
                self.assertEqual(result["cancelled"], shutdown)
                self.assertEqual(result["timed_out"], not shutdown)
                # A container's PID 1 may not reap adopted zombies; neither a
                # missing process nor a zombie can run or retain open pipes.
                status = Path("/proc/%s/stat" % pid)
                self.assertTrue(not status.exists() or status.read_text().split()[2] == "Z")

    def test_successful_shell_background_child_does_not_hold_completion(self):
        result = self.finish(self.submit("sleep 100 & echo complete"))
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(base64.b64decode(result["stdout_b64"]), b"complete\n")


class HttpsTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        directory = Path(self.directory.name)
        self.cert, key = directory / "cert.pem", directory / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1", "-subj", "/CN=veil-connect", "-keyout", str(key), "-out", str(self.cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.cert, key)
        self.runtime = agent.Runtime()
        self.server = agent.Server(("127.0.0.1", 0), context, self.runtime)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(5)
        self.runtime.stop()
        self.assertFalse(self.thread.is_alive())

    def request(self, path, token, body=None):
        client = http.client.HTTPSConnection("127.0.0.1", self.server.server_port, context=ssl._create_unverified_context(), timeout=3)
        try:
            client.request("GET" if body is None else "POST", path, body=None if body is None else json.dumps(body), headers={"Authorization": "Bearer " + token})
            response = client.getresponse()
            return response.status, json.loads(response.read())
        finally:
            client.close()

    def test_unfinished_handshake_does_not_block_authenticated_client(self):
        silent = socket.create_connection(self.server.server_address)
        self.addCleanup(silent.close)
        status, body = self.request("/v1/claim", self.runtime.bootstrap, {"client": secrets.token_urlsafe(32)})
        self.assertEqual(status, 200)
        self.assertEqual(body["schema"], agent.PROTOCOL)
        self.assertEqual(self.request("/v1/info", body["session"])[0], 200)
        self.assertEqual(self.request("/v1/info", self.runtime.bootstrap)[0], 401)
        self.assertEqual(self.request("/v1/jobs", secrets.token_urlsafe(32), {"id": "a" * 32, "script": "touch /never", "timeout_ms": 100})[0], 401)
        self.assertEqual(self.runtime.jobs, {})


if __name__ == "__main__":
    unittest.main()
