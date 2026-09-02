// Asking the people you already talk to whether they have a model.
//
// The point is to work with no internet at all. A person on a network where
// the publisher is unreachable can still get a translation or speech model
// from a contact, and the file that carries it is the ordinary .veiltranslate
// or .veilaudio this app already sends.
//
// Two things this must not become. It must not be a way to learn what
// languages someone reads without their say-so — hence a setting, and hence
// accepted contacts only. And it must not be a way to put entries in front of
// someone who never asked — hence answers are matched against a question this
// device actually sent, inside a window, with a cap.

// The lint wants `this._messaging` in the parameter list, which Dart forbids:
// a named parameter cannot start with an underscore. Every dependency here is
// injected so the service can be exercised without a node, a container or a
// clock, and that is worth more than the shorter constructor.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/model_inventory.dart';
import '../data/storage/storage.dart';
import '../core/ids.dart';
import 'messaging.dart';
import 'providers.dart';
import 'translation_model_controller.dart';
import 'whisper_model_controller.dart';

/// Answering is on unless the person turned it off.
///
/// Default-on because the whole feature is for the case where nothing else
/// works, and a network of contacts who all default to silence helps nobody.
/// Stored as the ABSENCE of a '0', so an existing profile needs no migration
/// and a storage read that comes back empty lands on the documented default
/// rather than on whatever false happens to mean today.
const String kAnswerModelInventoryKey = 'models.answer_inventory';

/// How long an answer stays welcome after the question.
///
/// Bounded because the alternative is a device that accepts an inventory list
/// from any accepted contact at any time — which is an unsolicited push with
/// extra steps.
const Duration kModelAnswerWindow = Duration(seconds: 90);

/// The most contacts whose answers are held at once, and the most rows kept
/// from any one of them. A list from a peer is attacker-shaped input; both
/// numbers are here so neither can be grown by the sender.
const int kMaxAnsweringPeers = 64;
const int kMaxRowsPerPeer = 32;

class PeerModelOffers {
  const PeerModelOffers(this.peer, this.offers);
  final NodeId peer;
  final List<ModelOffer> offers;
}

class ModelExchangeService {
  ModelExchangeService({
    required MessagingService messaging,
    required Storage storage,
    required Future<Directory?> Function() translateRoot,
    required Future<Directory?> Function() speechRoot,
    required DateTime Function() now,
  }) : _messaging = messaging,
       _storage = storage,
       _translateRoot = translateRoot,
       _speechRoot = speechRoot,
       _now = now {
    _messaging.onModelInventoryRequest = _answer;
    _messaging.onModelInventoryOffer = _collect;
  }

  final MessagingService _messaging;
  final Storage _storage;
  final Future<Directory?> Function() _translateRoot;
  final Future<Directory?> Function() _speechRoot;
  final DateTime Function() _now;

  /// When each peer was asked. An answer outside the window is dropped.
  final Map<String, DateTime> _asked = {};

  /// Set by [dispose]. Detaching the handlers stops the NEXT request; an
  /// answer already in flight is several awaits deep and needs telling.
  bool _disposed = false;

  final _answers = StreamController<PeerModelOffers>.broadcast();

  Stream<PeerModelOffers> get answers => _answers.stream;

  /// Whether this device answers "what models have you got".
  Future<bool> answersAutomatically() async =>
      await _storage.getSetting(kAnswerModelInventoryKey) != '0';

  Future<void> setAnswersAutomatically(bool enabled) =>
      _storage.putSetting(kAnswerModelInventoryKey, enabled ? '1' : '0');

  /// Ask [peers] what they have.
  Future<void> ask(Iterable<NodeId> peers) async {
    final at = _now();
    for (final peer in peers) {
      _asked[peer.hex] = at;
      await _messaging.sendModelInventoryRequest(peer);
    }
    _forgetExpired(at);
  }

  Future<void> _answer(NodeId peer) async {
    if (_disposed) return;
    if (!await answersAutomatically()) return;
    // AFTER the first await as well, and this one is not only about what is
    // sent. `_speechRoot` reaches back through the provider `Ref` that built
    // this service, and a `Ref` used after its provider was disposed THROWS —
    // so an answer parked on the preference read when the identity changed did
    // not merely leak, it raised out of a messaging callback with nobody to
    // catch it (report21 XV18-L3).
    if (_disposed) return;
    final offers = await localModelOffers(
      translateRoot: await _translateRoot(),
      speechRoot: await _speechRoot(),
    );
    // Silence when there is nothing, rather than an empty list. "I have none"
    // and "I do not answer this" then look the same from outside, which is the
    // only way the setting is worth having: a peer who can tell the two apart
    // learns that the person deliberately declined.
    if (offers.isEmpty) return;
    // CHECKED AGAIN, right before the send. Detaching the handler stops the
    // NEXT request; it does nothing about this one, which is several awaits
    // deep — a preference read and two directory scans — by the time it gets
    // here. Without this an answer begun under one identity was still sent
    // after the app had moved to another, telling that peer what the identity
    // the user had left keeps on disk (report21 XV18-L3).
    if (_disposed) return;
    await _messaging.sendModelInventoryOffer(
      peer,
      jsonEncode([for (final offer in offers) offer.toWire()]),
    );
  }

