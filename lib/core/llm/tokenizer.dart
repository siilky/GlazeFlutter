import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
// ignore: depend_on_referenced_packages, implementation_imports
import 'package:path_provider/path_provider.dart';
// ignore: implementation_imports
import 'package:tiktoken/src/common/byte_array.dart';
import 'package:tiktoken/tiktoken.dart';

const _o200kBaseVocabUrl =
    'https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken';

const _o200kBasePatStr =
    r"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+";

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
  if (_o200kBaseEncoder != null) return;

  final dir = await getApplicationSupportDirectory();
  final cacheFile = File('${dir.path}/$_o200kCacheFile');

  String bpeData;
  if (await cacheFile.exists()) {
    bpeData = await cacheFile.readAsString();
  } else {
    final response = await Dio().get<String>(
      _o200kBaseVocabUrl,
      options: Options(responseType: ResponseType.plain),
    );
    bpeData = response.data!;
    await cacheFile.writeAsString(bpeData);
  }

  final mergeableRanks = <ByteArray, int>{};
  for (final line in bpeData.split('\n')) {
    if (line.isEmpty) continue;
    final parts = line.split(' ');
    if (parts.length != 2) continue;
    mergeableRanks[ByteArray.fromList(base64Decode(parts[0]))] = int.parse(parts[1]);
  }

  const specialTokens = <String, int>{
    '': 199999,
    '<|endofprompt|>': 200018,
  };

  _o200kBaseEncoder = Tiktoken(
    name: 'o200k_base',
    patStr: _o200kBasePatStr,
    mergeableRanks: mergeableRanks,
    specialTokens: specialTokens,
  );
}

bool get o200kBaseLoaded => _o200kBaseEncoder != null;

int estimateTokens(String text, {bool useCache = true}) {
  if (text.isEmpty) return 0;
  final cleaned = _stripBase64Media(text);
  if (cleaned.isEmpty) return 0;

  if (useCache) {
    final key = _cacheKey(cleaned);
    final cached = _tokenCache[key];
    if (cached != null) return cached;
    final count = _computeTokens(cleaned);
    if (_tokenCache.length >= _maxCacheSize) _tokenCache.remove(_tokenCache.keys.first);
    _tokenCache[key] = count;
    return count;
  }

  return _computeTokens(cleaned);
}

int _computeTokens(String cleaned) {
  try {
    if (_o200kBaseEncoder != null) {
      return _o200kBaseEncoder!
          .encode(cleaned, disallowedSpecial: SpecialTokensSet.empty())
          .length;
    }
    final cl100kCount = _getCl100kBase()
        .encode(cleaned, disallowedSpecial: SpecialTokensSet.empty())
        .length;
    return (cl100kCount * _o200kFallbackFactor).ceil();
  } catch (_) {
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