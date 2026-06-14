import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/ids.dart';
import '../domain/identity.dart';
import 'providers.dart';

/// Top-level lifecycle of the app, used by the router to gate screens.
enum AppPhase {
  /// Reading prefs / deciding where to send the user.
  bootstrapping,

  /// No identity set up yet — run the first-launch wizard.
  onboarding,

  /// An identity exists; the space is locked and needs a password.
  locked,

  /// Space unlocked, node starting/connected — show the messenger.
  ready,
}

class AppState {
  const AppState(this.phase, {this.identity, this.unlockError = false});

  final AppPhase phase;
  final Identity? identity;
  final bool unlockError;

  AppState copyWith({AppPhase? phase, Identity? identity, bool? unlockError}) =>
      AppState(
        phase ?? this.phase,
        identity: identity ?? this.identity,
        unlockError: unlockError ?? false,
      );
}

const _kOnboardedKey = 'onboarded';
const _kStorageModeKey = 'storage_mode';

class AppController extends Notifier<AppState> {
  @override
  AppState build() {
    _bootstrap();
    return const AppState(AppPhase.bootstrapping);
  }

  Future<void> _bootstrap() async {
    final prefs = await ref.read(prefsProvider.future);
    final onboarded = prefs.getBool(_kOnboardedKey) ?? false;
    state = AppState(onboarded ? AppPhase.locked : AppPhase.onboarding);
  }

  /// Finish first-launch setup: persist the new identity into a freshly
  /// created space and start the session.
  Future<void> completeOnboarding({
    required Identity identity,
    required String password,
    required StorageMode mode,
  }) async {
    final storage = ref.read(storageProvider);
    await storage.open(password: password, createIfMissing: true);
    await storage.saveIdentity(identity);

    final prefs = await ref.read(prefsProvider.future);
    await prefs.setBool(_kOnboardedKey, true);
    await prefs.setString(_kStorageModeKey, mode.name);

    await _enterSession(identity);
  }

  /// Returning user: try to unlock the space with [password].
  Future<void> unlock(String password) async {
    final storage = ref.read(storageProvider);
    bool ok;
    try {
      ok = await storage.open(password: password);
    } catch (_) {
      // Wrong password, missing or corrupt container — never let unlock throw
      // (that would freeze the lock screen's spinner). Surface as an error.
      ok = false;
    }
    if (!ok) {
      state = state.copyWith(unlockError: true);
      return;
    }
    final identity = await storage.loadIdentity() ?? _placeholderIdentity();
    await _enterSession(identity);
  }

  Future<void> _enterSession(Identity identity) async {
    // Kick the node off without blocking the UI transition.
    ref.read(nodeControllerProvider).start();
    // In real mode the user's identity IS the node's identity — show the real
    // node id (and invite) rather than the local placeholder.
    final stack = ref.read(realStackProvider);
    final effective = stack != null
        ? Identity(
            nodeId: stack.myInvite.nodeId,
            displayName: identity.displayName,
            username: identity.username,
          )
        : identity;
    state = AppState(AppPhase.ready, identity: effective);
  }

  Future<void> lock() async {
    await ref.read(storageProvider).close();
    state = const AppState(AppPhase.locked);
  }

  /// Generates a fresh sovereign identity. The real implementation derives a
  /// 24-word BIP-39 phrase + node id via veil_flutter; here we mint a random
  /// node id so the rest of the flow is exercisable.
  static Identity generateIdentity({String? displayName}) {
    final rnd = Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = rnd.nextInt(256);
    }
    return Identity(nodeId: NodeId(bytes), displayName: displayName);
  }

  Identity _placeholderIdentity() => generateIdentity();
}

final appControllerProvider =
    NotifierProvider<AppController, AppState>(AppController.new);