  void _collect(NodeId peer, String bodyJson) {
    if (_disposed) return;
    final at = _now();
    _forgetExpired(at);
    final askedAt = _asked[peer.hex];
    // Unsolicited, or too late to be an answer to anything.
    if (askedAt == null || at.difference(askedAt) > kModelAnswerWindow) return;

    final Object? wire;
    try {
      wire = jsonDecode(bodyJson);
    } on FormatException {
      return;
    }
    final offers = offersFromWire(
      wire,
      // A peer's files are not on this device, and a path from a peer would be
      // a claim about our own filesystem. Never used as one.
      placeholder: Directory.systemTemp,
    );
    if (offers.isEmpty) return;
    _answers.add(
      PeerModelOffers(
        peer,
        offers.length > kMaxRowsPerPeer
            ? offers.sublist(0, kMaxRowsPerPeer)
            : offers,
      ),
    );
  }

  void _forgetExpired(DateTime at) {
    _asked.removeWhere((_, when) => at.difference(when) > kModelAnswerWindow);
    if (_asked.length <= kMaxAnsweringPeers) return;
    // Oldest first: the questions least likely still to be answered.
    final ordered = _asked.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    for (final entry in ordered.take(_asked.length - kMaxAnsweringPeers)) {
      _asked.remove(entry.key);
    }
  }

  /// How many questions are still remembered. For the bound test: what must
  /// stay bounded is what this device REMEMBERS, not what it sent, so a peer
  /// that never answers cannot grow it.
  int get debugPendingQuestions => _asked.length;

  /// Take the callbacks back off, but only the ones that are still ours.
  ///
  /// Compared with `==`, not `identical`. A tear-off of an instance method is
  /// EQUAL to another tear-off of the same method on the same object, and Dart
  /// promises nothing about the two being the same object — so the identity
  /// check here was false every time, and this method left both callbacks
  /// installed on a pipeline that had moved on. Nothing noticed while the
  /// service was built once per session; once it is built per identity, a
  /// stale handler is A still answering on A's pipeline after the screen
  /// showed B.
  void dispose() {
    _disposed = true;
    if (_messaging.onModelInventoryRequest == _answer) {
      _messaging.onModelInventoryRequest = null;
    }
    if (_messaging.onModelInventoryOffer == _collect) {
      _messaging.onModelInventoryOffer = null;
    }
    _answers.close();
  }
}

/// One service per identity, rebuilt when the identity changes.
///
/// WATCHED, not read. This service installs two callbacks on a messaging
/// pipeline and answers questions about what this device holds — both belong
/// to one identity. Read once, it kept A's pipeline and A's storage for the
/// rest of the session: asking from B's screen sent the question over A's
/// transport, which tells the contact that A and B are the same device, and
/// the answer-contacts switch shown under B read and wrote A's setting. Worse
/// in the other direction — B's own pipeline had no handler at all, so B
/// silently answered nobody (report17 XV17-H5).
///
/// The rebuild disposes the previous service, which takes its callbacks off
/// A's pipeline and drops the questions it was still waiting on answers to.
final modelExchangeServiceProvider = Provider<ModelExchangeService>((ref) {
  final service = ModelExchangeService(
    messaging: ref.watch(messagingServiceProvider),
    storage: ref.watch(storageProvider),
    translateRoot: ref.watch(translationModelsRootProvider),
    speechRoot: () async =>
        ref.read(whisperModelStoreProvider).modelDirectory(),
    now: DateTime.now,
  );
  ref.onDispose(service.dispose);
  return service;
});

/// The setting behind the "answer contacts" switch.
///
/// Async because the answer lives in the container, which is not open until
/// the person has unlocked. Loading rather than a guessed default while it
/// reads: showing a switch in the wrong position and then flipping it under
/// someone's hand is worse than a moment of nothing, and worse still when the
/// thing being shown is what this device tells other people.
class AnswerModelInventoryController extends AsyncNotifier<bool> {
  @override
  Future<bool> build() {
    // WATCHED: the switch shows what THIS identity answers, and a switch
    // re-reads it rather than leaving the previous one's position on screen.
    final service = ref.watch(modelExchangeServiceProvider);
    _service = service;
    return service.answersAutomatically();
  }

  late ModelExchangeService _service;

  Future<void> set(bool enabled) async {
    final service = _service;
    await service.setAnswersAutomatically(enabled);
    // Flipped under A, landing after a switch: the setting went where it
    // belongs, the switch on B's screen must not move because of it.
    if (identical(_service, service)) state = AsyncData(enabled);
  }
}

final answerModelInventoryProvider =
    AsyncNotifierProvider<AnswerModelInventoryController, bool>(
      AnswerModelInventoryController.new,
    );
