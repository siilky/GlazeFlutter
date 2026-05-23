import 'dart:convert';
import 'dart:typed_data';

import '../../db/app_db.dart';
import '../image_storage_service.dart';
import 'backup_helpers.dart';

class FlutterBackupImporter extends BackupHelpers {
  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;

  FlutterBackupImporter(this.db, this.imageStorage);

  Future<void> import(
    Map<String, dynamic> data, {
    void Function(String stage)? onProgress,
  }) async {
    final tables = data['tables'] as Map<String, dynamic>?;
    if (tables == null) return;

    // Pre-fetch existing columns for every table so we can filter out
    // columns that no longer exist (e.g. renamed fields like
    // last_scroll_anchor → last_scroll_anchor_json).
    final existingColumns = <String, Set<String>>{};
    final allTableNames = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'drift_%'",
        )
        .get();
    for (final t in allTableNames) {
      final tName = t.read<String>('name');
      final cols =
          await db.customSelect("PRAGMA table_info('$tName')").get();
      existingColumns[tName] = cols.map((c) => c.read<String>('name')).toSet();
    }

    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.transaction(() async {
      for (final entry in tables.entries) {
        final tableName = entry.key;
        final rows = entry.value as List<dynamic>;
        if (rows.isEmpty) continue;

        onProgress?.call('Importing $tableName...');

        final knownCols = existingColumns[tableName];
        if (knownCols == null) continue;

        try {
          await db.customStatement('DELETE FROM $tableName');
        } catch (_) {}

        for (final row in rows) {
          final r = row as Map<String, dynamic>;
          // Only keep columns that actually exist in the current schema.
          final columns =
              r.keys.where((c) => knownCols.contains(c)).toList();
          if (columns.isEmpty) continue;

          final placeholders = columns.map((_) => '?').join(', ');
          final sql =
              'INSERT OR REPLACE INTO $tableName (${columns.join(', ')}) VALUES ($placeholders)';
          final args = <dynamic>[];
          for (final c in columns) {
            final v = r[c];
            if (v is List || v is Map) {
              args.add(jsonEncode(v));
            } else {
              args.add(v);
            }
          }

          try {
            await db.customStatement(sql, args);
          } catch (_) {}
        }
      }
    });
    await db.customStatement('PRAGMA foreign_keys = ON');

    await restoreGalleryImages(data['gallery'] as Map<String, dynamic>?);
    await _restoreAvatars(data['avatars'] as Map<String, dynamic>?);
  }

  Future<void> restoreGalleryImages(Map<String, dynamic>? galleryData) async {
    if (galleryData == null) return;

    for (final entry in galleryData.entries) {
      final charId = entry.key;
      final images = entry.value as List<dynamic>;

      // Rebuild gallery entries with corrected paths for this device.
      final restoredEntries = <Map<String, dynamic>>[];

      for (final img in images) {
        final imgMap = img as Map<String, dynamic>;
        final entryData = imgMap['entry'] as Map<String, dynamic>?;
        final base64Data = imgMap['base64'] as String?;
        if (base64Data == null) continue;

        final ext = extFromEntry(entryData);
        final id = entryData?['id'] as String? ??
            'gal_${DateTime.now().millisecondsSinceEpoch}';

        try {
          final savedPath = await imageStorage.saveBytes(
            base64Decode(base64Data),
            'gallery/$charId',
            id,
            ext,
          );
          // Update the entry with the new absolute path for this device.
          if (entryData != null) {
            restoredEntries.add({...entryData, 'imagePath': savedPath});
          }
        } catch (_) {}
      }

      // Update gallery_json in the DB with the corrected paths.
      if (restoredEntries.isNotEmpty) {
        try {
          await db.customStatement(
            'UPDATE characters SET gallery_json = ? WHERE char_id = ?',
            [jsonEncode(restoredEntries), charId],
          );
        } catch (_) {}
      }
    }
  }

  /// Restores character and persona avatar PNG files from base64 blobs and
  /// updates avatar_path in the DB to the new device-local path.
  /// Expected structure: { "characters": { "<id>": "<base64>" }, "personas": { "<id>": "<base64>" } }
  Future<void> _restoreAvatars(Map<String, dynamic>? avatarsData) async {
    if (avatarsData == null) return;

    final chars = avatarsData['characters'] as Map<String, dynamic>?;
    if (chars != null) {
      for (final e in chars.entries) {
        if (e.value is! String) continue;
        try {
          final bytes = base64Decode(e.value as String);
          final savedPath =
              await imageStorage.saveAvatar(e.key, Uint8List.fromList(bytes));
          await db.customStatement(
            'UPDATE characters SET avatar_path = ? WHERE char_id = ?',
            [savedPath, e.key],
          );
        } catch (_) {}
      }
    }

    final personas = avatarsData['personas'] as Map<String, dynamic>?;
    if (personas != null) {
      for (final e in personas.entries) {
        if (e.value is! String) continue;
        try {
          final bytes = base64Decode(e.value as String);
          final savedPath =
              await imageStorage.saveAvatar(e.key, Uint8List.fromList(bytes));
          await db.customStatement(
            'UPDATE personas SET avatar_path = ? WHERE persona_id = ?',
            [savedPath, e.key],
          );
        } catch (_) {}
      }
    }
  }
}
