"""Blind FIFO shaper for loopback UDP. Never parses encrypted packet bytes."""
import collections
import selectors
import socket
import threading
import time

class UdpShaper:
    def __init__(self, target, max_queue_ms=200):
        self.targets = target if isinstance(target, list) else [target]
        self.max_queue_ms = max_queue_ms
        self.selector = selectors.DefaultSelector()
        self.fronts = []
        for destination in self.targets:
            front = socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            front.bind(('127.0.0.1',0))
            front.setblocking(False)
            self.fronts.append(front)
            self.selector.register(front,selectors.EVENT_READ,('front',destination))
        self.ports = [front.getsockname()[1] for front in self.fronts]
        self.back = {}
        self.queues = [collections.deque(), collections.deque()]
        self.next_at = [0., 0.]
        self.stats = [{'received':0, 'sent':0, 'drops':0, 'max_queue_ms':0.} for _ in range(2)]
        self.rate_bps = 0
        self.stopped = threading.Event()
        self.failure = None
        self.worker = threading.Thread(target=self.run_guarded, name='xveil-neutral-udp-shaper')
        self.worker.start()

    def enqueue(self, direction, sock, address, data):
        now = time.monotonic()
        stat = self.stats[direction]
        stat['received'] += 1
        backlog_ms = max(0., (self.next_at[direction] - now) * 1000)
        if self.rate_bps and backlog_ms >= self.max_queue_ms:
            stat['drops'] += 1
            return
        ready = max(now, self.next_at[direction])
        if self.rate_bps:
            ready += len(data) * 8 / self.rate_bps
        self.next_at[direction] = ready
        stat['max_queue_ms'] = max(stat['max_queue_ms'], (ready-now)*1000)
        self.queues[direction].append((ready, sock, address, data))

    def run_guarded(self):
        try:
            self.run()
        except Exception as error:
            self.failure = type(error).__name__

    def run(self):
        while not self.stopped.is_set():
            now = time.monotonic()
            deadline = min((queue[0][0] for queue in self.queues if queue), default=now+.02)
            for key, _ in self.selector.select(max(0., min(.02, deadline-now))):
                for _ in range(64):
                    try:
                        data, address = key.fileobj.recvfrom(65536)
                    except BlockingIOError:
                        break
                    if key.data[0] == 'front':
                        cache_key = (key.fileobj.fileno(),address)
                        backend = self.back.get(cache_key)
                        if backend is None:
                            backend = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                            backend.bind(('127.0.0.1',0))
                            backend.setblocking(False)
                            self.back[cache_key] = backend
                            self.selector.register(backend, selectors.EVENT_READ, ('back',key.fileobj,address))
                        self.enqueue(0, backend, key.data[1], data)
                    else:
                        self.enqueue(1, key.data[1], key.data[2], data)
            now = time.monotonic()
            for direction, queue in enumerate(self.queues):
                while queue and queue[0][0] <= now:
                    _, sock, address, data = queue.popleft()
                    try:
                        sock.sendto(data, address)
                        self.stats[direction]['sent'] += 1
                    except BlockingIOError:
                        self.stats[direction]['drops'] += 1

    def stop(self):
        self.stopped.set()
        self.worker.join(2)
        if self.worker.is_alive():
            raise RuntimeError('UDP shaper did not stop')
        self.selector.close()
        for sock in [*self.fronts, *self.back.values()]:
            sock.close()

