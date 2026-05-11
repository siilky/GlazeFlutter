import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../theme/theme_provider.dart';
import '../theme/theme_preset.dart';

final chatFontSizeProvider = Provider<double>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  return preset.chatFontSizeValue;
});

final chatLetterSpacingProvider = Provider<double>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  return preset.chatLetterSpacing;
});

final uiFontSizeProvider = Provider<double?>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  final v = preset.uiFontSize;
  if (v == 'system' || v == null) return null;
  return preset.uiFontSizeValue;
});

final uiLetterSpacingProvider = Provider<double>((ref) {
  final preset = ref.watch(themeProvider).activePreset;
  return preset.uiLetterSpacing;
});

final _loadedFonts = <String>{};

Future<String?> _loadFontFromBase64(String base64Data, String name) async {
  if (_loadedFonts.contains(name)) return name;

  try {
    final bytes = base64Decode(base64Data);
    await ui.loadFontFromList(Uint8List.fromList(bytes), fontFamily: name);
    _loadedFonts.add(name);
    return name;
  } catch (_) {
    return null;
  }
}

final chatFontFamilyProvider = FutureProvider<String?>((ref) async {
  final preset = ref.watch(themeProvider).activePreset;
  if (!preset.hasChatFont || preset.chatFontName == null) return null;
  return _loadFontFromBase64(preset.chatFont!, preset.chatFontName!);
});

final uiFontFamilyProvider = FutureProvider<String?>((ref) async {
  final preset = ref.watch(themeProvider).activePreset;
  if (!preset.hasCustomFont || preset.customFontName == null) return null;
  return _loadFontFromBase64(preset.customFont!, preset.customFontName!);
});

final bgImageProvider = FutureProvider<String?>((ref) async {
  final preset = ref.watch(themeProvider).activePreset;
  if (!preset.hasBgImage) return null;

  try {
    final data = preset.bgImage!;
    final commaIdx = data.indexOf(',');
    if (commaIdx == -1) return null;
    final base64Str = data.substring(commaIdx + 1);
    final bytes = base64Decode(base64Str);

    final dir = await getApplicationSupportDirectory();
    final hash = base64Str.length.hashCode.toRadixString(36);
    final file = File('${dir.path}/bg/$hash.jpg');
    if (!file.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    await file.writeAsBytes(bytes);
    return file.path;
  } catch (_) {
    return null;
  }
});
