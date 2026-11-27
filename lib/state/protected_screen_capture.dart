import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart' show prefsProvider;

const protectedScreenCaptureKey = 'privacy.protected_screen_capture.v1';

final protectedScreenCaptureProvider =
    AsyncNotifierProvider<ProtectedScreenCapturePreference, bool>(
      ProtectedScreenCapturePreference.new,
    );

class ProtectedScreenCapturePreference extends AsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final prefs = await ref.watch(prefsProvider.future);
    return prefs.get(protectedScreenCaptureKey) == true;
  }

  Future<bool> set(bool allowed) async {
    final previous = state.asData;
    final preferences = ref.read(prefsProvider);
    final prefs = preferences.asData?.value;
    if (state.isLoading ||
        preferences.isLoading ||
        previous == null ||
        prefs == null) {
      return false;
    }
    state = const AsyncLoading();
    var saved = false;
    try {
      saved = await prefs.setBool(protectedScreenCaptureKey, allowed);
      return saved;
    } catch (_) {
      return false;
    } finally {
      if (ref.mounted) {
        final current = ref.read(prefsProvider);
        if (!current.isLoading && identical(prefs, current.asData?.value)) {
          state = saved ? AsyncData(allowed) : previous;
        }
      }
    }
  }
}
