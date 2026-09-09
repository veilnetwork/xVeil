// Which settings may travel in an offline archive, decided once.
//
// The container's settings namespace is not a preferences bag. It also holds
// credentials and cryptographic state: `node.master_key.v1` is base64 master
// signing material, `node.sovereign_identity.v1` the identity document,
// `ratchet.*` the double-ratchet's own instance state. An import that filled
// any missing key would let a file somebody sent plant a master key that was
// merely ABSENT — no overwrite needed, and no password either, since an open
// archive is just bytes anyone can write.
//
// So the rule is an ALLOWLIST, not a denylist. A denylist is a promise to have
// thought of every dangerous key that exists today and every one added later;
// this list is a promise about the few that are safe, and a new key is not
// carried until somebody decides it should be. The cost is real and is stated
// in the import report: settings outside the list are counted as not carried,
// rather than silently dropped.
//
// Three kinds of key are deliberately NOT here:
//
//   * credentials and key material (`node.*`, `ratchet.*`) — an archive is not
//     how an identity moves; the identity record is, under its own guard;
//   * machine-local state (window sizes, paths, chosen directories) — carrying
//     it would point one device at another device's disk;
//   * the device-group registry (`devices.*`, `groups.index`) — device
//     membership is signed state that the group's own log carries.
//
// The three keys the device-group sync already carries travel as sync events
// instead ([DeviceSettingsSyncHub.syncedKeys]), so they are not repeated here.

/// Settings carried verbatim by an archive.
///
/// Short on purpose. `nickname:claimed` is here because a claimed public name
/// belongs to the IDENTITY rather than to a device, contains no secret (the
/// claim is published to the network), and is otherwise silently lost when a
/// person moves to a new device.
const Set<String> kTransferableSettingKeys = {'nickname:claimed'};

/// Prefixes that are never carried, whatever the exact key.
///
/// Redundant with the allowlist by construction — nothing outside it travels —
/// and kept as a second, explicit statement so that widening the allowlist by
/// accident cannot quietly admit key material. A key matching one of these is
/// refused even if somebody adds it to the list above.
const List<String> kNeverTransferredSettingPrefixes = [
  'node.',
  'ratchet.',
  'devices.',
  'groups.',
  'identity.',
];

/// Whether [key] may travel in an archive.
///
/// Used by BOTH sides: the exporter does not write what the importer would not
/// accept, so an archive never carries a value that silently goes nowhere, and
/// the two cannot drift into disagreeing about what a transfer contains.
bool isTransferableSetting(String key) {
  for (final prefix in kNeverTransferredSettingPrefixes) {
    if (key.startsWith(prefix)) return false;
  }
  return kTransferableSettingKeys.contains(key);
}
