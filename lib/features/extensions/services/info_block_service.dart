import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/info_blocks_repository.dart';
import '../../../core/llm/sse_client.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/character.dart';
import '../../../core/state/db_provider.dart';
import '../../settings/api_list_provider.dart';
import '../models/block_config.dart';
import '../models/info_block.dart';

final infoBlockServiceProvider = Provider<InfoBlockService>(
  (ref) => InfoBlockService(ref),
);

class InfoBlockService {
  InfoBlockService(this._ref);

  final Ref _ref;

  InfoBlocksRepository get _repo =>
      InfoBlocksRepository(_ref.read(appDbProvider));

  /// Generates the text content for a single infoblock block.
  /// Returns null if generation failed or was cancelled.
  /// [previousOutput] is the content produced by the preceding block in the
  /// chain (used as additional context when non-null).
  Future<String?> generateSingleBlockContent({
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required Character? character,
    required String? persona,
    required String? previousOutput,
    CancelToken? cancelToken,
  }) async {
    if (cancelToken?.isCancelled == true) return null;

    // Build context from recent messages using blockConfig.contextMessageCount.
    final contextMessages = _buildContextMessages(messages, blockConfig.contextMessageCount);

    // Build injected history: last `injectLastN` assistant messages that
    // already have a block result for this block name.
    final injectedHistory = await _buildInjectedHistory(
      sessionId: sessionId,
      messages: messages,
      blockConfig: blockConfig,
    );

    // Build system message (template + prompt) and user message (context).
    final resolvedTemplate = _resolveTemplate(blockConfig);
    final systemContent = _buildSystemMessage(
      blockConfig: blockConfig,
      template: resolvedTemplate,
    );
    final userContent = _buildUserMessage(
      blockConfig: blockConfig,
      character: character,
      persona: persona,
      contextMessages: contextMessages,
      previousBlockHistory: injectedHistory,
      previousOutput: previousOutput,
    );

    // Resolve API config.
    final apiConfigId = blockConfig.apiConfigId;
    if (apiConfigId.isEmpty) {
      debugPrint('[InfoBlockService] No API config for block "${blockConfig.name}"');
      return null;
    }

    final apiConfigs = await _ref.read(apiListProvider.future);
    final apiConfig = apiConfigs.where((c) => c.id == apiConfigId).firstOrNull;
    if (apiConfig == null) {
      debugPrint('[InfoBlockService] API config not found: $apiConfigId');
      return null;
    }

    if (cancelToken?.isCancelled == true) return null;

    final rawResponse = await _callLLM(
      apiConfig: apiConfig,
      blockConfig: blockConfig,
      systemContent: systemContent,
      userContent: userContent,
      cancelToken: cancelToken,
    );

    if (rawResponse == null) return null;

    // Extract content from the LLM's response: parse out the <name>...</name>
    // block if present. Falls back to the raw response (trimmed) when no
    // matching tags are found so the user still sees *something* in the panel.
    final extracted = _extractBlockContent(rawResponse, blockConfig.name);
    if (extracted == null) {
      debugPrint('[InfoBlockService] WARNING: response not wrapped in <${blockConfig.name}> tags; storing raw output');
      return rawResponse.trim();
    }
    return extracted;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Context helpers
  // ─────────────────────────────────────────────────────────────────────────

  List<ChatMessage> _buildContextMessages(List<ChatMessage> messages, int count) {
    if (messages.isEmpty) return [];
    if (count == 0) return [];
    if (count < 0) return List<ChatMessage>.from(messages); // entire history
    final startIdx = (messages.length - count).clamp(0, messages.length);
    return messages.sublist(startIdx);
  }

  /// Substitutes SillyTavern-style macros in [text].
  String _applyMacros(String text, {Character? character, String? persona}) {
    var result = text;
    result = result.replaceAll('{{char}}', character?.name ?? '');
    result = result.replaceAll('{{user}}', persona ?? '');
    result = result.replaceAll('{{description}}', character?.description ?? '');
    result = result.replaceAll('{{personality}}', character?.personality ?? '');
    return result;
  }

  /// Replaces `{{name}}` in the template with the block's actual name.
  /// Falls back to a minimal default when the template is empty.
  String _resolveTemplate(BlockConfig blockConfig) {
    final raw = blockConfig.template.trim();
    final tpl = raw.isEmpty ? '<${blockConfig.name}>\n\n</${blockConfig.name}>' : raw;
    return tpl.replaceAll('{{name}}', blockConfig.name);
  }

  /// Collects past results of this block from the last [injectLastN] assistant
  /// messages — used to give the model memory of its previous outputs.
  Future<List<InfoBlock>> _buildInjectedHistory({
    required String sessionId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
  }) async {
    if (blockConfig.injectLastN <= 0 || !blockConfig.inject) return [];

    final assistantMessages = messages
        .where((m) => m.role == 'assistant')
        .toList();

    final lastN = assistantMessages.length > blockConfig.injectLastN
        ? assistantMessages.sublist(
            assistantMessages.length - blockConfig.injectLastN)
        : assistantMessages;

    final results = <InfoBlock>[];
    for (final msg in lastN) {
      final blocks = await _repo.getByMessageId(sessionId, msg.id);
      results.addAll(blocks.where((b) => b.blockName == blockConfig.name));
    }
    return results;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Prompt building (system + user)
  // ─────────────────────────────────────────────────────────────────────────

  /// Builds the system message: shows the model the exact template layout it
  /// must produce, plus optional user-defined prompt instructions.
  /// Mirrors upstream `BlockService.getBlocksFullPrompt`.
  String _buildSystemMessage({
    required BlockConfig blockConfig,
    required String template,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('Block template (output the content inside these tags):');
    buffer.writeln(template);
    buffer.writeln();

    if (blockConfig.prompt.isNotEmpty) {
      buffer.writeln('Instructions:');
      buffer.writeln(blockConfig.prompt);
      buffer.writeln();
    }
    return buffer.toString().trimRight();
  }

  /// Builds the user message: the conversation context, character, persona,
  /// and previous block history. The model is meant to fill in the template
  /// based on this material.
  String _buildUserMessage({
    required BlockConfig blockConfig,
    required Character? character,
    required String? persona,
    required List<ChatMessage> contextMessages,
    required List<InfoBlock> previousBlockHistory,
    required String? previousOutput,
  }) {
    final buffer = StringBuffer();

    if (blockConfig.contextSystemPrompt.isNotEmpty) {
      final sysPrompt = _applyMacros(
        blockConfig.contextSystemPrompt,
        character: character,
        persona: persona,
      );
      buffer.writeln(sysPrompt);
      buffer.writeln();
    }

    if (character != null) {
      buffer.writeln('Character: ${character.name}');
      if (character.description != null && character.description!.isNotEmpty) {
        buffer.writeln('Description: ${character.description}');
      }
      buffer.writeln();
    }

    if (persona != null && persona.isNotEmpty) {
      buffer.writeln('User Persona: $persona');
      buffer.writeln();
    }

    if (contextMessages.isNotEmpty) {
      buffer.writeln('Recent conversation:');
      for (final msg in contextMessages) {
        final role = msg.role == 'user' ? 'USER' : 'ASSISTANT';
        buffer.writeln('$role: ${msg.content}');
      }
      buffer.writeln();
    }

    if (previousBlockHistory.isNotEmpty) {
      buffer.writeln('Previous <${blockConfig.name}> outputs (for continuity):');
      for (final block in previousBlockHistory) {
        buffer.writeln('<${blockConfig.name}>');
        buffer.writeln(block.content);
        buffer.writeln('</${blockConfig.name}>');
      }
      buffer.writeln();
    }

    if (previousOutput != null && previousOutput.isNotEmpty) {
      buffer.writeln('Output from previous block in chain:');
      buffer.writeln(previousOutput);
      buffer.writeln();
    }

    return buffer.toString().trimRight();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Block content extraction
  // ─────────────────────────────────────────────────────────────────────────

  /// Extracts the first `<name ...>...</name>` block from [response] and
  /// returns it with the original tags preserved. Returns null when the
  /// response does not contain a matching tag pair.
  ///
  /// Tolerates attributes on the opening tag (e.g. `<name attr="x">`) and
  /// matches across newlines, matching the behaviour of upstream's
  /// `getBlockFromMessage` while keeping this implementation regex-based
  /// for simplicity.
  String? _extractBlockContent(String response, String name) {
    if (response.isEmpty) return null;
    final escaped = RegExp.escape(name);
    final pattern = RegExp(
      '<$escaped(\\s+[^>]*)?>[\\s\\S]*?<\\/$escaped>',
      multiLine: true,
    );
    final match = pattern.firstMatch(response);
    if (match == null) return null;
    final inner = (match.group(2) ?? '').trim();
    return '<$name>$inner</$name>';
  }

  // ─────────────────────────────────────────────────────────────────────────
  // LLM call
  // ─────────────────────────────────────────────────────────────────────────

  Future<String?> _callLLM({
    required ApiConfig apiConfig,
    required BlockConfig blockConfig,
    required String systemContent,
    required String userContent,
    CancelToken? cancelToken,
  }) async {
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemContent},
      {'role': 'user', 'content': userContent},
    ];

    try {
      final sseClient = SseClient();
      final completer = Completer<String>();

      await sseClient.streamChatCompletion(
        endpoint: apiConfig.endpoint,
        apiKey: apiConfig.apiKey,
        model: blockConfig.model.isNotEmpty ? blockConfig.model : apiConfig.model,
        messages: messages,
        maxTokens: apiConfig.maxTokens,
        temperature: apiConfig.temperature,
        topP: apiConfig.topP,
        stream: false,
        cancelToken: cancelToken,
        onComplete: (text, reasoning, {rawResponseJson}) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onError: (error) {
          if (!completer.isCompleted) completer.completeError(error);
        },
      );

      return await completer.future;
    } catch (e) {
      if (cancelToken?.isCancelled == true) return null;
      debugPrint('[InfoBlockService] LLM call failed: $e');
      return null;
    }
  }
}
