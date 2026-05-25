import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:path_provider/path_provider.dart';
// ignore: implementation_imports
import 'package:tiktoken/src/common/byte_array.dart';
import 'package:tiktoken/tiktoken.dart';

const _o200kBaseVocabUrl =
    'https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken';

const _o200kBasePatStr =
    r"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+('[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*('[sS]|'[tT]|'[rR][eE]|'[vV][eE]|'[mM]|'[lL][lL]|'[dD])?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+";

const _o200kCacheFile = 'o200k_base.tiktoken';

const _o200kFallbackFactor = 0.87;

Tiktoken? _o200kBaseEncoder;
Tiktoken? _cl100kBaseEncoder;

final _tokenCache = <String, int>{};
const _maxCacheSize = 2048;

Tiktoken _getCl100kBase() {
  if (_cl100kBaseEncoder != null) return _cl100kBaseEncoder!;
  _cl100kBaseEncoder = getEncoding('cl100k_base');
  return _cl100kBaseEncoder!;
}

Future<void> preloadO200kBase() async {
  if (_o200kBaseEncoder != null) {
    debugPrint('[tokenizer] o200k_base already loaded');
    return;
  }

  try {
    final dir = await getApplicationSupportDirectory();
    final cacheFile = File('${dir.path}/$_o200kCacheFile');

    String bpeData;
    if (await cacheFile.exists()) {
      bpeData = await cacheFile.readAsString();
      debugPrint('[tokenizer] o200k_base loaded from cache (${bpeData.length} chars)');
    } else {
      debugPrint('[tokenizer] o200k_base not cached, downloading from $_o200kBaseVocabUrl...');
      final response = await Dio().get<String>(
        _o200kBaseVocabUrl,
        options: Options(responseType: ResponseType.plain),
      );
      bpeData = response.data!;
      await cacheFile.writeAsString(bpeData);
      debugPrint('[tokenizer] o200k_base downloaded and cached (${bpeData.length} chars)');
    }

    final t0 = DateTime.now();
    final mergeableRanks = <ByteArray, int>{};
    for (final line in bpeData.split('\n')) {
      if (line.isEmpty) continue;
      final parts = line.split(' ');
      if (parts.length != 2) continue;
      mergeableRanks[ByteArray.fromList(base64Decode(parts[0]))] = int.parse(parts[1]);
    }
    final t1 = DateTime.now();
    debugPrint('[tokenizer] o200k_base parsed ${mergeableRanks.length} ranks in ${t1.difference(t0).inMilliseconds}ms');

    const specialTokens = <String, int>{
      '<|endoftext|>': 199999,
      '<|endofprompt|>': 200018,
    };

    final t2 = DateTime.now();
    _o200kBaseEncoder = Tiktoken(
      name: 'o200k_base',
      patStr: _o200kBasePatStr,
      mergeableRanks: mergeableRanks,
      specialTokens: specialTokens,
    );
    final t3 = DateTime.now();
    debugPrint('[tokenizer] o200k_base Tiktoken constructor took ${t3.difference(t2).inMilliseconds}ms');
    debugPrint('[tokenizer] _o200kBaseEncoder set? ${_o200kBaseEncoder != null} hash=${identityHashCode(_o200kBaseEncoder)}');

    debugPrint('[tokenizer] o200k_base testing encode...');
    final t4 = DateTime.now();
    final testCount = _o200kBaseEncoder!
        .encode('Hello world', disallowedSpecial: SpecialTokensSet.empty())
        .length;
    debugPrint('[tokenizer] o200k_base encode test: "Hello world" = $testCount tokens in ${DateTime.now().difference(t4).inMilliseconds}ms');
    debugPrint('[tokenizer] after test: _o200kBaseEncoder null? ${_o200kBaseEncoder == null}');

    _tokenCache.clear();
    debugPrint('[tokenizer] o200k_base ready — token cache cleared');
  } catch (e, st) {
    debugPrint('[tokenizer] FAILED to load o200k_base: $e\n$st');
  }
}

bool get o200kBaseLoaded => _o200kBaseEncoder != null;

int _encodeCallCount = 0;

int estimateTokens(String text, {bool useCache = true}) {
  if (text.isEmpty) return 0;
  final cleaned = _stripBase64Media(text);
  if (cleaned.isEmpty) return 0;

  if (useCache) {
    final key = _cacheKey(cleaned);
    final cached = _tokenCache[key];
    if (cached != null) return cached;
    final sw = Stopwatch()..start();
    final count = _computeTokens(cleaned);
    sw.stop();
    _encodeCallCount++;
    if (_encodeCallCount <= 10 || sw.elapsedMilliseconds > 100) {
      debugPrint('[tokenizer] encode #$_encodeCallCount: ${cleaned.length} chars → $count tokens in ${sw.elapsedMilliseconds}ms');
    }
    if (_tokenCache.length >= _maxCacheSize) _tokenCache.remove(_tokenCache.keys.first);
    _tokenCache[key] = count;
    return count;
  }

  return _computeTokens(cleaned);
}

int _computeTokens(String cleaned) {
  try {
    final encoder = _o200kBaseEncoder;
    if (_encodeCallCount <= 3) {
      debugPrint('[tokenizer] _computeTokens: _o200kBaseEncoder==null? ${_o200kBaseEncoder == null} hash=${identityHashCode(_o200kBaseEncoder)}');
    }
    if (encoder != null) {
      return encoder
          .encode(cleaned, disallowedSpecial: SpecialTokensSet.empty())
          .length;
    }
    debugPrint('[tokenizer] o200k_base NOT loaded (_o200kBaseEncoder == null), using cl100k_base * 0.87 fallback');
    final cl100kCount = _getCl100kBase()
        .encode(cleaned, disallowedSpecial: SpecialTokensSet.empty())
        .length;
    return (cl100kCount * _o200kFallbackFactor).ceil();
  } catch (e) {
    debugPrint('[tokenizer] encode failed: $e');
    return (cleaned.length / 3.35).ceil();
  }
}

String _cacheKey(String text) {
  if (text.length <= 128) return text;
  return md5.convert(utf8.encode(text)).toString();
}

void clearTokenCache() => _tokenCache.clear();

String _stripBase64Media(String text) {
  if (text.length < 256) return text;
  var result = text.replaceAllMapped(
    RegExp(r'<img\s+src="data:image/[^"]{256,}?"\s*/?>'),
    (_) => '',
  );
  result = result.replaceAllMapped(
    RegExp(r'data:image/[^;]+;base64,[A-Za-z0-9+/=]{256,}'),
    (_) => '',
  );
  return result;
}