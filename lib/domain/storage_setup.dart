/// Protected, per-store setup marker. Never place this in the public catalog:
/// it distinguishes a pending master from an empty legacy identity space.
const kPendingMasterSetupSetting = 'storage.pending_master.v1';

/// Only an absent marker or explicit completion permits ordinary use. Unknown
/// nonempty stages must not turn partially published rosters into live masters.
bool masterSetupIsPending(String? stage) =>
    stage != null && stage.isNotEmpty && stage != '0';
