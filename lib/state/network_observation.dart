import 'dart:async';
import 'dart:io' show Platform;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/transport/veil_transport.dart';

NetworkAttachment networkAttachmentOf(List<ConnectivityResult> results) {
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
    return NetworkAttachment.offline;
  }
  if (results.contains(ConnectivityResult.wifi)) return NetworkAttachment.wifi;
  if (results.contains(ConnectivityResult.ethernet)) {
    return NetworkAttachment.ethernet;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return NetworkAttachment.cellular;
  }
  return NetworkAttachment.unknown;
}

/// An observer-local revision, never a network handle, SSID, BSSID or address.
class NetworkObservation {
  const NetworkObservation(this.attachment, {this.revision});
  factory NetworkObservation.types(List<ConnectivityResult> results) =>
      NetworkObservation(networkAttachmentOf(results));

  final NetworkAttachment attachment;
  final int? revision;

  static NetworkObservation decode(Object? value) {
    if (value is! Map) {
      throw const FormatException('Invalid network observation');
    }
    final revision = value['revision'];
    final attachment = switch (value['kind']) {
      'wifi' => NetworkAttachment.wifi,
      'cellular' => NetworkAttachment.cellular,
      'ethernet' => NetworkAttachment.ethernet,
      'offline' => NetworkAttachment.offline,
      'unknown' => NetworkAttachment.unknown,
      _ => null,
    };
    if (attachment == null || revision is! int || revision < 0) {
      throw const FormatException('Invalid network observation');
    }
    return NetworkObservation(attachment, revision: revision);
  }
}

final networkConnectivityProvider = Provider<Connectivity>(
  (_) => Connectivity(),
);

final networkObservationSourceProvider = Provider<NetworkObservationSource>((
  ref,
) {
  final source = NetworkObservationSource(
    ref.watch(networkConnectivityProvider),
  );
  ref.onDispose(() => unawaited(source.dispose()));
  return source;
});

/// Android needs the identity of the default Network, not just its transport
/// type. Other platforms, and Android versions without the native port, retain
/// the existing connectivity observation. Only one source drives reconnects.
class NetworkObservationSource {
  NetworkObservationSource(this.connectivity, {bool? isAndroid}) {
    if (isAndroid ?? (!kIsWeb && Platform.isAndroid)) {
      _native = const EventChannel('xveil/default_network/events')
          .receiveBroadcastStream()
          .listen(
            (value) {
              if (_fallback || _disposed) return;
              try {
                _publish(NetworkObservation.decode(value));
              } catch (_) {
                _useFallback();
              }
            },
            onError: (Object _) => _useFallback(),
            onDone: _useFallback,
          );
    } else {
      _useFallback(reseed: false);
    }
  }

  final Connectivity connectivity;
  final _events = StreamController<NetworkObservation>.broadcast(sync: true);
  StreamSubscription<Object?>? _native;
  StreamSubscription<List<ConnectivityResult>>? _legacy;
  bool _fallback = false;
  bool _disposed = false;
  int _observations = 0;

  Stream<NetworkObservation> get changes => _events.stream;

  Future<NetworkObservation> current() async {
    if (!_fallback) {
      try {
        final result = await const MethodChannel(
          'xveil/default_network',
        ).invokeMethod<Object?>('current');
        if (!_fallback) return NetworkObservation.decode(result);
      } catch (_) {
        _useFallback();
      }
    }
    return NetworkObservation.types(await connectivity.checkConnectivity());
  }

  void _publish(NetworkObservation observation) {
    if (!_disposed) {
      _observations++;
      _events.add(observation);
    }
  }

  void _useFallback({bool reseed = true}) {
    if (_fallback || _disposed) return;
    _fallback = true;
    unawaited(_native?.cancel());
    _legacy = connectivity.onConnectivityChanged.listen(
      (results) => _publish(NetworkObservation.types(results)),
      onError: (Object _) {},
    );
    // A native stream may fail after its initial snapshot has been applied.
    // Seed its replacement even if the legacy source emits no immediate event.
    final before = _observations;
    if (reseed) {
      unawaited(() async {
        try {
          final snapshot = await connectivity.checkConnectivity();
          if (_observations == before) {
            _publish(NetworkObservation.types(snapshot));
          }
        } catch (_) {}
      }());
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _native?.cancel();
    await _legacy?.cancel();
    await _events.close();
  }
}
