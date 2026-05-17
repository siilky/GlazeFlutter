void main() {
  // Simulate what GptMarkdown does
  final inlineComponents = <String, RegExp>{
    'ATagMd': RegExp(r'\[([^\]]+)\]\(([^)]+)\)'),
    'ImageMd': RegExp(r'!\[([^\]]*)\]\(([^)]+)\)'),
    'HtmlColorMd': RegExp(r'==hc:(#[0-9a-fA-F]{3,8})==(.+?)=='),
    'GlowTextMd': RegExp(r'==glow:(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)=='),
    'ColorGlowTextMd': RegExp(r'==cg:(#[0-9a-fA-F]{3,8}),(#[0-9a-fA-F]{3,8}),(\d+)==(.+?)=='),
    'GradientTextMd': RegExp(r'==grad:(#[0-9a-fA-F]{3,8}(?:,#[0-9a-fA-F]{3,8})+)==(.+?)=='),
    'MarkMd': RegExp(r'==mark==(.+?)=='),
    'ActiveMarkMd': RegExp(r'==active==(.+?)=='),
    'TableMd': RegExp(r'\|(.+)\|'),
    'StrikeMd': RegExp(r"(?<!\*)\~\~(?<!\s)(.+?)(?<!\s)\~\~(?!\*)"),
    'BoldMd': RegExp(r"(?<!\*)\*\*(?<!\s)(.+?)(?<!\s)\*\*(?!\*)"),
    'ItalicMd': RegExp(r"(?<!\*)\*(?<!\s)(.+?)(?<!\s)\*(?!\*)"),
    'UnderLineMd': RegExp(r"_(?!\s)(.+?)(?<!\s)_"),
    'HighlightedText': RegExp(r"`(?!`)(.+?)(?<!`)`(?!`)"),
    'SourceTag': RegExp(r"(?:【.*?)?\[(\d+?)\]"),
  };

  final allPatterns = inlineComponents.values.map((e) => e.pattern).join('|');
  final combined = RegExp(allPatterns, multiLine: true, dotAll: true);

  final testInput = 'some text ==mark==highlighted== more ==grad:#ff33ff,#ff1493=="Я никуда не пропадала,"== rest ==cg:#ffb6c1,#ff6eb4,4==холодным розовым светом== end';

  print('Input: $testInput\n');
  
  for (final m in combined.allMatches(testInput)) {
    final matched = m[0]!;
    String? which;
    for (final e in inlineComponents.entries) {
      final exp = RegExp('^${e.value.pattern}\$', multiLine: e.value.isMultiLine, dotAll: e.value.isDotAll);
      if (exp.hasMatch(matched)) {
        which = e.key;
        break;
      }
    }
    print('Match at ${m.start}-${m.end}: "$matched" -> $which');
  }
}
