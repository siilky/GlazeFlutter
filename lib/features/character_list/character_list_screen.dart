import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/character.dart';
import '../../core/state/character_provider.dart';
import '../../core/state/db_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import 'widgets/widgets.dart';

class CharacterListScreen extends ConsumerStatefulWidget {
  const CharacterListScreen({super.key});

  @override
  ConsumerState<CharacterListScreen> createState() =>
      _CharacterListScreenState();
}

class _CharacterListScreenState extends ConsumerState<CharacterListScreen> {
  SortType _sortBy = SortType.date;
  SortDir _sortDir = SortDir.desc;
  bool _showCatalog = false;

  @override
  Widget build(BuildContext context) {
    final characters = ref.watch(charactersProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: GlazeAppBar(
                title: 'Characters',
                actions: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      icon: const Icon(Icons.search_rounded, size: 22),
                      color: AppColors.accent,
                      onPressed: () {/* TODO: search */},
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                Expanded(child: _TabsRow(
                  showCatalog: _showCatalog,
                  onTabChanged: (v) => setState(() => _showCatalog = v),
                )),
                const SizedBox(width: 12),
                if (!_showCatalog)
                  GlazePillButton(
                    icon: Icons.add_rounded,
                    label: 'Add',
                    onTap: () => _importCharacter(context, ref),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _showCatalog
                ? const Center(
                    child: Text(
                      'Catalog — coming soon',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : characters.when(
                    loading: () => const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                      ),
                    ),
                    error: (e, _) => Center(
                      child: Text('Error: $e',
                          style: const TextStyle(
                              color: AppColors.textSecondary)),
                    ),
                    data: (chars) {
                      if (chars.isEmpty) {
                        return EmptyCharacterState(
                          onImport: () => _importCharacter(context, ref),
                        );
                      }
                      final sorted = _sortChars(chars);
                      return CharacterGrid(
                        characters: sorted,
                        sortBy: _sortBy,
                        sortDir: _sortDir,
                        onSortDirToggle: () => setState(() {
                          _sortDir = _sortDir == SortDir.asc
                              ? SortDir.desc
                              : SortDir.asc;
                        }),
                        onSortTypeChanged: (t) =>
                            setState(() => _sortBy = t),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  List<Character> _sortChars(List<Character> chars) {
    final list = List<Character>.of(chars);
    list.sort((a, b) {
      int cmp;
      switch (_sortBy) {
        case SortType.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SortType.date:
          cmp = a.updatedAt.compareTo(b.updatedAt);
      }
      return _sortDir == SortDir.desc ? -cmp : cmp;
    });
    return list;
  }

  Future<void> _importCharacter(BuildContext context, WidgetRef ref) async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'json', 'charx', 'zip'],
        allowMultiple: true,
      );
      if (result == null || result.files.isEmpty) return;

      final importer = ref.read(characterImporterProvider);
      final notifier = ref.read(charactersProvider.notifier);
      int imported = 0;
      String? lastError;

      for (final file in result.files) {
        try {
          if (file.bytes != null) {
            final r = await importer.importFromBytes(file.bytes!, file.name);
            await notifier.add(r.character);
            imported++;
          } else if (file.path != null) {
            final r = await importer.importFromFile(file.path!);
            await notifier.add(r.character);
            imported++;
          }
        } catch (e) {
          lastError = 'Failed to import ${file.name}: $e';
        }
      }

      if (!context.mounted) return;
      if (imported > 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('Imported $imported character${imported > 1 ? 's' : ''}'),
          backgroundColor: AppColors.accent,
        ));
      } else if (lastError != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(lastError)));
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}

class _TabsRow extends StatelessWidget {
  final bool showCatalog;
  final ValueChanged<bool> onTabChanged;

  const _TabsRow({required this.showCatalog, required this.onTabChanged});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final w = constraints.maxWidth;
      return Container(
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              left: showCatalog ? w / 2 : 0,
              top: 0,
              bottom: 0,
              width: w / 2,
              child: Container(
                margin: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            Row(
              children: [
                _Tab(
                  label: 'My Characters',
                  icon: Icons.person_rounded,
                  isActive: !showCatalog,
                  onTap: () => onTabChanged(false),
                ),
                _Tab(
                  label: 'Catalog',
                  icon: Icons.public_rounded,
                  isActive: showCatalog,
                  onTap: () => onTabChanged(true),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isActive;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    required this.icon,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.accent : AppColors.inactiveTab;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
