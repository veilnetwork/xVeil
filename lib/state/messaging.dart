/// Flutter/Riverpod compatibility facade.
///
/// Runtime-independent messaging lives in [messaging_core.dart]. UI code may
/// keep importing this library; the headless daemon imports the core directly
/// and therefore never loads Flutter or Riverpod.
library;

export 'messaging_core.dart';
export 'messaging_providers.dart';
