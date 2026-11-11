/// File records share storage with container control files. An archive may
/// carry attachments and content manifests, but never create a master roster
/// (nor future files in that reserved namespace). Identity transfer has its
/// own explicit record and admission rules.
bool isTransferableFileId(String id) =>
    id.isNotEmpty && !id.startsWith('master:');
