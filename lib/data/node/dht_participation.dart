import 'dart:io';

import '../../core/log.dart';
import '../storage/storage.dart';

/// Whether this device serves the DHT for OTHER people.
///
/// The measurement that produced this setting: an idle client received
/// 13.6 KB/s, of which 85% was work done for strangers — storing their
/// records, answering their lookups, being a hop of their walks — while its
/// own application traffic was three bytes per second. On a phone that was
/// 5 GB a day.
///
/// Turning it off does NOT make the device quieter by refusing work locally;
/// that was tried (`service_budget_bytes_per_hour`) and measured to change the
/// traffic by nothing at all, because the bytes cross the network before any
/// local decision happens. It works by ADVERTISING the refusal at handshake
/// time, so upgraded peers stop choosing this node as a candidate at all.
///
/// It does not affect reachability. The node still publishes its own records,
/// still resolves others, still receives mail. What stops is unpaid work.
///
/// The cost falls on the network rather than on whoever turns it off, which is
/// why the default is a platform split rather than "off for everyone": every
/// xVeil client runs as `leaf` and only the seeds are `core`, so if every
/// client served nothing the replica set would be three machines.
const String kDhtParticipationSettingKey = 'dht.participate.v1';

/// Phones off, desktops on. Not a guess — see the measurement above; the
/// asymmetry is that a desktop is usually on mains and unmetered while a
/// phone is neither.
bool get kDhtParticipationDefault => !(Platform.isAndroid || Platform.isIOS);

/// What ONE read of the stored answer found.
///
/// Three outcomes, and they are not interchangeable: a device that never chose
/// must follow the platform default and keep following it if that default ever
/// changes; a device that chose must keep its choice even on a platform whose
/// default flips; and a read that FAILED knows neither, so it must not be
/// mistaken for either.
enum DhtParticipationState {
  /// The container holds an answer, in [DhtParticipationRead.value].
  answered,

  /// Never asked, or the space is not open yet — a normal lifecycle state,
  /// since the switch can be read before unlock.
  absent,

  /// An open space threw. A fault, not an answer.
  unreadable,
}

/// The outcome of a read, together with the answer when there is one.
typedef DhtParticipationRead = ({DhtParticipationState state, bool? value});

/// Read the stored answer ONCE.
///
/// Once is the point. This used to be two calls — `dhtParticipationAnswer` for
/// the value and `dhtParticipationUnreadable` for whether the read worked —
/// and `dhtParticipationEffective` made both. A fault that hit only the first
/// of them produced "no answer" from one and "readable" from the other, and
/// the resolution below then handed back the platform default: on a desktop,
/// `true`. So a single transient storage error booted a node that had
/// explicitly turned this OFF as one that serves the DHT for strangers — the
/// exact unpaid work the setting exists to stop, switched back on invisibly,
/// with the UI still showing the choice that was made (report14 X14-M3).
///
/// A second read cannot corroborate the first: they are separate reads of a
/// store that is allowed to fail intermittently. The only fix is to ask once
/// and carry the outcome.
Future<DhtParticipationRead> readDhtParticipation(Storage storage) async {
  if (!storage.isOpen) {
    return (state: DhtParticipationState.absent, value: null);
  }
  try {
    final raw = await storage.getSetting(kDhtParticipationSettingKey);
    return switch (raw) {
      'true' => (state: DhtParticipationState.answered, value: true),
      'false' => (state: DhtParticipationState.answered, value: false),
      _ => (state: DhtParticipationState.absent, value: null),
    };
  } catch (error) {
    devLog(() => 'xVeil[dht.participate]: setting unreadable ($error)');
    return (state: DhtParticipationState.unreadable, value: null);
  }
}

/// One identity's answer, or null when it has never been asked — or could not
/// be read. Prefer [readDhtParticipation], which tells those two apart.
Future<bool?> dhtParticipationAnswer(Storage storage) async =>
    (await readDhtParticipation(storage)).value;

/// Whether the stored answer could not be read at all, as opposed to never
/// having been given.
///
/// A CLOSED space is not this: it is a normal lifecycle state — the switch may
/// be asked before unlock — and it deliberately resolves to the platform
/// default, which `a closed store refuses the write and reads as unanswered`
/// pins. A throw from an OPEN space is different: it is a fault.
Future<bool> dhtParticipationUnreadable(Storage storage) async =>
    (await readDhtParticipation(storage)).state ==
    DhtParticipationState.unreadable;

/// The answer to boot with: this identity's choice, else the platform default.
///
/// Never writes. Resolving a default is not answering the question, and
/// freezing the invention into the container would make tomorrow's default
/// unable to reach a device that simply never chose.
Future<bool> dhtParticipationEffective(Storage storage) async {
  final read = await readDhtParticipation(storage);
  return switch (read.state) {
    DhtParticipationState.answered => read.value!,
    // A read that FAILED resolves to NOT serving.
    //
    // The asymmetry is the reason, not the odds. Failing to serve costs the
    // network one replica for one session, and the node still publishes its
    // own records, still resolves others, still receives mail. Failing to
    // honour an opt-out spends someone else's battery and metered data
    // against a decision they made deliberately, and it does it invisibly.
    // The next boot that can read the space restores the real answer.
    DhtParticipationState.unreadable => false,
    // Never asked resolves to the platform default, as it always has.
    DhtParticipationState.absent => kDhtParticipationDefault,
  };
}

/// Write this identity's answer. **False means it was not written**, including
/// "the space is not open" — the caller has to be able to say so rather than
/// show a switch that did not stick.
Future<bool> setDhtParticipation(Storage storage, bool participate) async {
  if (!storage.isOpen) return false;
  try {
    await storage.putSetting(
      kDhtParticipationSettingKey,
      participate ? 'true' : 'false',
    );
    return true;
  } catch (_) {
    return false;
  }
}
