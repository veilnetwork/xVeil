import 'package:xveil/data/storage/async_kv_log_store.dart';
import 'package:xveil/data/storage/fake_kv_log_store.dart';
import 'package:xveil/data/storage/hidden_volume_storage.dart';
import 'support/outbox_replacement_cases.dart';

void main() {
  outboxReplacementCases(
    open: (faults) async {
      final raw = FakeKvLogStore();
      final storage = HiddenVolumeStorage.async(
        ({required password, required create}) async =>
            ReplacementStore(SyncWrappedAsyncKvLogStore(raw), faults),
      );
      await storage.open(password: 'fixture');
      return storage;
    },
  );
}
