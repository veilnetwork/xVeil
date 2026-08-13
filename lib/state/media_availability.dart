import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_ffi.dart';

/// Whether this build can do calls, voice messages and video notes at all.
///
/// The UI half of [VeilMediaNative.available]: widgets watch this and hide the
/// affordance rather than offering a button whose only outcome is a failure —
/// exactly what `transcriptionAvailableProvider` and
/// `translationAvailableProvider` already do for the other two optional
/// natives.
///
/// A separate file from `media_ffi.dart` on purpose: that one is Flutter-free
/// because `lib/state/` is walked by the headless daemon's import graph
/// (`headless_is_flutter_free_test`), and one `flutter_riverpod` import there
/// would stop the daemon compiling. This file is only ever reached from
/// widgets.
///
/// Constant for the process's lifetime — a library that failed to load will not
/// appear later — so there is nothing to invalidate.
final callMediaAvailableProvider = Provider<bool>(
  (ref) => VeilMediaNative.available(),
);
