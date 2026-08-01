import '../domain/cloud.dart';
import '../state/cloud_service.dart';
import 'api_server.dart';

/// Turns [CloudService] into the plain maps and bytes the REST router serves.
///
/// Kept apart from the router for the same reason [GroupApiAdapter] is: the
/// router should decide what an HTTP request means, not how the cloud spells
/// its own state. It also keeps the wiring honest — everything here is a thin
/// projection, so there is no place for a second, subtly different idea of
/// what a cloud item is.
class CloudApiAdapter {
  const CloudApiAdapter(this._cloud, {required this.loadFile});

  final CloudService _cloud;

  /// Opens content already on this device as a streamable source. The adapter
  /// never reaches for the network itself; see [file]. A source rather than
  /// bytes so a multi-GB item is served range by range instead of being
  /// reassembled in RAM first.
  final Future<ApiBlobSource?> Function(String contentId) loadFile;

  Map<String, dynamic> _item(CloudItem item) => {
    'id': item.id,
    'name': item.name,
    'kind': item.kind.name,
    'revision': item.revision,
    'modifiedAtMs': item.modifiedAtMs,
    if (item.contentId != null) 'contentId': item.contentId,
    'size': item.size,
    if (item.mime != null) 'mime': item.mime,
    if (item.folderId != null) 'folder': item.folderId,
    if (item.thumbContentId != null) 'preview': item.thumbContentId,
    'deleted': item.deleted,
  };

  Future<List<Map<String, dynamic>>> items() async => [
    for (final item in await _cloud.listItems()) _item(item),
  ];

  Future<List<Map<String, dynamic>>> folders() async {
    await _cloud.start();
    return [
      for (final folder in _cloud.listFolders())
        {
          'id': folder.id,
          'name': folder.name,
          'revision': folder.revision,
          if (folder.parentId != null) 'parent': folder.parentId,
        },
    ];
  }

  Future<Map<String, dynamic>> usage() async {
    final usage = await _cloud.usage();
    return {
      'logicalItems': usage.logicalItems,
      'logicalBytes': usage.logicalBytes,
      'localItems': usage.localItems,
      'localBytes': usage.localBytes,
      'indexOnlyItems': usage.indexOnlyItems,
      'devices': [
        for (final device in usage.devices)
          {
            'deviceId': device.deviceId.hex,
            'short': device.deviceId.short,
            'items': device.items,
            'bytes': device.bytes,
            'isSelf': device.isSelf,
          },
      ],
    };
  }

  /// The bytes of one item, pulling them from another device first when this
  /// one is set to keep only the index.
  ///
  /// Returns null when the id is unknown or the content could not be had —
  /// one outcome for both, because a caller that may list the index learns
  /// nothing from the difference and a caller that may not should learn even
  /// less.
  Future<ApiBlobSource?> file(String itemId) async {
    final items = await _cloud.listItems();
    CloudItem? found;
    for (final item in items) {
      if (item.id == itemId) found = item;
    }
    if (found == null || found.deleted || found.contentId == null) return null;
    if (!await _cloud.ensureLocal(found)) return null;
    return loadFile(found.contentId!);
  }

  Future<({Map<String, dynamic>? item, String? error})> saveNote({
    String? id,
    required String title,
    required String body,
    String? folderId,
  }) async {
    try {
      final saved = await _cloud.saveTextNote(
        itemId: id,
        title: title,
        body: body,
        folderId: folderId,
      );
      return (item: _item(saved), error: null);
    } on CloudEditConflict {
      // Someone else moved the note on while this request was in flight.
      // Telling the caller to re-read is the whole answer; the current text is
      // one GET away and inventing a merge here would be a second idea of what
      // a note is.
      return (item: null, error: 'the note changed elsewhere — re-read it');
    } catch (error) {
      return (item: null, error: '$error');
    }
  }

  Future<String?> deleteItem(String id) async {
    try {
      await _cloud.deleteItem(id);
      return null;
    } catch (error) {
      return '$error';
    }
  }
}
