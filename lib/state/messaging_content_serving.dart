part of 'messaging_core.dart';

typedef _ServedContent = ({
  ContentManifest manifest,
  ServeSource? source,
  DateTime servedAt,
});

/// Owns sender-side content manifests and every live [ServeSource] handle.
///
/// Wire advertisement and byte serving stay in [MessagingService]; this
/// registry centralizes TTL/count eviction, stream leases, delayed source
/// retirement and teardown so no file handle lives only inside an untracked
/// timer.
class _MessagingContentServing {
  _MessagingContentServing(this._owner);

  final MessagingService _owner;

  static const _servingTtl = Duration(minutes: 10);
  static const _sourceRetireGrace = Duration(minutes: 15);
  static const _maxEntries = 256;

  final Map<String, _ServedContent> entries = {};
  final Map<String, int> activeStreams = {};
  final Map<String, List<ServeSource>> retiredAfterStream = {};
  final Map<Timer, ServeSource> _scheduledRetirements = {};

  Future<ServeSource?> Function(String path)? sourceOpener;

  int get count => entries.length;

  bool sameSource(ServeSource left, ServeSource right) =>
      identical(left, right) ||
      (identical(left.read, right.read) && identical(left.close, right.close));

  void retireForContent(String contentId, ServeSource source) {
    if ((activeStreams[contentId] ?? 0) > 0) {
      (retiredAfterStream[contentId] ??= []).add(source);
      return;
    }
    retireLater(source);
  }

  void retireLater(ServeSource source) {
    late final Timer timer;
    timer = Timer(_sourceRetireGrace, () {
      final tracked = _scheduledRetirements.remove(timer);
      if (tracked != null) unawaited(_close(tracked));
    });
    _scheduledRetirements[timer] = source;
  }

  void evict() {
    final now = _owner._now();
    entries.removeWhere((contentId, served) {
      if ((activeStreams[contentId] ?? 0) > 0) return false;
      if (now.difference(served.servedAt) <= _servingTtl) return false;
      if (served.source != null) unawaited(_close(served.source!));
      return true;
    });
    if (entries.length <= _maxEntries) return;
    final byAge = entries.entries.toList()
      ..sort(
        (left, right) => left.value.servedAt.compareTo(right.value.servedAt),
      );
    for (final entry in byAge) {
      if (entries.length <= _maxEntries) break;
      if ((activeStreams[entry.key] ?? 0) > 0) continue;
      if (entry.value.source != null) unawaited(_close(entry.value.source!));
      entries.remove(entry.key);
    }
  }

  bool beginStream(String contentId, int maxActive) {
    final active = activeStreams[contentId] ?? 0;
    if (active >= maxActive) return false;
    activeStreams[contentId] = active + 1;
    return true;
  }

  void endStream(String contentId) {
    final active = (activeStreams[contentId] ?? 0) - 1;
    if (active > 0) {
      activeStreams[contentId] = active;
      return;
    }
    activeStreams.remove(contentId);
    final retired = retiredAfterStream.remove(contentId);
    if (retired != null) {
      for (final source in retired) {
        retireLater(source);
      }
    }
  }

  Future<void> clear() async {
    final sources = Set<ServeSource>.identity();
    for (final served in entries.values) {
      if (served.source != null) sources.add(served.source!);
    }
    for (final retired in retiredAfterStream.values) {
      sources.addAll(retired);
    }
    for (final timer in _scheduledRetirements.keys) {
      timer.cancel();
    }
    sources.addAll(_scheduledRetirements.values);
    _scheduledRetirements.clear();
    entries.clear();
    retiredAfterStream.clear();
    activeStreams.clear();
    await Future.wait([for (final source in sources) _close(source)]);
  }

  Future<void> _close(ServeSource source) async {
    try {
      await source.close();
    } catch (_) {}
  }
}
