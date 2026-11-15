import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import '../domain/storage_locator.dart';

const kStartupUnlockOptIn = 'quick_unlock_os_store.v1';

/// Per enumerable access root, just like its OS record. Legacy bytes remain
/// unchanged; these markers never enumerate hidden spaces or contain secrets.
String startupUnlockConsentKey(IdentityStorageLocator locator) =>
    switch (locator) {
      LegacyStorageLocator() => kStartupUnlockOptIn,
      ManagedStorageLocator(:final id, :final protection) =>
        '$kStartupUnlockOptIn.managed.${protection.name}.${id.value}',
    };

bool startupUnlockConsented(
  SharedPreferences prefs,
  IdentityStorageLocator locator,
) =>
    prefs.getBool(startupUnlockConsentKey(locator)) ??
    (locator is ManagedStorageLocator
        ? prefs.getBool(kStartupUnlockOptIn) == true
        : false);

// ProfilePreferencesLifetime supplies one stable view per backend lifetime.
// Serialize the entire consent operation, not only its individual disk writes:
// preserving a legacy fallback must not overwrite a concurrent explicit choice.
final _pendingConsent = Expando<Future<void>>();
Future<bool> _consentWork(
  SharedPreferences prefs,
  Future<bool> Function() action,
) {
  final result = (_pendingConsent[prefs] ?? Future<void>.value()).then(
    (_) => action(),
  );
  final settled = result.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {},
  );
  _pendingConsent[prefs] = settled;
  unawaited(
    settled.then((_) {
      if (identical(_pendingConsent[prefs], settled)) {
        _pendingConsent[prefs] = null;
      }
    }),
  );
  return result;
}

Future<bool> _preserveLegacyConsent(
  SharedPreferences prefs,
  List<ManagedStorageLocator> siblings,
) async {
  final allowed = prefs.getBool(kStartupUnlockOptIn) == true;
  for (final sibling in siblings) {
    final key = startupUnlockConsentKey(sibling);
    if (prefs.getBool(key) == null && !await prefs.setBool(key, allowed)) {
      return false;
    }
  }
  return true;
}

/// Before changing the old shared marker, materialize its prior meaning for
/// already public siblings. No OS or hidden-space probe is needed. Refusal
/// leaves the shared fallback intact; explicit scoped denials stay denials.
Future<bool> setStartupUnlockConsent(
  SharedPreferences prefs,
  IdentityStorageLocator locator, {
  Iterable<ManagedStorageLocator> managedSiblings = const [],
}) {
  final siblings = List<ManagedStorageLocator>.unmodifiable(managedSiblings);
  return _consentWork(prefs, () async {
    if (locator is LegacyStorageLocator &&
        !await _preserveLegacyConsent(prefs, siblings)) {
      return false;
    }
    return prefs.setBool(startupUnlockConsentKey(locator), true);
  });
}

Future<bool> clearStartupUnlockConsent(
  SharedPreferences prefs,
  IdentityStorageLocator locator, {
  Iterable<ManagedStorageLocator> managedSiblings = const [],
}) {
  final siblings = List<ManagedStorageLocator>.unmodifiable(managedSiblings);
  return _consentWork(prefs, () async {
    if (locator is ManagedStorageLocator) {
      // A tombstone prevents an old shared opt-in from reviving this choice.
      return prefs.setBool(startupUnlockConsentKey(locator), false);
    }
    if (!await _preserveLegacyConsent(prefs, siblings)) return false;
    return prefs.remove(kStartupUnlockOptIn);
  });
}
