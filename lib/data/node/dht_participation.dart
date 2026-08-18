import 'dart:io';

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
bool get kDhtParticipationDefault =>
    !(Platform.isAndroid || Platform.isIOS);

/// One identity's answer, or null when it has never been asked.
///
/// Tri-state on purpose, exactly like the bundled-seeds answer next to it: a
/// device that has never chosen must follow the platform default and keep
/// following it if that default ever changes, while a device that explicitly
/// chose "serve" must keep serving even on a platform whose default flips.
/// Collapsing the two at read time would silently overwrite a real choice with
/// a policy decision made later.
Future<bool?> dhtParticipationAnswer(Storage storage) async {
  if (!storage.isOpen) return null;
  try {
    final raw = await storage.getSetting(kDhtParticipationSettingKey);
    return switch (raw) {
      'true' => true,
      'false' => false,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// The answer to boot with: this identity's choice, else the platform default.
///
/// Never writes. Resolving a default is not answering the question, and
/// freezing the invention into the container would make tomorrow's default
/// unable to reach a device that simply never chose.
Future<bool> dhtParticipationEffective(Storage storage) async =>
    (await dhtParticipationAnswer(storage)) ?? kDhtParticipationDefault;

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
