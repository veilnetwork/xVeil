import 'dart:async';
import 'dart:collection';

/// A bound on how much answering work an anonymous request path may have in
/// flight at once.
///
/// The paths this guards accept a request over an anonymous endpoint, and every
/// accepted one makes the host build a return circuit to answer. That is the
/// expensive half: the request is ~158 bytes and the answer is a full onion
/// round trip, measured at about eleven seconds and a rendezvous circuit each
/// way. Without a bound, one party holding a valid capability turns a stream of
/// tiny datagrams into as many circuits as it likes — the host does the work,
/// pays the bandwidth, and holds a pending answer per request in memory.
///
/// Note what the bound is NOT protecting against, because the audit that
/// prompted it said otherwise: a request does not force a large decrypt. Reads
/// are record-granular (`_kStoreRecord`, 3800 bytes), so a 256-byte chunk
/// request touches one record or two — not the covering piece, and not the
/// 32 MiB the report assumed. The amplification that is real is circuits, not
/// bytes off disk.
///
/// ADMIT ONLY WHAT IS AUTHORIZED. Callers must run their MAC check BEFORE
/// asking for a slot. A gate placed ahead of authorization is worse than none:
/// anyone who can reach the endpoint fills the queue with garbage and the
/// authorized requests are the ones refused.
class ServeAdmission {
  ServeAdmission({this.maxConcurrent = 8, this.maxWaiting = 32})
    : assert(maxConcurrent > 0),
      assert(maxWaiting >= 0);

  /// How many answers may be in flight together.
  ///
  /// Eight, from the client's own measurements rather than a guess: the fetch
  /// window is four because at eight the anonymous transport already started
  /// LOSING requests and finishing slower (see `_chunkWindow`). A cap at eight
  /// therefore sits above what the honest path can usefully consume — the
  /// transport binds before this does — while still bounding a flood.
  final int maxConcurrent;

  /// How many may wait for a slot before the rest are refused. Waiting is
  /// cheap; being unbounded is what turns a flood into memory growth.
  final int maxWaiting;

  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();
  int _running = 0;
  int _refused = 0;
  bool _closed = false;

  /// Answers in flight, counting a slot handed to a waiter.
  int get running => _running;

  /// Requests queued for a slot.
  int get waiting => _waiting.length;

  /// Requests turned away because the queue was full. Diagnostic only — a
  /// refusal is silent on the wire, since a refusal a stranger can observe is
  /// an oracle for "this host has this share".
  int get refused => _refused;

  /// Runs [body] once a slot is free, or returns null without running it.
  ///
  /// Null means refused, and the caller's answer is simply never sent. That is
  /// safe here because every client of these paths retries: the capability
  /// fetch allows five attempts per chunk and the member fetch two, each with
  /// a thirty-second window, and a slot frees in about the length of one
  /// answer.
  Future<T?> run<T>(Future<T> Function() body) async {
    if (_closed) return null;
    if (_running < maxConcurrent) {
      _running++;
    } else if (_waiting.length < maxWaiting) {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
      // Closed while we waited: the slot was handed over by `close`, not by a
      // finished answer, and there is nothing left to answer for.
      if (_closed) return null;
    } else {
      _refused++;
      return null;
    }
    try {
      return await body();
    } finally {
      _release();
    }
  }

  /// Hand the slot to the next waiter, or give it back.
  ///
  /// Transferred rather than released-and-reacquired: dropping `_running` and
  /// letting the waiter re-check would let a request arriving in that gap take
  /// the slot instead, and two of them could then be admitted for one release.
  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }

  /// Refuse everything from here on and wake everyone who is waiting.
  ///
  /// Without this a host that closes with requests queued leaves those futures
  /// pending forever, and whatever they captured with them.
  void close() {
    _closed = true;
    while (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    }
  }
}
