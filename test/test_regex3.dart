void main() {
  final cases = [
    '==hc:#ff33ff==test==',
    '==glow:#ffffff,4==echo==',
    '==cg:#ffb6c1,#ff6eb4,4==rosa==',
    '==grad:#ff33ff,#ff1493==text==',
  ];

  final exps = {
    'HtmlColorMd': RegExp(r'==hc:(#[0-9a-fA-F]{3,8})==(.+?)=='),
    'GlowTextMd': RegExp(r'==glow:(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)=='),
    'ColorGlowTextMd': RegExp(r'==cg:(#[0-9a-fA-F]{3,8}),(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)=='),
    'GradientTextMd': RegExp(r'==grad:(#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+)==(.+?)=='),
    'MarkMd': RegExp(r'==mark==(.+?)=='),
  };

  for (final tc in cases) {
    print('Input: $tc');
    for (final e in exps.entries) {
      final m = e.value.firstMatch(tc);
      if (m != null) {
        print('  ${e.key}: MATCH groups=${m.groupCount} g1="${m[1]}" g2="${m[2]}"');
      }
    }
    print('');
  }

  // Test combined regex like GptMarkdown does
  final allPatterns = exps.values.map((e) => e.pattern).join('|');
  print('Combined pattern length: ${allPatterns.length}');
  
  final combined = RegExp(allPatterns, multiLine: true, dotAll: true);
  
  final fullText = '==grad:#ff33ff,#ff1493=="text here"== rest';
  print('\nFull text: $fullText');
  for (final m in combined.allMatches(fullText)) {
    print('  Match at ${m.start}-${m.end}: "${m[0]}"');
  }
}
