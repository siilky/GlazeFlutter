import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/preset.dart';
import '../../core/state/db_provider.dart';
import '../cloud_sync/services/sync_deletion_tracker.dart';

final presetListProvider =
    AsyncNotifierProvider<PresetListNotifier, List<Preset>>(
      PresetListNotifier.new,
    );

class PresetListNotifier extends AsyncNotifier<List<Preset>> {
  @override
  Future<List<Preset>> build() async {
    return ref.watch(presetRepoProvider).getAll();
  }

  Future<void> add(Preset preset) async {
    await ref.read(presetRepoProvider).put(preset);
    ref.invalidateSelf();
  }

  Future<void> remove(String id) async {
    await ref.read(presetRepoProvider).delete(id);
    await SyncDeletionTracker.record('theme_presets', id);
    ref.invalidateSelf();
  }
}
