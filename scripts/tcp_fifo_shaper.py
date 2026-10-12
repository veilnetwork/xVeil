"""Aggregate byte-rate limiter for loopback TCP; never parses stream contents.

All connections share one FIFO reservation clock per direction. TCP retains
bytes under pressure; bounded reads and socket buffers propagate backpressure.
No application roles, addresses, or payloads are retained in optional traces.
"""
import asyncio
import collections
import socket
import threading
import time


class TcpShaper:
    def __init__(self, targets, max_queue_ms=200, trace=False):
        self.targets = targets
        self.max_queue_ms = max_queue_ms
        self.rate_bps = 0
        self.trace_rows = collections.deque(maxlen=100000) if trace else None
        self.trace_events = 0
        self.stats = [dict(received=0, sent=0, drops=0, received_bytes=0,
                           sent_bytes=0, max_queue_ms=0.) for _ in range(2)]
        self.failure = None
        self.ports = []
        self._ready = threading.Event()
        self.worker = threading.Thread(target=self._run_guarded,
                                       name='xveil-neutral-tcp-shaper')
        self.worker.start()
        if not self._ready.wait(5):
            self.stop()
            raise RuntimeError('TCP shaper did not start')
        if self.failure:
            self.worker.join(5)
            raise RuntimeError('TCP shaper startup failed: ' + self.failure)

    def _run_guarded(self):
        try:
            asyncio.run(self._run())
        except Exception as error:
            self.failure = type(error).__name__
        finally:
            self._ready.set()

    async def _run(self):
        self._loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        self._locks = [asyncio.Lock(), asyncio.Lock()]
        self._next_at = [0., 0.]
        self._pending = [0, 0]
        self._connection_sequence = 0
        self._handlers = set()
        servers = []
        try:
            for link, target in enumerate(self.targets):
                def accepted(reader, writer, target=target, link=link):
                    task = asyncio.create_task(self._connection(reader, writer, target, link))
                    self._handlers.add(task)
                    task.add_done_callback(self._handlers.discard)
                server = await asyncio.start_server(accepted, '127.0.0.1', 0,
                                                    limit=4096)
                servers.append(server)
                self.ports.append(server.sockets[0].getsockname()[1])
            self._ready.set()
            await self._stop.wait()
        finally:
            for server in servers:
                server.close()
            # Recent asyncio versions wait for accepted clients in wait_closed.
            # Cancel their pumps first, including accept callbacks already queued.
            await asyncio.sleep(0)
            tasks = list(self._handlers)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await asyncio.gather(*(s.wait_closed() for s in servers))

    @staticmethod
    def _bound_writer(writer):
        writer.transport.set_write_buffer_limits(high=4096, low=1024)
        sock = writer.get_extra_info('socket')
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8192)

    async def _connection(self, reader, writer, target, link):
        # Local trace handle only; no address, payload or application role.
        self._connection_sequence += 1
        connection = self._connection_sequence
        other = None
        pumps = []
        try:
            upstream, other = await asyncio.wait_for(
                asyncio.open_connection(*target, limit=4096), 5)
            self._bound_writer(writer)
            self._bound_writer(other)
            pumps = [asyncio.create_task(self._pump(reader, other, 0, link, connection)),
                     asyncio.create_task(self._pump(upstream, writer, 1, link, connection))]
            await asyncio.gather(*pumps)
        except (ConnectionError, OSError, asyncio.TimeoutError):
            # A fixture node may not yet be listening or may be shutting down.
            # Its ordinary connection retry handles this; bytes are not replayed.
            pass
        except Exception as error:
            self.failure = type(error).__name__
        finally:
            for task in pumps:
                task.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)
            for endpoint in (writer, other):
                if endpoint is not None:
                    endpoint.close()
                    try:
                        await asyncio.wait_for(endpoint.wait_closed(), 1)
                    except (ConnectionError, OSError):
                        pass
                    except asyncio.TimeoutError:
                        endpoint.transport.abort()

    async def _pump(self, reader, writer, direction, link, connection):
        while data := await reader.read(1280):
            read_at = time.monotonic() if self.trace_rows is not None else None
            # asyncio exposes no public unread-byte count. This is opt-in
            # fixture instrumentation, never an admission/scheduling input.
            reader_buffer_bytes = (len(reader._buffer)
                                   if self.trace_rows is not None else None)
            stat = self.stats[direction]
            stat['received'] += 1
            stat['received_bytes'] += len(data)
            async with self._locks[direction]:
                now = time.monotonic()
                rate = self.rate_bps
                if rate:
                    # Waiting here keeps reservation order and bounds admitted
                    # backlog. Each waiting connection retains one small read.
                    wait = self._next_at[direction] - now - self.max_queue_ms / 1000
                    if wait > 0:
                        await asyncio.sleep(wait)
                    now = time.monotonic()
                    ready = max(now, self._next_at[direction]) + len(data) * 8 / rate
                else:
                    ready = now
                self._next_at[direction] = ready
                queue_ms = max(0., (ready - now) * 1000)
                stat['max_queue_ms'] = max(stat['max_queue_ms'], queue_ms)
                row = None
                if self.trace_rows is not None and rate:
                    row = dict(at=now, direction=direction, link=link,
                               connection=connection, read_at=read_at,
                               reader_buffer_bytes=reader_buffer_bytes,
                               bytes=len(data), pending=self._pending[direction],
                               ready=ready, queue_ms=queue_ms)
                    self.trace_rows.append(row)
                    self.trace_events += 1
                self._pending[direction] += 1
            try:
                await asyncio.sleep(max(0., ready - time.monotonic()))
                writer.write(data)
                if row is not None:
                    row.update(write_at=time.monotonic(),
                               writer_buffer_bytes=writer.transport.get_write_buffer_size())
                await writer.drain()
                stat['sent'] += 1
                stat['sent_bytes'] += len(data)
                if row is not None:
                    sent_at = time.monotonic()
                    row.update(sent_at=sent_at,
                               release_lateness_ms=(sent_at - ready) * 1000)
            finally:
                self._pending[direction] -= 1
        if writer.can_write_eof():
            writer.write_eof()
            await writer.drain()

    def stop(self):
        if hasattr(self, '_loop') and self.worker.is_alive():
            self._loop.call_soon_threadsafe(self._stop.set)
        self.worker.join(5)
        if self.worker.is_alive():
            raise RuntimeError('TCP shaper did not stop')
