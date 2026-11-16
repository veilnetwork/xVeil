/// Route new identities through the three-mode profile store by default.
///
/// Existing hidden containers keep their original backend; enabling the router
/// does not migrate, enumerate or compact their unknown hidden spaces. The
/// compile-time opt-out is retained for isolated legacy regression controls.
const managedStorageEnabled = bool.fromEnvironment(
  'XVEIL_MANAGED_STORAGE',
  defaultValue: true,
);
