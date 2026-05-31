import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/preset.dart';
import '../../../core/services/file_export_service.dart';
import '../../../core/state/global_regex_provider.dart';
import '../../../core/utils/id_generator.dart';
import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../../../shared/widgets/glaze_toast.dart';
import '../../../shared/widgets/sheet_view.dart';

/// Full regex manager sheet (list + inline editor) shown from the preset editor.
///
/// Displays both the preset's regexes and global regexes, matching the
/// RegexSheet.vue design. Shown via [showModalBottomSheet] — not [GlazeBottomSheet].
class RegexSheet extends ConsumerStatefulWidget {
  final List<PresetRegex> regexes;
  final ValueChanged<List<PresetRegex>> onChanged;
  final String? presetName;

  const RegexSheet({
    super.key,
    required this.regexes,
    required this.onChanged,
    this.presetName,
  });

  @override
  ConsumerState<RegexSheet> createState() => _RegexSheetState();
}

class _RegexSheetState extends ConsumerState<RegexSheet> {
  late List<PresetRegex> _presetRegexes = List.from(widget.regexes);
  String _view = 'list';
  PresetRegex? _activeScript;
  bool _isPresetScript = false;
  Timer? _globalSaveTimer;

  @override
  void didUpdateWidget(RegexSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_view == 'list' && !identical(oldWidget.regexes, widget.regexes)) {
      _presetRegexes = List.from(widget.regexes);
    }
  }

  @override
  void dispose() {
    _globalSaveTimer?.cancel();
    super.dispose();
  }

  // ── Navigation ───────────────────────────────────────────────────────────────

  void _selectScript(PresetRegex script, {required bool isPreset}) {
    setState(() {
      _activeScript = script;
      _isPresetScript = isPreset;
      _view = 'edit';
    });
  }

  void _goBack() {
    _globalSaveTimer?.cancel();
    setState(() {
      _view = 'list';
      _activeScript = null;
      _isPresetScript = false;
    });
  }

  // ── Script changes ────────────────────────────────────────────────────────────

  void _onScriptChanged(PresetRegex updated) {
    setState(() => _activeScript = updated);
    if (_isPresetScript) {
      final idx = _presetRegexes.indexWhere((r) => r.id == updated.id);
      if (idx >= 0) {
        setState(() => _presetRegexes = List.from(_presetRegexes)..[idx] = updated);
        widget.onChanged(_presetRegexes);
      }
    } else {
      _globalSaveTimer?.cancel();
      _globalSaveTimer = Timer(const Duration(milliseconds: 500), () async {
        if (mounted) await ref.read(globalRegexProvider.notifier).updateRegex(updated);
      });
    }
  }

  void _togglePreset(PresetRegex script, bool enabled) {
    final updated = script.copyWith(disabled: !enabled);
    final idx = _presetRegexes.indexWhere((r) => r.id == script.id);
    if (idx < 0) return;
    setState(() => _presetRegexes = List.from(_presetRegexes)..[idx] = updated);
    widget.onChanged(_presetRegexes);
  }

  void _deletePreset(PresetRegex script) {
    setState(() => _presetRegexes = _presetRegexes.where((r) => r.id != script.id).toList());
    widget.onChanged(_presetRegexes);
  }

  void _addPresetScript() {
    final newScript = PresetRegex(id: generateId(), name: 'New Script', regex: '');
    setState(() => _presetRegexes = [..._presetRegexes, newScript]);
    widget.onChanged(_presetRegexes);
    _selectScript(newScript, isPreset: true);
  }

  void _addGlobalScript() {
    final newScript = PresetRegex(id: generateId(), name: 'New Global Script', regex: '');
    ref.read(globalRegexProvider.notifier).addRegex(newScript);
    _selectScript(newScript, isPreset: false);
  }

  // ── Menus ─────────────────────────────────────────────────────────────────────

  void _showScriptMenu(BuildContext context, PresetRegex script, bool isPreset) {
    GlazeBottomSheet.show<void>(
      context,
      title: script.name,
      items: [
        BottomSheetItem(
          icon: Icons.download_outlined,
          label: 'Export',
          onTap: () async {
            Navigator.of(context, rootNavigator: true).pop();
            await _exportScript(context, script);
          },
        ),
        BottomSheetItem(
          icon: Icons.delete_outline,
          iconColor: const Color(0xFFFF4444),
          label: 'Delete',
          isDestructive: true,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            if (isPreset) {
              _deletePreset(script);
            } else {
              ref.read(globalRegexProvider.notifier).removeRegex(script.id);
            }
          },
        ),
      ],
    );
  }

  void _showAddMenu(BuildContext context) {
    GlazeBottomSheet.show<void>(
      context,
      title: 'Regex Scripts',
      items: [
        BottomSheetItem(
          icon: Icons.label_outline,
          label: 'Add to Preset',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showAddDestinationMenu(context, toPreset: true);
          },
        ),
        BottomSheetItem(
          icon: Icons.public,
          label: 'Add Globally',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _showAddDestinationMenu(context, toPreset: false);
          },
        ),
      ],
    );
  }

  void _showAddDestinationMenu(BuildContext context, {required bool toPreset}) {
    GlazeBottomSheet.show<void>(
      context,
      title: toPreset ? (widget.presetName ?? 'Active Preset') : 'Global Regexes',
      items: [
        BottomSheetItem(
          icon: Icons.add,
          label: 'Create New',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            if (toPreset) {
              _addPresetScript();
            } else {
              _addGlobalScript();
            }
          },
        ),
        BottomSheetItem(
          icon: Icons.upload_file_outlined,
          label: 'Import from File',
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _importRegex(context, toPreset: toPreset);
          },
        ),
      ],
    );
  }

  // ── Export / Import ───────────────────────────────────────────────────────────

  Future<void> _exportScript(BuildContext context, PresetRegex script) async {
    final json = const JsonEncoder.withIndent('  ').convert(script.toJson());
    final safe = script.name.replaceAll(RegExp(r'[^\w\-]'), '_');
    try {
      await FileExportService.export(data: json, filename: 'regex-$safe.json', subfolder: 'regexes');
      if (context.mounted) GlazeToast.show(context, 'Exported');
    } catch (e) {
      if (context.mounted) GlazeToast.error(context, 'Export failed: ', e);
    }
  }

  Future<void> _importRegex(BuildContext context, {required bool toPreset}) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : ['json', 'zip'],
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {}
    if (result == null || result.files.isEmpty) return;

    try {
      final List<dynamic> combinedRaw = [];
      for (final picked in result.files) {
        late Uint8List bytes;
        if (picked.bytes != null && picked.bytes!.isNotEmpty) {
          bytes = picked.bytes!;
        } else if (picked.path != null && picked.path!.isNotEmpty) {
          bytes = await File(picked.path!).readAsBytes();
        } else {
          continue;
        }
        if (picked.name.toLowerCase().endsWith('.zip')) {
          final archive = ZipDecoder().decodeBytes(bytes);
          for (final entry in archive) {
            if (!entry.isFile || !entry.name.toLowerCase().endsWith('.json')) continue;
            _appendFromJson(utf8.decode(entry.content as List<int>), combinedRaw);
          }
        } else {
          _appendFromJson(utf8.decode(bytes), combinedRaw);
        }
      }

      if (combinedRaw.isEmpty) {
        if (context.mounted) GlazeToast.show(context, 'No regex scripts found');
        return;
      }

      if (toPreset) {
        final newRegexes = _normalizeRawRegexList(combinedRaw);
        setState(() => _presetRegexes = [..._presetRegexes, ...newRegexes]);
        widget.onChanged(_presetRegexes);
        if (context.mounted) GlazeToast.show(context, 'Imported ${newRegexes.length} script(s)');
      } else {
        await ref.read(globalRegexProvider.notifier).importFromJsBackup(combinedRaw);
        if (context.mounted) GlazeToast.show(context, 'Imported ${combinedRaw.length} script(s) globally');
      }
    } catch (e) {
      if (context.mounted) GlazeToast.error(context, 'Import failed: ', e);
    }
  }

  void _appendFromJson(String jsonStr, List<dynamic> out) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        out.addAll(decoded);
      } else if (decoded is Map<String, dynamic>) {
        out.add(decoded);
      }
    } catch (_) {}
  }

  List<PresetRegex> _normalizeRawRegexList(List<dynamic> rawList) {
    final result = <PresetRegex>[];
    for (final r in rawList) {
      if (r is! Map<String, dynamic>) continue;
      final m = normalizeJsGlobalRegex(Map<String, dynamic>.from(r));
      if (!m.containsKey('id')) m['id'] = generateId();
      if (r['isEnabled'] is bool) m['disabled'] = !(r['isEnabled'] as bool);
      try { result.add(PresetRegex.fromJson(m)); } catch (_) {}
    }
    return result;
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final globalRegexes = ref.watch(globalRegexProvider).valueOrNull ?? <PresetRegex>[];
    final isEdit = _view == 'edit';

    return SheetView(
      title: isEdit ? 'Regex Editor' : 'Regex Scripts',
      showBack: isEdit,
      onBack: isEdit ? _goBack : null,
      body: isEdit && _activeScript != null
          ? _RegexEditView(
              key: ValueKey(_activeScript!.id),
              script: _activeScript!,
              onChanged: _onScriptChanged,
            )
          : _buildListView(context, globalRegexes),
      floatingActionButton: isEdit
          ? null
          : FloatingActionButton.small(
              onPressed: () => _showAddMenu(context),
              backgroundColor: context.cs.primary,
              foregroundColor: Colors.black,
              child: const Icon(Icons.add),
            ),
    );
  }

  Widget _buildListView(BuildContext context, List<PresetRegex> globalRegexes) {
    return Builder(
      builder: (innerContext) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16).add(
          EdgeInsets.only(
            top: MediaQuery.paddingOf(innerContext).top,
            bottom: MediaQuery.paddingOf(innerContext).bottom,
          ),
        ),
        children: [
          if (_presetRegexes.isNotEmpty) ...[
            const _SectionTitle('Preset Regexes'),
            if (widget.presetName != null)
              _PresetNameChip(name: widget.presetName!),
            for (final r in _presetRegexes)
              _ScriptListItem(
                script: r,
                onTap: () => _selectScript(r, isPreset: true),
                onToggle: (v) => _togglePreset(r, v),
                onMore: () => _showScriptMenu(innerContext, r, true),
              ),
            const SizedBox(height: 16),
          ],
          const _SectionTitle('Global Regexes'),
          if (globalRegexes.isEmpty)
            const _EmptyState()
          else
            for (final r in globalRegexes)
              _ScriptListItem(
                script: r,
                onTap: () => _selectScript(r, isPreset: false),
                onToggle: (v) => ref.read(globalRegexProvider.notifier).updateRegex(r.copyWith(disabled: !v)),
                onMore: () => _showScriptMenu(innerContext, r, false),
              ),
          const SizedBox(height: 80),
        ],
      ));
  }
}

