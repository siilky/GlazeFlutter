import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../core/models/preset.dart';
import '../../core/state/db_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import 'preset_editor_screen.dart';

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
    ref.invalidateSelf();
  }
}

class PresetListScreen extends ConsumerWidget {
  const PresetListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final presets = ref.watch(presetListProvider);

    return GlazeScaffold(
      title: 'Presets',
      onBack: () => context.go('/tools'),
      actions: [
        IconButton(
          icon: const Icon(Icons.file_upload),
          color: AppColors.accent,
          onPressed: () => _importPreset(context, ref),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          color: AppColors.accent,
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const PresetEditorScreen())),
        ),
      ],
      body: presets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => list.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.tune, size: 64, color: AppColors.textSecondary),
                    const SizedBox(height: 16),
                    const Text('No presets yet'),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const PresetEditorScreen(),
                        ),
                      ),
                      child: const Text('Create Preset'),
                    ),
                  ],
                ),
              )
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) => _PresetTile(preset: list[i]),
              ),
      ),
    );
  }

  Future<void> _importPreset(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;

    final picked = result.files.first;

    String jsonString;
    if (picked.bytes != null) {
      jsonString = utf8.decode(picked.bytes!);
    } else if (picked.path != null && picked.path!.isNotEmpty) {
      jsonString = File(picked.path!).readAsStringSync();
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Cannot read file')));
      }
      return;
    }

    try {
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final preset = _parseSillyTavernPreset(json, picked.name);
      await ref.read(presetListProvider.notifier).add(preset);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Imported "${preset.name}" (${preset.blocks.length} blocks)',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  static const _stBlockIds = <String, String>{
    'chatHistory': 'chat_history',
    'charDescription': 'char_card',
    'charPersonality': 'char_personality',
    'personaDescription': 'user_persona',
    'dialogueExamples': 'example_dialogue',
    'worldInfoBefore': 'worldInfoBefore',
    'worldInfoAfter': 'worldInfoAfter',
    'scenario': 'scenario',
    'main': 'main',
    'nsfw': 'nsfw',
  };

  static const _mandatoryBlockIds = <String>{
    'chat_history', 'char_card', 'char_personality', 'user_persona',
    'example_dialogue', 'worldInfoBefore', 'worldInfoAfter', 'scenario',
    'main', 'nsfw',
  };

  static const _blockNameToId = <String, String>{
    'Chat History': 'chat_history',
    'charDescription': 'char_card',
    'Character Description': 'char_card',
    'charPersonality': 'char_personality',
    'Character Personality': 'char_personality',
    'personaDescription': 'user_persona',
    'User Persona': 'user_persona',
    'dialogueExamples': 'example_dialogue',
    'Dialogue Examples': 'example_dialogue',
  };

  String _normalizeImportedBlockId(String rawId, String name) {
    if (_stBlockIds.containsKey(rawId)) return _stBlockIds[rawId]!;
    if (_blockNameToId.containsKey(name)) return _blockNameToId[name]!;
    return rawId;
  }

  Preset _parseSillyTavernPreset(Map<String, dynamic> json, String fileName) {
    final blocks = <PresetBlock>[];
    final regexes = <PresetRegex>[];

    final promptsList = json['prompts'] as List<dynamic>? ?? [];
    final promptsById = <String, Map<String, dynamic>>{};
    for (final p in promptsList) {
      final id = (p as Map<String, dynamic>)['identifier'] as String?;
      if (id != null) promptsById[id] = p;
    }

    List<Map<String, dynamic>> orderList = [];
    if (json['prompt_order'] is List) {
      final promptOrder = json['prompt_order'] as List<dynamic>;
      Map<String, dynamic>? preferredOrder;
      for (final o in promptOrder) {
        if (o is! Map<String, dynamic>) continue;
        final cid = o['character_id'];
        if (cid == 100001 && (o['order'] as List?)?.isNotEmpty == true) {
          preferredOrder = o;
          break;
        }
      }
      Map<String, dynamic> bestOrder = preferredOrder ?? promptOrder.fold<Map<String, dynamic>?>(
        null,
        (prev, current) {
          if (current is! Map<String, dynamic>) return prev;
          final prevLen = (prev?['order'] as List?)?.length ?? 0;
          final currentLen = (current['order'] as List?)?.length ?? 0;
          return currentLen > prevLen ? current : prev;
        },
      ) ?? {};
      final order = bestOrder['order'] as List<dynamic>? ?? [];
      for (final item in order) {
        if (item is Map<String, dynamic>) orderList.add(item);
      }
    }

    if (orderList.isEmpty) {
      orderList = promptsList.map((p) {
        final pm = p as Map<String, dynamic>;
        return {
          'identifier': pm['identifier'],
          'enabled': pm['enabled'] ?? true,
        };
      }).toList().cast<Map<String, dynamic>>();
    }

    final usedIdentifiers = <String>{};

    for (final item in orderList) {
      final identifier = item['identifier'] as String?;
      if (identifier == null) continue;
      final p = promptsById[identifier];
      if (p == null) continue;

      usedIdentifiers.add(identifier);

      final blockName = (p['name'] as String?) ?? identifier;
      final normalizedId = _normalizeImportedBlockId(identifier, blockName);
      final isMandatory = _mandatoryBlockIds.contains(normalizedId);
      final isEnabled = item['enabled'] as bool? ?? p['enabled'] as bool? ?? true;

      String insertionMode;
      int? depth;
      if (normalizedId == 'chat_history') {
        insertionMode = 'relative';
      } else if (p['injection_position'] == 1) {
        insertionMode = 'depth';
        depth = p['injection_depth'] as int? ?? 4;
      } else {
        insertionMode = 'relative';
      }

      blocks.add(
        PresetBlock(
          id: normalizedId,
          name: blockName,
          role: (p['role'] as String?) ?? 'system',
          content: isMandatory ? '' : ((p['content'] as String?) ?? ''),
          enabled: isEnabled,
          insertionMode: insertionMode,
          depth: depth,
        ),
      );
    }

    for (final p in promptsList) {
      final pm = p as Map<String, dynamic>;
      final identifier = pm['identifier'] as String?;
      if (identifier == null || usedIdentifiers.contains(identifier)) continue;
      usedIdentifiers.add(identifier);

      final blockName = (pm['name'] as String?) ?? identifier;
      final normalizedId = _normalizeImportedBlockId(identifier, blockName);
      final isMandatory = _mandatoryBlockIds.contains(normalizedId);
      final isEnabled = pm['enabled'] as bool? ?? true;

      String insertionMode;
      int? depth;
      if (normalizedId == 'chat_history') {
        insertionMode = 'relative';
      } else if (pm['injection_position'] == 1) {
        insertionMode = 'depth';
        depth = pm['injection_depth'] as int? ?? 4;
      } else {
        insertionMode = 'relative';
      }

      blocks.add(
        PresetBlock(
          id: normalizedId,
          name: blockName,
          role: (pm['role'] as String?) ?? 'system',
          content: isMandatory ? '' : ((pm['content'] as String?) ?? ''),
          enabled: isEnabled,
          insertionMode: insertionMode,
          depth: depth,
        ),
      );
    }

    final stRegexes = json['regexes'] as List<dynamic>?;
    final extRegexes =
        (json['extensions'] as Map<String, dynamic>?)?['regex_scripts']
            as List<dynamic>?;
    final regexSource = extRegexes ?? stRegexes;
    if (regexSource != null) {
      for (int i = 0; i < regexSource.length; i++) {
        final r = regexSource[i] as Map<String, dynamic>;
        regexes.add(
          PresetRegex(
            id: r['id'] as String? ?? 'imported_r$i',
            name: (r['scriptName'] as String?) ?? 'Regex $i',
            regex: (r['findRegex'] as String?) ?? '',
            replacement: (r['replaceString'] as String?) ?? '',
            placement:
                (r['placement'] as List<dynamic>?)
                    ?.map((e) => e as int)
                    .toList() ??
                [1, 2],
            disabled:
                !(r['isEnabled'] as bool? ??
                    !((r['disabled'] as bool?) ?? false)),
            ephemerality:
                (r['ephemerality'] as List<dynamic>?)
                    ?.map((e) => e as int)
                    .toList() ??
                [1, 2],
            minDepth: r['minDepth'] as int?,
            maxDepth: r['maxDepth'] as int?,
          ),
        );
      }
    }

    return Preset(
      id: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
      name: (json['name'] as String?) ?? fileName.replaceAll('.json', ''),
      blocks: blocks,
      regexes: regexes,
      reasoningEnabled:
          json['reasoning'] as bool? ??
          json['reasoning_enabled'] as bool? ??
          false,
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }
}

