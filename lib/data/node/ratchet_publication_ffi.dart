part of 'ratchet_ffi.dart';

typedef _HostBeginNative =
    Int32 Function(Pointer<Void>, Pointer<Uint64>, Pointer<Pointer<Utf8>>);
typedef _HostBeginDart =
    int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Pointer<Utf8>>);
typedef _HostStateNative =
    Int32 Function(
      Pointer<Void>,
      Uint64,
      Pointer<Int32>,
      Pointer<Pointer<Utf8>>,
    );
typedef _HostStateDart =
    int Function(Pointer<Void>, int, Pointer<Int32>, Pointer<Pointer<Utf8>>);
typedef _HostAllowNative =
    Int32 Function(
      Pointer<Void>,
      Uint64,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Utf8>>,
    );
typedef _HostAllowDart =
    int Function(
      Pointer<Void>,
      int,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Utf8>>,
    );
typedef _HostEndNative =
    Int32 Function(Pointer<Void>, Uint64, Pointer<Pointer<Utf8>>);
typedef _HostEndDart = int Function(Pointer<Void>, int, Pointer<Pointer<Utf8>>);

int _beginHostPublication(FfiRatchetStateHandle door) {
  final epoch = calloc<Uint64>(), error = calloc<Pointer<Utf8>>();
  try {
    final fn = door._dl.lookupFunction<_HostBeginNative, _HostBeginDart>(
      'veil_ratchet_host_begin',
    );
    if (fn(door._handle, epoch, error) != 0) {
      throw StateError('begin ratchet publication: ${door._takeErr(error)}');
    }
    if (epoch.value == 0) throw StateError('invalid ratchet publication epoch');
    return epoch.value;
  } finally {
    calloc.free(epoch);
    calloc.free(error);
  }
}

RatchetPublicationState _hostPublicationState(
  FfiRatchetStateHandle door,
  int epoch,
) {
  final state = calloc<Int32>(), error = calloc<Pointer<Utf8>>();
  try {
    final fn = door._dl.lookupFunction<_HostStateNative, _HostStateDart>(
      'veil_ratchet_host_state',
    );
    if (fn(door._handle, epoch, state, error) != 0) {
      throw StateError('read ratchet publication: ${door._takeErr(error)}');
    }
    if (state.value < 0 ||
        state.value >= RatchetPublicationState.values.length) {
      throw StateError('invalid ratchet publication state');
    }
    return RatchetPublicationState.values[state.value];
  } finally {
    calloc.free(state);
    calloc.free(error);
  }
}

void _allowHostPublication(
  FfiRatchetStateHandle door,
  int epoch,
  Uint8List key,
  List<RatchetSendPosition> positions,
) {
  if (key.length != kRatchetKeyLen ||
      positions.length > veilRatchetMaxSendPositions) {
    throw ArgumentError('invalid ratchet publication key/count');
  }
  for (final at in positions) {
    if (at.chain.length != 32 || at.next < 0 || at.next > 0xffffffff) {
      throw ArgumentError('invalid ratchet publication position');
    }
  }
  final keyPtr = calloc<Uint8>(kRatchetKeyLen),
      marks = calloc<Uint8>(positions.length * 36 + 1),
      error = calloc<Pointer<Utf8>>();
  try {
    keyPtr.asTypedList(kRatchetKeyLen).setAll(0, key);
    final bytes = marks.asTypedList(positions.length * 36);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < positions.length; i++) {
      bytes.setAll(i * 36, positions[i].chain);
      data.setUint32(i * 36 + 32, positions[i].next, Endian.big);
    }
    final fn = door._dl.lookupFunction<_HostAllowNative, _HostAllowDart>(
      'veil_ratchet_host_allow',
    );
    if (fn(door._handle, epoch, keyPtr, marks, positions.length, error) != 0) {
      throw StateError(
        'authorize ratchet publication: ${door._takeErr(error)}',
      );
    }
  } finally {
    calloc.free(keyPtr);
    calloc.free(marks);
    calloc.free(error);
  }
}

void _endHostPublication(FfiRatchetStateHandle door, int epoch) {
  final error = calloc<Pointer<Utf8>>();
  try {
    final fn = door._dl.lookupFunction<_HostEndNative, _HostEndDart>(
      'veil_ratchet_host_end',
    );
    if (fn(door._handle, epoch, error) != 0) {
      throw StateError('close ratchet publication: ${door._takeErr(error)}');
    }
  } finally {
    calloc.free(error);
  }
}
