"""Run the existing blind FIFO outside the codec driver's Python runtime.

Only setup, rate changes and snapshots cross a private inherited pipe. Media
bytes use the same TCP sockets and reservation algorithm as TcpShaper.
"""
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading

from tcp_fifo_shaper import TcpShaper


class ProcessTcpShaper:
    def __init__(self, targets, max_queue_ms=200, trace=False, scope='aggregate'):
        self._cached = None
        self._rate_bps = 0
        self._responses = queue.Queue()
        self.process = subprocess.Popen(
            [sys.executable, '-u', str(Path(__file__).resolve()), '--worker'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            # Native SDK stderr belongs to the parent; worker diagnostics are
            # returned as explicit failures over the control pipe instead.
            stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.reader = threading.Thread(target=self._read_responses,
                                       name='xveil-shaper-control', daemon=True)
        self.reader.start()
        try:
            started = self._request(dict(op='start', targets=targets,
                                         max_queue_ms=max_queue_ms,
                                         trace=trace, scope=scope))
            self.ports = started['ports']
            self.pid = started['pid']
            if self.pid != self.process.pid:
                raise RuntimeError('Shaper worker identity does not match the child')
        except BaseException:
            self._close_process()
            raise

    def _read_responses(self):
        try:
            for line in self.process.stdout:
                self._responses.put(json.loads(line))
        except Exception as error:
            self._responses.put({'ok': False, 'error': type(error).__name__})
        finally:
            self._responses.put({'ok': False, 'error': 'WorkerEOF'})

    def _request(self, request):
        self.process.stdin.write(json.dumps(request) + '\n')
        self.process.stdin.flush()
        try:
            response = self._responses.get(timeout=30)
        except queue.Empty as error:
            # Fail this fixture, never silently restart or accept old results.
            raise RuntimeError('Shaper control exceeded its 30-second deadline') from error
        if not response.get('ok'):
            kind = response.get('error', 'WorkerFailure')
            raise (ValueError if kind == 'ValueError' else RuntimeError)(kind)
        return response

    @property
    def rate_bps(self):
        return self._rate_bps

    @rate_bps.setter
    def rate_bps(self, value):
        self._request({'op': 'rate', 'value': value})
        self._rate_bps = value

    def _snapshot(self, trace=False):
        return self._cached if self._cached is not None else self._request(
            {'op': 'snapshot', 'trace': trace})

    @property
    def stats(self):
        return self._snapshot()['stats']

    @property
    def failure(self):
        return self._snapshot()['failure']

    @property
    def trace_rows(self):
        return self._snapshot(trace=True)['rows']

    @property
    def trace_events(self):
        return self._snapshot()['events']

    def _close_process(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        self.reader.join(timeout=5)
        self.process.stdout.close()
        if self.reader.is_alive():
            raise RuntimeError('Shaper response reader did not exit')

    def stop(self):
        if self._cached is not None:
            return
        try:
            stopped = self._request({'op': 'stop'})
            code = self.process.wait(timeout=5)
            if code != 0:
                raise RuntimeError('Shaper worker exited unsuccessfully')
            self._cached = stopped
        finally:
            self._close_process()


def _worker():
    import os
    shaper = None

    def snapshot(trace):
        return dict(stats=shaper.stats, failure=shaper.failure,
                    events=shaper.trace_events,
                    rows=list(shaper.trace_rows)
                    if trace and shaper.trace_rows is not None else None)

    try:
        for line in sys.stdin:
            request = json.loads(line)
            op = request['op']
            if op == 'start' and shaper is None:
                shaper = TcpShaper([tuple(v) for v in request['targets']],
                                   max_queue_ms=request['max_queue_ms'],
                                   trace=request['trace'], scope=request['scope'])
                response = dict(ports=shaper.ports, pid=os.getpid())
            elif op == 'rate' and shaper is not None:
                rate = request['value']
                if type(rate) is not int or rate < 0:
                    raise ValueError('Invalid shaping rate')
                shaper.rate_bps = rate
                response = {}
            elif op == 'snapshot' and shaper is not None:
                response = snapshot(request.get('trace', False))
            elif op == 'stop' and shaper is not None:
                shaper.stop()
                response = snapshot(True)
            else:
                raise ValueError('Invalid shaper command')
            print(json.dumps(dict(ok=True, **response)), flush=True)
            if op == 'stop':
                return
    except Exception as error:
        print(json.dumps(dict(ok=False, error=type(error).__name__)), flush=True)
        raise SystemExit(1)
    finally:
        if shaper is not None:
            shaper.stop()


if __name__ == '__main__':
    if sys.argv[1:] != ['--worker']:
        raise SystemExit('Private codec-fixture worker; no standalone options')
    _worker()
