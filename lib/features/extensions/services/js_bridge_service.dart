import 'dart:async';

import 'package:flutter/foundation.dart';

class JsBridgeService {
  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> request) async {
    final method = request['method'] as String? ?? '';
    final params = _asMap(request['params']);

    try {
      final result = await _handle(method, params, _asMap(request['context']));
      return {'ok': true, 'result': result};
    } catch (e, st) {
      debugPrint('[JsBridge] $method failed: $e\n$st');
      return {
        'ok': false,
        'error': {
          'code': e is UnsupportedError ? 'unsupported_method' : 'bridge_error',
          'message': e.toString(),
        },
      };
    }
  }

  FutureOr<dynamic> _handle(
    String method,
    Map<String, dynamic> params,
    Map<String, dynamic> context,
  ) {
    switch (method) {
      case 'showToast':
        debugPrint('[JsBridge] toast: ${params['message'] ?? ''}');
        return true;
      case 'getVariables':
      case 'setVariables':
      case 'deleteVariable':
      case 'executeCommand':
      case 'triggerGeneration':
      case 'injectPrompt':
      case 'uninjectPrompt':
      case 'generateText':
      case 'playAudio':
        throw UnsupportedError('glaze.$method is not implemented yet');
      default:
        throw UnsupportedError('Unknown glaze method "$method"');
    }
  }

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return <String, dynamic>{};
  }
}
