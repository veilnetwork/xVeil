import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../native_libs.dart';

typedef _StartNative =
    Int32 Function(
      Int32 tunFd,
      Pointer<Utf8> proxyUrl,
      Pointer<Utf8> dnsIp,
      Uint16 mtu,
      Bool ipv6Enabled,
      Bool packetInformation,
      Bool routeDns,
    );
typedef _StartDart =
    int Function(
      int tunFd,
      Pointer<Utf8> proxyUrl,
      Pointer<Utf8> dnsIp,
      int mtu,
      bool ipv6Enabled,
      bool packetInformation,
      bool routeDns,
    );
typedef _StartRoutedNative =
    Int32 Function(
      Int32 tunFd,
      Pointer<Utf8> proxyUrl,
      Pointer<Utf8> dnsIp,
      Uint16 mtu,
      Bool ipv6Enabled,
      Bool packetInformation,
      Bool routeDns,
      Pointer<Utf8> selectorListen,
      Pointer<Utf8> selectorToken,
    );
typedef _StartRoutedDart =
    int Function(
      int tunFd,
      Pointer<Utf8> proxyUrl,
      Pointer<Utf8> dnsIp,
      int mtu,
      bool ipv6Enabled,
      bool packetInformation,
      bool routeDns,
      Pointer<Utf8> selectorListen,
      Pointer<Utf8> selectorToken,
    );
typedef _StatusNative = Int32 Function();
typedef _StatusDart = int Function();
typedef _LastErrorNative = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();
typedef _FreeStringNative = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);

/// Thin, synchronous lifecycle binding for the process-wide Rust packet engine.
///
/// Interface creation and permission prompts remain platform responsibilities;
/// this binding only consumes the resulting TUN descriptor.
class PacketTunnelFfi {
  PacketTunnelFfi._(DynamicLibrary library)
    : _start = library.lookupFunction<_StartNative, _StartDart>(
        'veil_packet_tunnel_start_fd',
      ),
      _status = library.lookupFunction<_StatusNative, _StatusDart>(
        'veil_packet_tunnel_status',
      ),
      _stop = library.lookupFunction<_StatusNative, _StatusDart>(
        'veil_packet_tunnel_stop',
      ),
      _lastError = library.lookupFunction<_LastErrorNative, _LastErrorDart>(
        'veil_packet_tunnel_last_error',
      ),
      _freeString = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
        'veil_free_string',
      ),
      _startRouted = _lookupRouted(library);

  static const stopped = 0;
  static const starting = 1;
  static const running = 2;
  static const error = 3;

  final _StartDart _start;
  final _StartRoutedDart? _startRouted;
  final _StatusDart _status;
  final _StatusDart _stop;
  final _LastErrorDart _lastError;
  final _FreeStringDart _freeString;

  /// Returns null for old/platform builds that do not embed the packet engine.
  static PacketTunnelFfi? tryOpen() {
    try {
      return PacketTunnelFfi._(processLibFor('veilclient_ffi'));
    } catch (_) {
      return null;
    }
  }

  int start({
    required int tunFd,
    required String socks5Listen,
    required String dnsIp,
    required int mtu,
    required bool packetInformation,
    required bool routeDns,
    String? selectorListen,
    String? selectorToken,
  }) {
    final proxyUrl = 'socks5://$socks5Listen'.toNativeUtf8();
    final dns = dnsIp.toNativeUtf8();
    final selectorAddress = selectorListen?.toNativeUtf8();
    final token = selectorToken?.toNativeUtf8();
    try {
      if ((selectorAddress == null) != (token == null)) return -1;
      if (selectorAddress != null && token != null) {
        final routed = _startRouted;
        if (routed == null) return -1;
        return routed(
          tunFd,
          proxyUrl,
          dns,
          mtu,
          true,
          packetInformation,
          routeDns,
          selectorAddress,
          token,
        );
      }
      return _start(
        tunFd,
        proxyUrl,
        dns,
        mtu,
        true,
        packetInformation,
        routeDns,
      );
    } finally {
      calloc.free(proxyUrl);
      calloc.free(dns);
      if (selectorAddress != null) calloc.free(selectorAddress);
      if (token != null) calloc.free(token);
    }
  }

  static _StartRoutedDart? _lookupRouted(DynamicLibrary library) {
    try {
      return library.lookupFunction<_StartRoutedNative, _StartRoutedDart>(
        'veil_packet_tunnel_start_fd_routed',
      );
    } on ArgumentError {
      return null;
    }
  }

  int status() => _status();

  int stop() => _stop();

  String? lastError() {
    final pointer = _lastError();
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } finally {
      _freeString(pointer);
    }
  }
}
