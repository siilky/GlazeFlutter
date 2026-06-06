import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/db/repositories/info_blocks_repository.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/character.dart';
import '../../../core/models/persona.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/utils/id_generator.dart';
import '../../chat/bridge/chat_bridge_registry.dart';
import '../../image_gen/image_gen_provider.dart';
import '../models/block_config.dart';
import '../models/block_run_status.dart';
import '../models/extension_preset.dart';
import '../models/info_block.dart';
import '../providers/extension_presets_provider.dart';
import '../providers/extensions_settings_provider.dart';
import '../providers/info_blocks_provider.dart';
import 'info_block_service.dart';

final extensionPostGenServiceProvider = Provider<ExtensionPostGenService>(
  (ref) => ExtensionPostGenService(ref),
);

/// Orchestrates extension block generation after chat response.
/// Blocks are run in `order` sequence; blocks with [BlockConfig.dependsOnPrevious]
/// wait for the previous block to finish (done or error) before starting.
/// Independently-configured blocks start in parallel with the previous one.
class ExtensionPostGenService {
  ExtensionPostGenService(this._ref);

  final Ref _ref;

  /// Active cancel token for the current block run. Cancelling this stops
  /// all in-flight block LLM/image calls without touching the main gen token.
  CancelToken? _blocksCancelToken;

  InfoBlocksRepository get _repo =>
      InfoBlocksRepository(_ref.read(appDbProvider));

