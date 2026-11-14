import 'dart:async';
import 'dart:io';

import 'capture_resource_lifetime.dart';

abstract interface class CaptureOutputStore {
  Future<void> remove(String path);
}

final class FileCaptureOutputStore implements CaptureOutputStore {
  const FileCaptureOutputStore();
  @override
  Future<void> remove(String path) async {
    final kind = await FileSystemEntity.type(path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return;
    if (kind != FileSystemEntityType.file) {
      throw const CaptureResourceRetirementFailure();
    }
    await File(path).delete();
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const CaptureResourceRetirementFailure();
    }
  }
}

/// An app-created plaintext camera output, retained through navigation and its
/// one consumer. Retirement joins an accepted consumer before deleting its file.
/// A cleanup refusal retains this owner even after a successful send.
final class CaptureOutputFile implements CaptureResource {
  CaptureOutputFile(
    this.path, {
    required CaptureResourceLifetime lifetime,
    this.store = const FileCaptureOutputStore(),
  }) : _lifetime = lifetime {
    _sealed = !lifetime.admit(this);
  }
  final String path;
  final CaptureResourceLifetime _lifetime;
  final CaptureOutputStore store;
  bool _sealed = false, _used = false, _removed = false;
  Future<void>? _accepted, _deleting;

  bool get canUse => !_sealed && !_used && _lifetime.isAdmitting;

  Future<T> use<T>(Future<T> Function(String path) consume) {
    if (_sealed || _used || !_lifetime.isAdmitting) {
      return Future.error(const CaptureResourceRetirementFailure());
    }
    _used = true;
    final settled = Completer<void>();
    _accepted = settled.future;
    final result = Completer<T>();
    unawaited(() async {
      try {
        final value = await Future<T>.sync(() => consume(path));
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _sealed = true;
        // Cleanup failure must not turn an already accepted send into a retry
        // suggestion. The registered owner remains and erasure must retry it.
        try {
          await _remove();
        } catch (_) {}
        settled.complete();
      }
    }());
    // Return only after automatic cleanup settled, including a refused cleanup.
    return result.future.then(
      (value) async {
        await settled.future;
        return value;
      },
      onError: (Object error, StackTrace stack) async {
        await settled.future;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  @override
  Future<void> retire() async {
    _sealed = true;
    await _accepted;
    await _remove();
  }

  Future<void> _remove() {
    if (_removed) return Future.value();
    final pending = _deleting;
    if (pending != null) return pending;
    final result = Completer<void>();
    _deleting = result.future;
    unawaited(() async {
      try {
        await store.remove(path);
        _removed = true;
        _lifetime.forget(this);
        result.complete();
      } catch (_) {
        result.completeError(const CaptureResourceRetirementFailure());
      } finally {
        _deleting = null;
      }
    }());
    return result.future;
  }
}