// ── List UI widgets ─────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.cs.onSurfaceVariant,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _PresetNameChip extends StatelessWidget {
  final String name;
  const _PresetNameChip({required this.name});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 6, 12, 6),
        decoration: BoxDecoration(
          color: context.cs.primary.withValues(alpha: 0.12),
          border: Border.all(color: context.cs.primary.withValues(alpha: 0.25)),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined, size: 14, color: context.cs.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                name,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.cs.primary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScriptListItem extends StatelessWidget {
  final PresetRegex script;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onMore;

  const _ScriptListItem({
    required this.script,
    required this.onTap,
    required this.onToggle,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        script.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: script.disabled ? context.cs.onSurfaceVariant : context.cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (script.regex.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          script.regex,
                          style: TextStyle(fontSize: 13, color: context.cs.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Switch(
                  value: !script.disabled,
                  onChanged: onToggle,
                  activeTrackColor: context.cs.primary,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onMore,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
                    child: Icon(Icons.more_vert, size: 20, color: context.cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text('No scripts', style: TextStyle(color: context.cs.onSurfaceVariant)),
      ),
    );
  }
}

// ── Edit view ───────────────────────────────────────────────────────────────────

class _RegexEditView extends StatefulWidget {
  final PresetRegex script;
  final ValueChanged<PresetRegex> onChanged;

  const _RegexEditView({super.key, required this.script, required this.onChanged});

  @override
  State<_RegexEditView> createState() => _RegexEditViewState();
}

class _RegexEditViewState extends State<_RegexEditView> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _regexCtrl;
  late final TextEditingController _replacementCtrl;
  late final TextEditingController _trimOutCtrl;
  late final TextEditingController _minDepthCtrl;
  late final TextEditingController _maxDepthCtrl;

  @override
  void initState() {
    super.initState();
    final s = widget.script;
    _nameCtrl = TextEditingController(text: s.name);
    _regexCtrl = TextEditingController(text: s.regex);
    _replacementCtrl = TextEditingController(text: s.replacement);
    _trimOutCtrl = TextEditingController(text: s.trimOut);
    _minDepthCtrl = TextEditingController(text: s.minDepth?.toString() ?? '');
    _maxDepthCtrl = TextEditingController(text: s.maxDepth?.toString() ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _regexCtrl.dispose();
    _replacementCtrl.dispose();
    _trimOutCtrl.dispose();
    _minDepthCtrl.dispose();
    _maxDepthCtrl.dispose();
    super.dispose();
  }

  void _update(PresetRegex updated) => widget.onChanged(updated);

  void _openMacroSelector() {
    const options = [
      ('0', "Don't substitute"),
      ('1', 'Substitute raw'),
      ('2', 'Substitute escaped'),
    ];
    GlazeBottomSheet.show<void>(
      context,
      title: 'Macros in Find Regex',
      items: options.map((o) {
        return BottomSheetItem(
          label: o.$2,
          icon: widget.script.macroRules == o.$1 ? Icons.check : null,
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            _update(widget.script.copyWith(macroRules: o.$1));
          },
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.script;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 80).add(
        EdgeInsets.only(
          top: MediaQuery.paddingOf(context).top,
          bottom: MediaQuery.paddingOf(context).bottom,
        ),
      ),
      children: [
        _MenuGroup(
          title: 'Script Settings',
          children: [
            _SettingsTextField(label: 'Script Name', controller: _nameCtrl, onChanged: (v) => _update(s.copyWith(name: v))),
            _SettingsTextField(label: 'Find Regex', controller: _regexCtrl, onChanged: (v) => _update(s.copyWith(regex: v))),
            _SettingsTextField(label: 'Replace With', controller: _replacementCtrl, onChanged: (v) => _update(s.copyWith(replacement: v)), maxLines: 3),
            _SettingsTextField(label: 'Trim Out', controller: _trimOutCtrl, onChanged: (v) => _update(s.copyWith(trimOut: v)), maxLines: 2),
          ],
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 500;
            final col1 = _buildCol1(s);
            final col2 = _buildCol2(context, s);
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [Expanded(child: col1), const SizedBox(width: 12), Expanded(child: col2)],
              );
            }
            return Column(children: [col1, const SizedBox(height: 12), col2]);
          },
        ),
      ],
    );
  }

  Widget _buildCol1(PresetRegex s) {
    const placements = [
      (1, 'User Input'),
      (2, 'AI Output'),
      (3, 'Slash Commands'),
      (5, 'World Info'),
      (6, 'Reasoning'),
    ];
    return Column(
      children: [
        _MenuGroup(
          title: 'Affects',
          compact: true,
          children: placements.map((opt) {
            return _CheckboxOption(
              label: opt.$2,
              value: s.placement.contains(opt.$1),
              onChanged: (v) {
                final list = List<int>.from(s.placement);
                v ? list.add(opt.$1) : list.remove(opt.$1);
                _update(s.copyWith(placement: list));
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _DepthInput(label: 'Min Depth', controller: _minDepthCtrl, onChanged: (v) => _update(s.copyWith(minDepth: v)))),
            const SizedBox(width: 12),
            Expanded(child: _DepthInput(label: 'Max Depth', controller: _maxDepthCtrl, onChanged: (v) => _update(s.copyWith(maxDepth: v)))),
          ],
        ),
      ],
    );
  }

  Widget _buildCol2(BuildContext context, PresetRegex s) {
    const ephemeralities = [
      (1, 'Alter Chat Display'),
      (2, 'Alter Outgoing Prompt'),
    ];
    final macroLabel = switch (s.macroRules) {
      '1' => 'Substitute raw',
      '2' => 'Substitute escaped',
      _ => "Don't substitute",
    };
    return Column(
      children: [
        _MenuGroup(
          title: 'Other Options',
          compact: true,
          children: [
            _CheckboxOption(label: 'Run On Edit', value: s.runOnEdit, onChanged: (v) => _update(s.copyWith(runOnEdit: v))),
          ],
        ),
        const SizedBox(height: 12),
        _MenuGroup(
          title: 'Macros in Find Regex',
          compact: true,
          children: [_MacroSelector(label: macroLabel, onTap: _openMacroSelector)],
        ),
        const SizedBox(height: 12),
        _MenuGroup(
          title: 'Ephemerality',
          compact: true,
          children: ephemeralities.map((opt) {
            return _CheckboxOption(
              label: opt.$2,
              value: s.ephemerality.contains(opt.$1),
              onChanged: (v) {
                final list = List<int>.from(s.ephemerality);
                v ? list.add(opt.$1) : list.remove(opt.$1);
                _update(s.copyWith(ephemerality: list));
              },
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── Edit sub-widgets ─────────────────────────────────────────────────────────────

class _MenuGroup extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final bool compact;

  const _MenuGroup({required this.title, required this.children, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, compact ? 8 : 12, 16, compact ? 4 : 8),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: context.cs.onSurfaceVariant, letterSpacing: 0.6),
            ),
          ),
          Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          for (int i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, color: Colors.white.withValues(alpha: 0.04)),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _SettingsTextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final int maxLines;

  const _SettingsTextField({required this.label, required this.controller, this.onChanged, this.maxLines = 1});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.cs.onSurfaceVariant)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            onChanged: onChanged,
            maxLines: maxLines,
            style: const TextStyle(fontSize: 15),
            decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
          ),
        ],
      ),
    );
  }
}

class _CheckboxOption extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _CheckboxOption({required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 22, height: 22,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                activeColor: context.cs.primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 12),
            Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class _DepthInput extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final ValueChanged<int?> onChanged;

  const _DepthInput({required this.label, required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.cs.onSurfaceVariant)),
          const SizedBox(height: 4),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 15),
            onChanged: (v) => onChanged(int.tryParse(v)),
            decoration: InputDecoration(
              isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero,
              hintText: 'Unlimited',
              hintStyle: TextStyle(color: context.cs.onSurfaceVariant.withValues(alpha: 0.4), fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

class _MacroSelector extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _MacroSelector({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: const TextStyle(fontSize: 14)),
              Icon(Icons.expand_more, size: 20, color: context.cs.onSurfaceVariant.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }
}
