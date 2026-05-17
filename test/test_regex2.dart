import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:gpt_markdown/custom_widgets/markdown_config.dart';

class TestGlowMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==glow:(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)==');

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    return TextSpan(text: '[GLOW:${match?[3]}]', style: const TextStyle(color: Colors.red));
  }
}

class TestCgMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==cg:(#[0-9a-fA-F]{3,8}),(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)==');

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    return TextSpan(text: '[CG:${match?[4]}]', style: const TextStyle(color: Colors.green));
  }
}

class TestGradMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==grad:(#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+)==(.+?)==');

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    return TextSpan(text: '[GRAD:${match?[2]}]', style: const TextStyle(color: Colors.pink));
  }
}

class TestHcMd extends InlineMd {
  @override
  RegExp get exp => RegExp(r'==hc:(#[0-9a-fA-F]{3,8})==(.+?)==');

  @override
  InlineSpan span(BuildContext context, String text, GptMarkdownConfig config) {
    final match = exp.firstMatch(text);
    return TextSpan(text: '[HC:${match?[2]}]', style: const TextStyle(color: Colors.blue));
  }
}

void main() {
  final testCases = [
    '==hc:#ff33ff==test==',
    '==glow:#ffffff,4==echo==',
    '==cg:#ffb6c1,#ff6eb4,4==rosa==',
    '==grad:#ff33ff,#ff1493==text==',
  ];

  final components = [
    TestHcMd(),
    TestGlowMd(),
    TestCgMd(),
    TestGradMd(),
  ];

  final regexes = components.map<String>((e) => e.exp.pattern);
  final combined = RegExp(regexes.join('|'), multiLine: true, dotAll: true);

  print('Combined regex pattern:');
  print(combined.pattern);
  print('');

  for (final tc in testCases) {
    print('Input: $tc');
    final matches = combined.allMatches(tc);
    for (final m in matches) {
      print('  Match: "${m[0]}"');
    }
    for (final comp in components) {
      final exp = RegExp('^${comp.exp.pattern}\$', multiLine: comp.exp.isMultiLine, dotAll: comp.exp.isDotAll);
      if (exp.hasMatch(tc)) {
        print('  Component: ${comp.runtimeType} MATCHED');
      }
    }
    print('');
  }

  // Now test the full markdown string
  final full = '==grad:#ff33ff,#ff1493=="Я никуда не пропадала,"== — её голос прозвучал';
  print('Full input: $full');
  final fullMatches = combined.allMatches(full);
  for (final m in fullMatches) {
    print('  Match: "${m[0]}" at ${m.start}-${m.end}');
  }
}
