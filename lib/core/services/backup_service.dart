import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_db.dart';
import 'backup/backup_exporter.dart';
import 'backup/flutter_backup_importer.dart';
import 'backup/js_backup_importer.dart';
import 'backup/st_backup_importer.dart';
import 'backup/tavo_backup_importer.dart';
import 'image_storage_service.dart';

class BackupService {
  final AppDatabase _db;
  final ImageStorageService _imageStorage;

  BackupService(this._db, ImageStorageService _imageStorage) : _imageStorage = _imageStorage;

  Future<String> exportBackup() => BackupExporter(_db, _imageStorage).export();

  Future<void> importBackup(
    Uint8List bytes, {
    void Function(String stage)? onProgress,
  }) async {
    if (_isZip(bytes)) {
      onProgress?.call('Reading archive...');
      final archive = ZipDecoder().decodeBytes(bytes);
      if (_isTavoArchive(archive)) {
        await TavoBackupImporter(_db, _imageStorage)
            .import(bytes, onProgress: onProgress);
        return;
      }
      if (_isSillyTavernArchive(archive)) {
        await StBackupImporter(_db, _imageStorage)
            .import(bytes, onProgress: onProgress);
        return;
      }
      throw const FormatException(
          'ZIP is neither a Tavo (.tbk) nor SillyTavern backup');
    }

    onProgress?.call('Parsing backup...');
    final jsonString = utf8.decode(bytes, allowMalformed: true);
    final data = await Isolate.run(
      () => jsonDecode(jsonString) as Map<String, dynamic>,
    );
    final isGlazeBackup = data['_isGlazeBackup'] == true ||
        data.containsKey('tables') ||
        data.containsKey('characters');
    if (!isGlazeBackup) {
      throw const FormatException('Not a valid Glaze backup file');
    }

    if (data['_source'] == 'flutter') {
      await FlutterBackupImporter(_db, _imageStorage)
          .import(data, onProgress: onProgress);
    } else {
      await JsBackupImporter(_db, _imageStorage)
          .import(data, onProgress: onProgress);
    }

    await _deleteOrphanedSessions();

    final prefs = await SharedPreferences.getInstance();
    final prefsData = data['preferences'] as Map<String, dynamic>?;
    if (prefsData != null) {
      final themeKeys = prefs.getKeys().where(
          (k) => k.startsWith('gz_theme_') || k.startsWith('glaze_theme_'));
      for (final k in themeKeys) {
        await prefs.remove(k);
      }
      for (final entry in prefsData.entries) {
        final v = entry.value;
        if (v is bool) {
          await prefs.setBool(entry.key, v);
        } else if (v is int) {
          await prefs.setInt(entry.key, v);
        } else if (v is double) {
          await prefs.setDouble(entry.key, v);
        } else if (v is String) {
          await prefs.setString(entry.key, v);
        }
      }
    }

    final lsData = data['localStorage'] as Map<String, dynamic>?;
    if (lsData != null) {
      final personaConnsRaw = lsData['gz_persona_connections'];
      if (personaConnsRaw != null) {
        try {
          final parsed = personaConnsRaw is String
              ? jsonDecode(personaConnsRaw) as Map<String, dynamic>
              : personaConnsRaw as Map<String, dynamic>;
          final conns = <String, dynamic>{
            'character': parsed['character'] ?? <String, dynamic>{},
            'chat': parsed['chat'] ?? <String, dynamic>{},
          };
          await prefs.setString('personaConnections', jsonEncode(conns));
        } catch (_) {}
      }
    }
  }

  bool _isZip(Uint8List bytes) {
    if (bytes.length < 4) return false;
    return bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04;
  }

  bool _isTavoArchive(Archive archive) {
    for (final f in archive.files) {
      if (f.isFile && f.name.toLowerCase().endsWith('data.mdb')) return true;
    }
    return false;
  }

  bool _isSillyTavernArchive(Archive archive) {
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final n = f.name;
      if (n.startsWith('characters/') ||
          n.startsWith('worlds/') ||
          n.startsWith('OpenAI Settings/') ||
          n.startsWith('chats/') ||
          n.toLowerCase().endsWith('settings.json')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _deleteOrphanedSessions() async {
    final charIds =
        (await _db.select(_db.characters).get()).map((r) => r.charId).toSet();
    if (charIds.isEmpty) return;

    final sessions = await _db.select(_db.chatSessions).get();
    final orphanIds = sessions
        .where((s) => !charIds.contains(s.characterId))
        .map((s) => s.sessionId)
        .toList();
    if (orphanIds.isEmpty) return;

    await _db.transaction(() async {
      for (final sid in orphanIds) {
        await (_db.delete(_db.chatSessions)..where((t) => t.sessionId.equals(sid))).go();
        await (_db.delete(_db.memoryBookRows)..where((t) => t.sessionId.equals(sid))).go();
        await (_db.delete(_db.chatSummaries)..where((t) => t.sessionId.equals(sid))).go();
      }
    });
  }
}