class _PresetTile extends ConsumerWidget {
  final Preset preset;
  const _PresetTile({required this.preset});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.tune),
      title: Text(preset.name),
      subtitle: Text(
        '${preset.blocks.length} blocks · ${preset.regexes.length} regex',
        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.upload_file, size: 20),
            tooltip: 'Export',
            onPressed: () => _exportPreset(ref, context, preset),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PresetEditorScreen(preset: preset),
                  ),
                );
              } else if (value == 'duplicate') {
                final dup = preset.copyWith(
                  id: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
                  name: '${preset.name} (copy)',
                );
                ref.read(presetListProvider.notifier).add(dup);
              } else if (value == 'export') {
                _exportPreset(ref, context, preset);
              } else if (value == 'delete') {
                ref.read(presetListProvider.notifier).remove(preset.id);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit')),
              const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
              const PopupMenuItem(value: 'export', child: Text('Export')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  void _exportPreset(WidgetRef ref, BuildContext context, Preset preset) async {
    try {
      final exportJson = <String, dynamic>{
        'name': preset.name,
        'prompts': preset.blocks
            .map(
              (b) => <String, dynamic>{
                'name': b.name,
                'role': b.role,
                'content': b.content,
                'enabled': b.enabled,
                'insertion_mode': b.insertionMode,
                if (b.depth != null) 'depth': b.depth,
              },
            )
            .toList(),
        'regexes': preset.regexes
            .map(
              (r) => <String, dynamic>{
                'scriptName': r.name,
                'findRegex': r.regex,
                'replaceString': r.replacement,
                'placement': r.placement,
                'isEnabled': !r.disabled,
              },
            )
            .toList(),
        'reasoning': preset.reasoningEnabled,
      };

      final encoded = const JsonEncoder.withIndent('  ').convert(exportJson);

      final safeName = preset.name.replaceAll(RegExp(r'[^\w\s-]'), '').trim();
      final desktop = Platform.environment['USERPROFILE'] ?? '.';
      final exportDir = Directory(p.join(desktop, 'Desktop'));
      final file = File(p.join(exportDir.path, '$safeName.json'));
      file.writeAsStringSync(encoded);

      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Export Complete'),
            content: Text('Saved to:\n${file.path}'),
            actions: [
              TextButton(
                onPressed: () {
                  Process.run('explorer', ['/select,', file.path]);
                  Navigator.pop(ctx);
                },
                child: const Text('Open File Location'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Export Failed'),
            content: Text('$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }
}
