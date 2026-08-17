import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import 'messaging_providers.dart';
import 'providers.dart';

/// Re-dial the overlay when the app comes back from the background.
///
/// The lifecycle half of the suspended-node defect (2026-08-17): an Android
/// node that loses its sessions while the app is backgrounded comes back
/// COMPLETELY dark — zero inbound from anyone, its own mailbox unreachable,
/// and senders' "live leg ok" a fiction, because the transport accepts frames
/// that then evaporate. Nothing in the runtime re-dials on its own; waking
/// the screen and foregrounding the app change nothing, and before this
/// observer only a full app restart revived the node.
///
/// On resume after a real absence the observer re-joins the boot's seed set
/// (joining a session that is still alive is a cheap no-op) and nudges the
/// mailbox drain, so queued mail surfaces the moment connectivity is back
/// rather than on the idle cadence.
///
/// The absence threshold keeps alt-tab flapping free: a resume within it is
/// ignored. Sessions survive short pauses; it is the minutes-long ones that
/// kill them.
const kResumeRedialAfter = Duration(seconds: 45);

final resumeReconnectProvider = Provider<void>((ref) {
  final observer = _ResumeReconnectObserver(ref);
  final binding = WidgetsBinding.instance;
  binding.addObserver(observer);
  ref.onDispose(() => binding.removeObserver(observer));
});

class _ResumeReconnectObserver with WidgetsBindingObserver {
  _ResumeReconnectObserver(this._ref);
  final Ref _ref;

  DateTime? _pausedAt;
  bool _redialing = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _pausedAt ??= DateTime.now();
      case AppLifecycleState.resumed:
        final away = _pausedAt == null
            ? Duration.zero
            : DateTime.now().difference(_pausedAt!);
        _pausedAt = null;
        if (away < kResumeRedialAfter) return;
        unawaited(_redial(away));
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _redial(Duration away) async {
    if (_redialing) return;
    _redialing = true;
    try {
      final stack = _ref.read(realStackProvider);
      if (stack == null) return;
      devLog(
        () =>
            'xVeil[bootstrap]: resumed after ${away.inSeconds}s away — '
            're-dialing the overlay',
      );
      await stack.redialSeeds();
      // Mail deposited while the node was dark is already at the relay;
      // surface it now instead of on the idle cadence.
      _ref.read(messagingServiceProvider).nudgeMailboxDrain();
    } on Object catch (e) {
      devLog(() => 'xVeil[bootstrap]: resume redial failed: $e');
    } finally {
      _redialing = false;
    }
  }
}
