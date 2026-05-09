String htmlToMarkdown(String html) {
  var result = html;

  result = _stripBlock(result, 'style');
  result = _stripBlock(result, 'script');

  result = result.replaceAll(RegExp(r'<br\s*/?>\s*', caseSensitive: false), '\n');

  result = result.replaceAllMapped(
    RegExp(r'<h([1-6])[^>]*>(.*?)</h\1>', caseSensitive: false, dotAll: true),
    (m) => '\n${'#' * int.parse(m[1]!)} ${_inline(m[2]!)}\n',
  );

  result = result.replaceAllMapped(
    RegExp(r'<p[^>]*>(.*?)</p>', caseSensitive: false, dotAll: true),
    (m) => '\n${_inline(m[1]!)}\n',
  );

  result = result.replaceAllMapped(
    RegExp(r'<blockquote[^>]*>(.*?)</blockquote>', caseSensitive: false, dotAll: true),
    (m) => _inline(m[1]!).split('\n').map((l) => '> $l').join('\n'),
  );

  result = _convertInline(result, 'strong', '**');
  result = _convertInline(result, 'b', '**');
  result = _convertInline(result, 'em', '*');
  result = _convertInline(result, 'i', '*');
  result = _convertInline(result, 'del', '~~');
  result = _convertInline(result, 's', '~~');
  result = _convertInline(result, 'u', '__');
  result = _convertInline(result, 'code', '`');

  result = result.replaceAllMapped(
    RegExp(r'''<a[^>]*href=["']([^"']*)["'][^>]*>(.*?)</a>''', caseSensitive: false, dotAll: true),
    (m) => '[${_inline(m[2]!)}](${m[1]!})',
  );

  result = result.replaceAllMapped(
    RegExp(r'''<img[^>]*src=["']([^"']*)["'][^>]*>''', caseSensitive: false),
    (m) => '![](${m[1]!})',
  );

  result = result.replaceAllMapped(
    RegExp(r'<hr\s*/?>', caseSensitive: false),
    (m) => '\n---\n',
  );

  result = result.replaceAll(
    RegExp(r'</?(?:div|span|section|article|header|footer|nav|main|figure|figcaption|details|summary|center|font|small|sub|sup|mark|table|tr|td|th|thead|tbody|ul|ol|li|dl|dt|dd|pre)[^>]*>', caseSensitive: false),
    '\n',
  );

  result = result.replaceAll(RegExp(r'<[^>]+>'), '');

  result = result.replaceAll('&amp;', '&');
  result = result.replaceAll('&lt;', '<');
  result = result.replaceAll('&gt;', '>');
  result = result.replaceAll('&quot;', '"');
  result = result.replaceAll('&#39;', "'");
  result = result.replaceAll('&apos;', "'");
  result = result.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (m) {
      final code = int.tryParse(m[1]!);
      return code != null ? String.fromCharCode(code) : m[0]!;
    },
  );
  result = result.replaceAll(RegExp(r'&nbsp;'), ' ');

  result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  return result.trim();
}

String _inline(String text) {
  return text.replaceAll(RegExp(r'<[^>]+>'), '').trim();
}

String _stripBlock(String html, String tag) {
  return html.replaceAll(RegExp('<$tag[^>]*>.*?</$tag>', caseSensitive: false, dotAll: true), '');
}

String _convertInline(String html, String tag, String marker) {
  return html.replaceAllMapped(
    RegExp('<$tag[^>]*>(.*?)</$tag>', caseSensitive: false, dotAll: true),
    (match) => '$marker${_inline(match[1]!)}$marker',
  );
}

bool hasHtmlTags(String content) => _htmlTagRegex.hasMatch(content);

String stripHtml(String content) {
  if (!hasHtmlTags(content)) return content;
  var result = _stripBlock(content, 'style');
  result = _stripBlock(result, 'script');
  result = result.replaceAll(RegExp(r'<br\s*/?>\s*', caseSensitive: false), '\n');
  result = result.replaceAll(RegExp(r'<[^>]+>'), '');
  result = result.replaceAll('&amp;', '&');
  result = result.replaceAll('&lt;', '<');
  result = result.replaceAll('&gt;', '>');
  result = result.replaceAll('&quot;', '"');
  result = result.replaceAll('&#39;', "'");
  result = result.replaceAll('&apos;', "'");
  result = result.replaceAll(RegExp(r'&nbsp;'), ' ');
  return result.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
}

final _htmlTagRegex = RegExp(
  r'<(div|span|p|br|img|a|table|tr|td|th|ul|ol|li|h[1-6]|hr|pre|code|blockquote|style|font|center|b|i|u|s|em|strong|small|sub|sup|mark|details|summary|section|article|header|footer|nav|figure|figcaption|iframe)\b',
  caseSensitive: false,
);