  /// Pushes the current aggregated block status for [messageId] to the
  /// WebView. No-op if the WebView isn't mounted (bridge==null). Computes
  /// the aggregated status (running > error > done) from the latest
  /// in-memory state and only sends it if it differs from the bridge's
  /// last sent value.
  void _pushBadgeToBridge(String charId, String sessionId, String messageId) {
    final bridge = _ref.read(chatBridgeRegistryProvider(charId));
    if (bridge == null) return;
    final blocks = _ref.read(infoBlocksProvider(sessionId));
    final mb = blocks.where((b) => b.messageId == messageId).toList();
    if (mb.isEmpty) return;
    String status;
    if (mb.any((b) => b.status == BlockRunStatus.running)) {
      status = 'running';
    } else if (mb.any((b) => b.status == BlockRunStatus.error)) {
      status = 'error';
    } else {
      status = 'done';
    }
    unawaited(bridge.updateBlockStatus(messageId, status));
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Public API
  // ─────────────────────────────────────────────────────────────────────────

  /// Called by GenerationPipeline after assistant message is finalised.
  Future<void> processAfterGeneration({
    required String charId,
    required ChatSession session,
    required Character character,
    required Persona? persona,
  }) async {
    final settings = _ref.read(extensionsSettingsProvider);
    debugPrint('[ExtPostGen] processAfterGeneration: enabled=${settings.enabled} presetId=${settings.activePresetId}');
    if (!settings.enabled) {
      debugPrint('[ExtPostGen] SKIP: settings.enabled=false');
      return;
    }
    final presetId = settings.activePresetId;
    if (presetId == null || presetId.isEmpty) {
      debugPrint('[ExtPostGen] SKIP: presetId is null/empty');
      return;
    }

    final presets = _ref.read(extensionPresetsProvider);
    final preset = presets.where((pr) => pr.id == presetId).firstOrNull;
    if (preset == null) {
      debugPrint('[ExtPostGen] SKIP: preset not found in extensionPresetsProvider (have=${presets.length})');
      return;
    }
    debugPrint('[ExtPostGen] preset="${preset.name}" totalBlocks=${preset.blocks.length}');

    final sessionId = session.id;
    if (sessionId.isEmpty) {
      debugPrint('[ExtPostGen] SKIP: sessionId is empty');
      return;
    }

    final messages = session.messages;
    if (messages.isEmpty) {
      debugPrint('[ExtPostGen] SKIP: messages.isEmpty');
      return;
    }

    final lastMessage = messages.last;
    if (lastMessage.role == 'user') {
      debugPrint('[ExtPostGen] SKIP: last message is user, no assistant response to extend');
      return;
    }
    debugPrint('[ExtPostGen] target message: id=${lastMessage.id} role=${lastMessage.role} contentLen=${lastMessage.content.length}');

    // Fresh cancel token for this run.
    _blocksCancelToken = CancelToken();

    await _runChain(
      charId: charId,
      sessionId: sessionId,
      messageId: lastMessage.id,
      messages: messages,
      preset: preset,
      character: character,
      persona: persona,
      cancelToken: _blocksCancelToken!,
    );
  }

  /// Re-runs a single block for an already-existing message.
  Future<void> rerunBlock({
    required String blockId,
    required String messageId,
    required String sessionId,
    required String charId,
    required List<ChatMessage> messages,
    required Character character,
    required Persona? persona,
  }) async {
    final settings = _ref.read(extensionsSettingsProvider);
    if (!settings.enabled) return;
    final presetId = settings.activePresetId;
    if (presetId == null || presetId.isEmpty) return;

    final presets = _ref.read(extensionPresetsProvider);
    final preset = presets.where((pr) => pr.id == presetId).firstOrNull;
    if (preset == null) return;

    final blockConfig = preset.blocks.where((b) => b.id == blockId).firstOrNull;
    if (blockConfig == null) return;

    final cancelToken = CancelToken();
    _blocksCancelToken = cancelToken;

    // Reset the existing block in-place: clear content, set status=running
    // and push the badge to the WebView *before* kicking off the LLM call
    // so the user gets immediate visual feedback.
    final existing = await _repo.getByMessageId(sessionId, messageId);
    final previous = existing.where((b) => b.blockId == blockId).toList();
    if (previous.isEmpty) {
      // No prior result for this message+block — fall through to a fresh
      // run (which creates a new placeholder).
      debugPrint('[ExtPostGen] rerunBlock: no prior block found, starting fresh run');
    } else {
      final old = previous.first;
      await _repo.updateContent(old.id, '');
      await _repo.updateStatus(old.id, BlockRunStatus.running);
      final reset = old.copyWith(content: '', status: BlockRunStatus.running);
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(reset);
      _pushBadgeToBridge(charId, sessionId, messageId);
      debugPrint('[ExtPostGen] rerunBlock: reset existing block id=${old.id} to running');
    }

    final block = await _runSingleBlock(
      charId: charId,
      sessionId: sessionId,
      messageId: messageId,
      messages: messages,
      blockConfig: blockConfig,
      preset: preset,
      character: character,
      persona: persona,
      previousOutput: null,
      cancelToken: cancelToken,
    );

    if (block != null) {
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(block);
    }
  }

  /// Cancels any in-flight block generation for the current session.
  void cancelBlocks() {
    _blocksCancelToken?.cancel();
    _blocksCancelToken = null;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Chain execution
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _runChain({
    required String charId,
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required ExtensionPreset preset,
    required Character character,
    required Persona? persona,
    required CancelToken cancelToken,
  }) async {
    final blocks = preset.blocks
        .where((b) => b.enabled)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    debugPrint('[ExtPostGen] _runChain: enabledBlocks=${blocks.length} (of ${preset.blocks.length})');
    if (blocks.isEmpty) {
      debugPrint('[ExtPostGen] SKIP: no enabled blocks in preset');
      return;
    }

    String? previousOutput;
    Future<InfoBlock?>? previousFuture;

    for (final blockConfig in blocks) {
      if (cancelToken.isCancelled) break;

      final Future<InfoBlock?> blockFuture;

      if (blockConfig.dependsOnPrevious && previousFuture != null) {
        // Sequential: wait for previous block's result, pass its output.
        blockFuture = previousFuture.then((prev) async {
          if (cancelToken.isCancelled) return null;
          final output = prev?.content;
          return _runSingleBlock(
            charId: charId,
            sessionId: sessionId,
            messageId: messageId,
            messages: messages,
            blockConfig: blockConfig,
            preset: preset,
            character: character,
            persona: persona,
            previousOutput: output,
            cancelToken: cancelToken,
          );
        });
      } else {
        // Parallel: start immediately with last known previousOutput.
        final capturedPrev = previousOutput;
        blockFuture = _runSingleBlock(
          charId: charId,
          sessionId: sessionId,
          messageId: messageId,
          messages: messages,
          blockConfig: blockConfig,
          preset: preset,
          character: character,
          persona: persona,
          previousOutput: capturedPrev,
          cancelToken: cancelToken,
        );
      }

      // If this is a sequential gate we need to await in the loop so the
      // next block can decide whether to wait or not.
      if (blockConfig.dependsOnPrevious) {
        final result = await blockFuture;
        if (result != null) {
          previousOutput = result.content;
          _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(result);
        }
        previousFuture = null;
      } else {
        previousFuture = blockFuture;
        // Don't await — let it run in parallel. Chain completion via
        // side-effect in _runSingleBlock (notifier.addOrReplace).
        unawaited(blockFuture.then((result) {
          if (result != null) {
            _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(result);
          }
        }));
      }
    }

    // Await last dangling parallel future so the function doesn't return
    // before all blocks have settled.
    if (previousFuture != null) {
      await previousFuture;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Single block dispatch
  // ─────────────────────────────────────────────────────────────────────────

  Future<InfoBlock?> _runSingleBlock({
    required String charId,
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required ExtensionPreset preset,
    required Character character,
    required Persona? persona,
    required String? previousOutput,
    required CancelToken cancelToken,
  }) async {
    if (cancelToken.isCancelled) return null;

    debugPrint('[ExtPostGen] _runSingleBlock START: name="${blockConfig.name}" type=${blockConfig.type.name} order=${blockConfig.order}');

    // Insert a running placeholder so the badge updates immediately.
    final placeholderId = generateId();
    final placeholder = InfoBlock(
      id: placeholderId,
      sessionId: sessionId,
      messageId: messageId,
      blockId: blockConfig.id,
      blockName: blockConfig.name,
      blockType: blockConfig.type.name,
      content: '',
      createdAt: DateTime.now().millisecondsSinceEpoch,
      order: blockConfig.order,
      status: BlockRunStatus.running,
    );
    await _repo.insert(placeholder);
    _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(placeholder);
    debugPrint('[ExtPostGen] placeholder inserted: id=$placeholderId messageId=$messageId status=running');

    // Push badge immediately to the WebView so the user sees feedback even
    // before the ref.listen cycle fires. Skips silently if the WebView is
    // not mounted yet (bridge == null) — the badge will appear once the
    // widget is ready and _syncAllBlockStatuses runs.
    final bridge = _ref.read(chatBridgeRegistryProvider(charId));
    if (bridge != null) {
      unawaited(bridge.updateBlockStatus(messageId, 'running'));
      debugPrint('[ExtPostGen] pushed running badge to bridge for msg=$messageId');
    } else {
      debugPrint('[ExtPostGen] bridge=null for charId=$charId; badge will sync after WebView ready');
    }

    try {
      InfoBlock? result;

      switch (blockConfig.type) {
        case BlockType.infoblock:
          result = await _runInfoblock(
            charId: charId,
            sessionId: sessionId,
            messageId: messageId,
            messages: messages,
            blockConfig: blockConfig,
            preset: preset,
            character: character,
            persona: persona,
            previousOutput: previousOutput,
            cancelToken: cancelToken,
            placeholderId: placeholderId,
          );
        case BlockType.imageGen:
          result = await _runImageGen(
            sessionId: sessionId,
            messageId: messageId,
            messages: messages,
            blockConfig: blockConfig,
            character: character,
            persona: persona,
            previousOutput: previousOutput,
            cancelToken: cancelToken,
            placeholderId: placeholderId,
          );
        case BlockType.jsRunner:
          result = await _runJsRunner(
            charId: charId,
            sessionId: sessionId,
            messageId: messageId,
            messages: messages,
            blockConfig: blockConfig,
            character: character,
            previousOutput: previousOutput,
            cancelToken: cancelToken,
            placeholderId: placeholderId,
            placeholder: placeholder,
          );
      }

      return result;
    } catch (e) {
      if (!cancelToken.isCancelled) {
        debugPrint('[ExtPostGen] Error in block "${blockConfig.name}": $e');
      }
      await _repo.updateStatus(placeholderId, BlockRunStatus.error);
      final errored = placeholder.copyWith(status: BlockRunStatus.error);
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(errored);
      _pushBadgeToBridge(charId, sessionId, messageId);
      return errored;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Infoblock
  // ─────────────────────────────────────────────────────────────────────────

  Future<InfoBlock?> _runInfoblock({
    required String charId,
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required ExtensionPreset preset,
    required Character character,
    required Persona? persona,
    required String? previousOutput,
    required CancelToken cancelToken,
    required String placeholderId,
  }) async {
    debugPrint('[ExtPostGen] _runInfoblock START: name="${blockConfig.name}" promptLen=${blockConfig.prompt.length} apiConfigId="${blockConfig.apiConfigId}" model="${blockConfig.model}"');
    final infoBlockService = _ref.read(infoBlockServiceProvider);
    final content = await infoBlockService.generateSingleBlockContent(
      sessionId: sessionId,
      messageId: messageId,
      messages: messages,
      blockConfig: blockConfig,
      character: character,
      persona: persona?.name,
      previousOutput: previousOutput,
      cancelToken: cancelToken,
    );
    debugPrint('[ExtPostGen] _runInfoblock DONE: name="${blockConfig.name}" contentIsNull=${content == null} contentLen=${content?.length ?? 0}');

    if (cancelToken.isCancelled) {
      await _repo.updateStatus(placeholderId, BlockRunStatus.stopped);
      final stopped = InfoBlock(
        id: placeholderId,
        sessionId: sessionId,
        messageId: messageId,
        blockId: blockConfig.id,
        blockName: blockConfig.name,
        blockType: blockConfig.type.name,
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: blockConfig.order,
        status: BlockRunStatus.stopped,
      );
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(stopped);
      _pushBadgeToBridge(charId, sessionId, messageId);
      return stopped;
    }

    if (content == null || content.isEmpty) {
      await _repo.updateStatus(placeholderId, BlockRunStatus.error);
      final errored = InfoBlock(
        id: placeholderId,
        sessionId: sessionId,
        messageId: messageId,
        blockId: blockConfig.id,
        blockName: blockConfig.name,
        blockType: blockConfig.type.name,
        content: '',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: blockConfig.order,
        status: BlockRunStatus.error,
      );
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(errored);
      _pushBadgeToBridge(charId, sessionId, messageId);
      return errored;
    }

    // Update placeholder in DB with final content + done status.
    await _repo.updateContent(placeholderId, content);
    await _repo.updateStatus(placeholderId, BlockRunStatus.done);

    final done = InfoBlock(
      id: placeholderId,
      sessionId: sessionId,
      messageId: messageId,
      blockId: blockConfig.id,
      blockName: blockConfig.name,
      blockType: blockConfig.type.name,
      content: content,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      order: blockConfig.order,
      status: BlockRunStatus.done,
    );
    _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(done);
    _pushBadgeToBridge(charId, sessionId, messageId);
    return done;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Image gen
  // ─────────────────────────────────────────────────────────────────────────

  Future<InfoBlock?> _runImageGen({
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required Character character,
    required Persona? persona,
    required String? previousOutput,
    required CancelToken cancelToken,
    required String placeholderId,
  }) async {
    final imgGenSettingsAsync = _ref.read(imageGenSettingsProvider);
    final imgGenSettings = imgGenSettingsAsync.value;
    if (imgGenSettings == null || !imgGenSettings.enabled) {
      await _repo.updateStatus(placeholderId, BlockRunStatus.done);
      return null;
    }

    // Build image prompt: use previousOutput (infoblock) if available,
    // otherwise fall back to last assistant message content.
    final lastAssistant = messages.lastWhere(
      (m) => m.role == 'assistant',
      orElse: () => messages.last,
    );
    final promptSource = previousOutput?.isNotEmpty == true
        ? previousOutput!
        : lastAssistant.content;

    // Extract [img gen:...] tag from the source text.
    final imageService = await _ref.read(imageGenSettingsProvider.notifier).getServiceAsync();
    if (!imageService.hasImageGenTags(promptSource)) {
      // No tag — nothing to generate.
      await _repo.updateStatus(placeholderId, BlockRunStatus.done);
      return null;
    }

    final instructions = imageService.extractImageGenInstructions(promptSource);
    if (instructions.isEmpty) {
      await _repo.updateStatus(placeholderId, BlockRunStatus.done);
      return null;
    }

    final instruction = instructions.first;
    final rawPrompt = instruction['prompt'] as String? ?? '';
    if (rawPrompt.isEmpty) {
      await _repo.updateStatus(placeholderId, BlockRunStatus.done);
      return null;
    }

    try {
      final imageBytes = await imageService.generateImage(
        settings: imgGenSettings,
        prompt: rawPrompt,
        llmEndpoint: '',
        llmApiKey: '',
        llmModel: '',
        character: character,
        persona: persona,
        cancelToken: cancelToken,
      );

      if (cancelToken.isCancelled) {
        await _repo.updateStatus(placeholderId, BlockRunStatus.stopped);
        return null;
      }

      // Save to disk using the same path convention as inline image gen.
      final storage = await _ref.read(imageStorageProvider.future);
      final dir = Directory(p.join(storage.baseDir, 'generated'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final filename = 'extblock_${DateTime.now().millisecondsSinceEpoch}.png';
      final filePath = p.join(dir.path, filename);
      await File(filePath).writeAsBytes(imageBytes);

      final content = '[IMG:RESULT:$filePath]';
      await _repo.updateContent(placeholderId, content);
      await _repo.updateStatus(placeholderId, BlockRunStatus.done);

      final done = InfoBlock(
        id: placeholderId,
        sessionId: sessionId,
        messageId: messageId,
        blockId: blockConfig.id,
        blockName: blockConfig.name,
        blockType: blockConfig.type.name,
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: blockConfig.order,
        status: BlockRunStatus.done,
      );
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(done);
      return done;
    }     on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        await _repo.updateStatus(placeholderId, BlockRunStatus.stopped);
        return null;
      }
      rethrow;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // JS Runner
  // ─────────────────────────────────────────────────────────────────────────

  Future<InfoBlock?> _runJsRunner({
    required String charId,
    required String sessionId,
    required String messageId,
    required List<ChatMessage> messages,
    required BlockConfig blockConfig,
    required Character character,
    required String? previousOutput,
    required CancelToken cancelToken,
    required String placeholderId,
    required InfoBlock placeholder,
  }) async {
    if (cancelToken.isCancelled) {
      await _repo.updateStatus(placeholderId, BlockRunStatus.stopped);
      return placeholder.copyWith(status: BlockRunStatus.stopped);
    }

    if (blockConfig.script.isEmpty) {
      debugPrint('[ExtPostGen] jsRunner block "${blockConfig.name}" — script is empty');
      await _repo.updateStatus(placeholderId, BlockRunStatus.done);
      _pushBadgeToBridge(charId, sessionId, messageId);
      return placeholder.copyWith(status: BlockRunStatus.done);
    }

    final bridge = _ref.read(chatBridgeRegistryProvider(charId));
    if (bridge == null) {
      debugPrint('[ExtPostGen] jsRunner block "${blockConfig.name}" — bridge not available (WebView not mounted)');
      await _repo.updateStatus(placeholderId, BlockRunStatus.error);
      final errored = placeholder.copyWith(status: BlockRunStatus.error);
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(errored);
      _pushBadgeToBridge(charId, sessionId, messageId);
      return errored;
    }

    try {
      final content = await bridge.runJsBlock(
        script: blockConfig.script,
        messages: messages,
        character: character,
        previousOutput: previousOutput,
        contextMessageCount: blockConfig.contextMessageCount,
        cancelToken: cancelToken,
      );

      if (cancelToken.isCancelled) {
        await _repo.updateStatus(placeholderId, BlockRunStatus.stopped);
        final stopped = placeholder.copyWith(status: BlockRunStatus.stopped);
        _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(stopped);
        _pushBadgeToBridge(charId, sessionId, messageId);
        return stopped;
      }

      await _repo.updateContent(placeholderId, content);
      await _repo.updateStatus(placeholderId, BlockRunStatus.done);

      final done = InfoBlock(
        id: placeholderId,
        sessionId: sessionId,
        messageId: messageId,
        blockId: blockConfig.id,
        blockName: blockConfig.name,
        blockType: blockConfig.type.name,
        content: content,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        order: blockConfig.order,
        status: BlockRunStatus.done,
      );
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(done);
      _pushBadgeToBridge(charId, sessionId, messageId);
      return done;
    } catch (e) {
      if (cancelToken.isCancelled) {
        await _repo.updateStatus(placeholderId, BlockRunStatus.stopped);
        final stopped = placeholder.copyWith(status: BlockRunStatus.stopped);
        _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(stopped);
        _pushBadgeToBridge(charId, sessionId, messageId);
        return stopped;
      }
      debugPrint('[ExtPostGen] jsRunner "${blockConfig.name}" failed: $e');
      await _repo.updateStatus(placeholderId, BlockRunStatus.error);
      final errored = placeholder.copyWith(status: BlockRunStatus.error);
      _ref.read(infoBlocksProvider(sessionId).notifier).addOrReplace(errored);
      _pushBadgeToBridge(charId, sessionId, messageId);
      return errored;
    }
  }
}
