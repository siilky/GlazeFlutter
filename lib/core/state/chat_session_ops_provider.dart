import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import 'db_provider.dart';

class ChatSessionOps extends AsyncNotifier<List<ChatSession>> {
  @override
  Future<List<ChatSession>> build() async {
    return ref.read(chatRepoProvider).getAllSessions();
  }

  Future<void> saveSession(ChatSession session) async {
    await ref.read(chatRepoProvider).put(session);
    ref.invalidateSelf();
  }

  Future<ChatSession?> getSession(String sessionId) async {
    return ref.read(chatRepoProvider).getById(sessionId);
  }

  Future<List<ChatSession>> getSessionsByCharacter(String charId) async {
    return ref.read(chatRepoProvider).getByCharacterId(charId);
  }
}

final chatSessionOpsProvider = AsyncNotifierProvider<ChatSessionOps, List<ChatSession>>(
  ChatSessionOps.new,
);
