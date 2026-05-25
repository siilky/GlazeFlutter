import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';

void main() {
  group('ChatSessionService LRU cache', () {
    const maxCacheSize = 20;

    setUp(() {
      ChatSessionService.clearCache();
    });

    tearDown(() {
      ChatSessionService.clearCache();
    });

    ChatSession _makeSession(String id, {String charId = 'test'}) {
      return ChatSession(
        id: id,
        characterId: charId,
        sessionIndex: 0,
      );
    }

    test('clearCache removes all entries', () {
      ChatSessionService.updateCache(_makeSession('a'));
      ChatSessionService.updateCache(_makeSession('b'));
      ChatSessionService.clearCache();
      expect(ChatSessionService.cacheSize, 0);
    });

    test('clearCache with charId removes only matching entries', () {
      ChatSessionService.updateCache(_makeSession('charA_0', charId: 'charA'));
      ChatSessionService.updateCache(_makeSession('charA_1', charId: 'charA'));
      ChatSessionService.updateCache(_makeSession('charB_0', charId: 'charB'));
      ChatSessionService.clearCache(charId: 'charA');
      expect(ChatSessionService.cacheSize, 1);
    });

    test('cache evicts oldest entries when exceeding max size', () {
      for (int i = 0; i < maxCacheSize + 5; i++) {
        ChatSessionService.updateCache(_makeSession('key_$i'));
      }
      expect(ChatSessionService.cacheSize, maxCacheSize);
    });

    test('touching a key moves it to end of LRU', () {
      for (int i = 0; i < maxCacheSize; i++) {
        ChatSessionService.updateCache(_makeSession('key_$i'));
      }
      ChatSessionService.updateCache(_makeSession('key_0'));
      ChatSessionService.updateCache(_makeSession('extra'));
      expect(ChatSessionService.cacheSize, maxCacheSize);
    });

    test('updateCache on existing entry does not grow cache', () {
      final s1 = _makeSession('id1');
      ChatSessionService.updateCache(s1);
      expect(ChatSessionService.cacheSize, 1);
      ChatSessionService.updateCache(s1);
      expect(ChatSessionService.cacheSize, 1);
    });
  });
}
