import 'package:veil_media/veil_media.dart';

import '../data/transport/veil_flutter_transport.dart';
import '../domain/call.dart';
import 'call_service.dart';
import 'mac_media_permissions.dart';

/// The real [CallMediaController]: opens a veil media datagram channel to the
/// call peer and drives the libwebrtc audio engine (libveil_media.dylib) over
/// it. Per-packet RTP/RTCP flows native↔native (the C++ Transport shim calls
/// the veil_media_* ABI); this Dart layer is control only.
///
/// SSRCs are derived from the node ids inside the engine, so both ends agree
/// without extra negotiation. One engine per live call; [stop] is idempotent.
class VeilCallMediaController implements CallMediaController {
  VeilCallMediaController(this._transport);

  final VeilFlutterTransport _transport;
  VeilMediaEngine? _engine;
  int? _chan;

  @override
  Future<bool> start(Call call) async {
    await stop(); // never leak a prior session
    // Present the macOS mic (and camera for video) TCC prompt via
    // AVCaptureDevice BEFORE the engine touches CoreAudio — but NEVER let the
    // prompt block the call FSM: bound the wait, and proceed regardless (the
    // engine still comes up; capture starts once permission lands).
    if (call.media.audio) {
      await MacMediaPermissions.requestMicrophone()
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
    }
    if (call.media.video) {
      await MacMediaPermissions.requestCamera()
          .timeout(const Duration(seconds: 5), onTimeout: () => false);
    }
    final localId = (await _transport.nodeId()).bytes;
    final peerId = call.peer.bytes;
    final chan = await _transport.openMediaChannel(peerId);
    _chan = chan;
    final engine = VeilMediaEngine.create(
      veilChan: chan,
      localId: localId,
      peerId: peerId,
    );
    if (engine == null) {
      _transport.closeMediaChannel(chan);
      _chan = null;
      return false;
    }
    _engine = engine;
    // Audio both directions for now; video/screen ride later phases.
    return engine.startAudio(send: true, recv: true);
  }

  @override
  Future<void> stop() async {
    final e = _engine;
    _engine = null;
    if (e != null) {
      try {
        e.stopAudio();
      } catch (_) {}
      try {
        e.dispose();
      } catch (_) {}
    }
    final ch = _chan;
    _chan = null;
    if (ch != null) {
      try {
        _transport.closeMediaChannel(ch);
      } catch (_) {}
    }
  }
}
