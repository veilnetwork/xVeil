import 'dart:async';
import 'dart:typed_data';

import 'android_microphone_lifetime.dart';

import 'package:veil_flutter/veil_flutter.dart'
    show VeilBackground, VeilBackgroundRetirement;

final class BackgroundServiceRetired implements Exception {
  const BackgroundServiceRetired();
  @override
  String toString() => 'BackgroundServiceRetired';
}

final class BackgroundServiceUnavailable implements Exception {
  const BackgroundServiceUnavailable();
  @override
  String toString() => 'BackgroundServiceUnavailable';
}

/// Resource/admission ownership, not permission to erase a profile. Release
/// must recheck the same native owner or recognize its exact lost-success reply.
abstract interface class BackgroundResourceRetirement {
  Future<void> verifyReleasedResources();
  Future<void> releaseAdmission();
}

final class _SdkRetirement implements BackgroundResourceRetirement {
  _SdkRetirement(this.owner, this.microphone);
  final VeilBackgroundRetirement owner;
  final AndroidMicrophoneRetirement microphone;
  @override
  Future<void> verifyReleasedResources() async {
    await owner.verifyReleasedResources();
    await microphone.verifyReleasedResources();
  }

  @override
  Future<void> releaseAdmission() async {
    await microphone.releaseNativeAdmission();
    await owner.releaseAdmission();
    microphone.publishFreshLifetime();
  }
}

typedef BackgroundCallStart =
    Future<void> Function({
      String? title,
      String? text,
      bool hangupAction,
      String? callSession,
      bool ringing,
      bool microphone,
      bool camera,
    });
typedef BackgroundCallPresentation =
    Future<bool> Function({
      required String callSession,
      required String callerName,
      Uint8List? avatar,
    });

/// One application lifetime for every daemon command, including call updates.
/// Retirement seals admission synchronously and joins accepted platform calls.
/// Old facades stay sealed after native release; providers must publish a fresh
/// facade for the next profile lifetime. Missing retirement is never absence.
class BackgroundServiceActions {
  BackgroundServiceActions({
    required this._start,
    required this._stop,
    this._retire,
    this._callStart,
    this._callPresentation,
  });

  factory BackgroundServiceActions.platform() => BackgroundServiceActions(
    start: VeilBackground.start,
    stop: VeilBackground.stop,
    retire: () async {
      final microphone = AndroidMicrophoneLifetime.current()..sealAdmission();
      final background = await VeilBackground.retire();
      return _SdkRetirement(background, await microphone.retireForErasure());
    },
    callStart: VeilBackground.start,
    callPresentation: VeilBackground.setCallPresentation,
  );

  final Future<void> Function() _start, _stop;
  final Future<BackgroundResourceRetirement> Function()? _retire;
  final BackgroundCallStart? _callStart;
  final BackgroundCallPresentation? _callPresentation;
  final _accepted = <Future<void>>{};
  bool _retired = false;
  Future<BackgroundResourceRetirement>? _retiring;
  BackgroundResourceRetirement? _owner;

  Future<T> _admit<T>(Future<T> Function() action) {
    if (_retired) return Future.error(const BackgroundServiceRetired());
    // Reserve before invoking an adapter: reentrant retirement must join this
    // accepted call too, even before the adapter returns its future.
    final settled = Completer<void>();
    _accepted.add(settled.future);
    final work = Future<T>.sync(action);
    void finish() {
      settled.complete();
      _accepted.remove(settled.future);
    }

    unawaited(
      work.then<void>(
        (_) => finish(),
        onError: (Object _, StackTrace _) => finish(),
      ),
    );
    return work;
  }

  Future<void> start() => _admit(_start);
  Future<void> stop() => _admit(_stop);

  Future<void> startCall({
    String? title,
    String? text,
    bool hangupAction = false,
    String? callSession,
    bool ringing = false,
    bool microphone = false,
    bool camera = false,
  }) => _admit(() {
    final send = _callStart;
    if (send == null) throw const BackgroundServiceUnavailable();
    return send(
      title: title,
      text: text,
      hangupAction: hangupAction,
      callSession: callSession,
      ringing: ringing,
      microphone: microphone,
      camera: camera,
    );
  });

  Future<bool> setCallPresentation({
    required String callSession,
    required String callerName,
    Uint8List? avatar,
  }) {
    return _admit(() {
      final owned = avatar == null ? null : Uint8List.fromList(avatar);
      final send = _callPresentation;
      if (send == null) throw const BackgroundServiceUnavailable();
      return send(
        callSession: callSession,
        callerName: callerName,
        avatar: owned,
      );
    });
  }

  Future<BackgroundResourceRetirement> retireForErasure() {
    _retired = true;
    final owner = _owner;
    if (owner != null) return Future.value(owner);
    final pending = _retiring;
    if (pending != null) return pending;
    final earlier = _accepted.toList(growable: false);
    late final Future<BackgroundResourceRetirement> next;
    next =
        () async {
          await Future.wait(earlier);
          final retire = _retire;
          if (retire == null) throw const BackgroundServiceUnavailable();
          return _owner = await retire();
        }().whenComplete(() {
          if (identical(_retiring, next)) _retiring = null;
        });
    return _retiring = next;
  }
}
