import 'dart:async';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/models/preset.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/character_provider.dart';
import '../bridge/chat_bridge_controller.dart';
import '../bridge/chat_webview_keep_alive.dart';
import '../bridge/chat_webview_settings.dart';
import '../chat_provider.dart';
import '../chat_state.dart';
import '../editing_message_provider.dart';
import '../../../core/models/chat_message.dart';
import '../../../../shared/theme/app_colors.dart';
import '../../../../shared/theme/theme_font_provider.dart';
import '../../extensions/models/block_run_status.dart';
import '../../extensions/models/info_block.dart';
import '../../extensions/providers/info_blocks_provider.dart';
import '../../extensions/services/extension_post_gen_service.dart';
import '../bridge/chat_bridge_registry.dart';
import 'webview_callbacks.dart';

const String _kStreamingId = '__streaming__';

class ChatWebViewWidget extends ConsumerStatefulWidget {
  final String charId;
  final String? charName;
  final String? charColor;
  final String? personaName;
  final String? personaColor;
  final String? charAvatarPath;
  final String? personaAvatarPath;
  final String? bgImagePath;
  final double bgBlur;
  final double bgOpacity;
  final double bgNoiseOpacity;
  final double bgNoiseIntensity;
  final double bgDim;
  final List<ChatMessage> messages;
  final bool isGenerating;
  final bool isGeneratingImage;
  final double bottomInset;
  final double topInset;
  final String? searchQuery;
  final int searchCurrentIndex;
  final String? chatLayout;
  /// Changes when preset colors/layout tokens affecting the WebView change.
  final String? themeSyncKey;
  final double elementOpacity;
  final double elementBlur;
  final int greetingTotal;
  final String? chatFontName;
  final String? chatFontDataUrl;
  final double chatFontSize;
  final double chatLetterSpacing;
  final List<dynamic> memoryEntries;
  final List<dynamic> memoryDrafts;
  final String? sessionId;
  final int visibleStartIndex;
  final String? regenTargetId;
  final bool isSelectionMode;
  final bool batterySaver;
  final bool hideMessageId;
  final bool hideGenerationTime;
  final bool hideTokenCount;
  final bool disableSwipeRegeneration;

  // Callback objects
  final MessageActionsCallbacks messageActions;
  final EditActionsCallbacks editActions;
  final ImageGenCallbacks imageGenActions;
  final ScrollCallbacks scrollActions;
  final MiscCallbacks miscActions;

  const ChatWebViewWidget({
    super.key,
    required this.charId,
    this.charName,
    this.charColor,
    this.personaName,
    this.personaColor,
    this.charAvatarPath,
    this.personaAvatarPath,
    this.bgImagePath,
    this.bgBlur = 0.0,
    this.bgOpacity = 1.0,
    this.bgNoiseOpacity = 0.0,
    this.bgNoiseIntensity = 1.0,
    this.bgDim = 0.0,
    required this.messages,
    required this.isGenerating,
    this.isGeneratingImage = false,
    this.bottomInset = 0,
    this.topInset = 0,
    this.searchQuery,
    this.searchCurrentIndex = 0,
    this.chatLayout,
    this.themeSyncKey,
    this.elementOpacity = 0.8,
    this.elementBlur = 12,
    this.greetingTotal = 0,
    this.chatFontName,
    this.chatFontDataUrl,
    this.chatFontSize = 15.0,
    this.chatLetterSpacing = 0.0,
    this.memoryEntries = const [],
    this.memoryDrafts = const [],
    this.sessionId,
    this.visibleStartIndex = 0,
    this.regenTargetId,
    this.isSelectionMode = false,
    this.batterySaver = false,
    this.hideMessageId = false,
    this.hideGenerationTime = false,
    this.hideTokenCount = false,
    this.disableSwipeRegeneration = false,
    this.messageActions = const MessageActionsCallbacks(),
    this.editActions = const EditActionsCallbacks(),
    this.imageGenActions = const ImageGenCallbacks(),
    this.scrollActions = const ScrollCallbacks(),
    this.miscActions = const MiscCallbacks(),
  });

  @override
  ConsumerState<ChatWebViewWidget> createState() => ChatWebViewWidgetState();
}

class ChatWebViewWidgetState extends ConsumerState<ChatWebViewWidget>
    with AutomaticKeepAliveClientMixin {
  ChatBridgeController? _bridge;
  bool _ready = false;
  bool _streamingSent = false;
  bool _regenStreamingSent = false;
  bool _wasGenerating = false;
  bool _sessionSwitching = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    // Unregister bridge so the service doesn't hold a stale reference.
    ref.read(chatBridgeRegistryProvider(widget.charId).notifier).state = null;
    super.dispose();
  }

  /// Shallow comparison of two regex lists by id + disabled state.
  bool _regexListChanged(List<PresetRegex> a, List<PresetRegex> b) {
    if (a.length != b.length) return true;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].disabled != b[i].disabled) return true;
    }
    return false;
  }

  Future<void> _syncIdentityFromWidget() async {
    final bridge = _bridge;
    if (bridge == null) return;

    await bridge.setIdentity(
      charName: widget.charName,
      charColor: widget.charColor,
      personaName: widget.personaName,
      layout: widget.chatLayout,
      charAvatarPath: widget.charAvatarPath,
      personaAvatarPath: widget.personaAvatarPath,
      greetingTotal: widget.greetingTotal,
    );
  }

  Future<void> _initWebView() async {
    final bridge = _bridge;
    if (bridge == null) return;

    final character = ref.read(characterByIdProvider(widget.charId));
    final effectivePersona = ref.read(effectivePersonaForChatProvider(
      (charId: widget.charId, sessionId: widget.sessionId),
    ));
    final displayRegexes = ref.read(displayRegexesProvider).valueOrNull ?? [];
    bridge.setRegexContext(displayRegexes, character, effectivePersona);

    await _syncIdentityFromWidget();

    await _applyThemeToBridge();

    await _bridge!.setBackgroundNoise(widget.bgNoiseOpacity, widget.bgNoiseIntensity);

    await _bridge!.setChatFont(
      fontName: widget.chatFontName,
      fontDataUrl: widget.chatFontDataUrl,
      fontSize: widget.chatFontSize,
      letterSpacing: widget.chatLetterSpacing,
    );

    await _bridge!.setMessageSettings(
      batterySaver: widget.batterySaver,
      hideMessageId: widget.hideMessageId,
      hideGenerationTime: widget.hideGenerationTime,
      hideTokenCount: widget.hideTokenCount,
      disableSwipeRegeneration: widget.disableSwipeRegeneration,
    );

    // Persona/char identity can resolve while theme and assets load above.
    await _syncIdentityFromWidget();
    await _bridge!.setMessages(widget.messages, visibleStartIndex: widget.visibleStartIndex);
    _bridge!.updateMemoryBookData(
      entries: widget.memoryEntries.map((e) => {'status': e.status, 'messageIds': e.messageIds}).toList(),
      pendingDrafts: widget.memoryDrafts.map((e) => {'messageIds': e.messageIds}).toList(),
    );
    if (widget.bottomInset > 0) {
      await _bridge!.setBottomPadding(widget.bottomInset);
    }
    if (widget.topInset > 0) {
      await _bridge!.setTopPadding(widget.topInset);
    }
    if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty) {
      await _bridge!.setSearch(query: widget.searchQuery!, activeIndex: widget.searchCurrentIndex);
    }
    await _bridge!.setSelectionMode(widget.isSelectionMode);
    await _bridge!.scrollToBottom();
    final initialAnyGen = widget.isGenerating || widget.isGeneratingImage;
    _bridge!.isGenerating = initialAnyGen;
    unawaited(_bridge!.evalJs('if (window.bridge) window.bridge.isGenerating = $initialAnyGen;'));
    _ready = true;

    // Push initial block statuses so badges appear on first load.
    // Run async so we can await the notifier's DB load if it hasn't
    // completed yet (InfoBlocksNotifier starts with [] and loads async).
    unawaited(_syncAllBlockStatuses());
  }

  /// Reads all info blocks for the current session from DB (forcing a refresh
  /// if the notifier hasn't loaded yet) and pushes the aggregated status for
  /// each message to the bridge so the ext-block badge appears.
  Future<void> _syncAllBlockStatuses() async {
    final sid = widget.sessionId;
    if (sid == null || sid.isEmpty || _bridge == null) {
      debugPrint('[BlockBadge] _syncAllBlockStatuses: skip (sid=$sid, bridge=${_bridge != null})');
      return;
    }

    // Force a fresh read from DB so we don't miss blocks that loaded before
    // the WebView was ready.
    final notifier = ref.read(infoBlocksProvider(sid).notifier);
    await notifier.refresh();

    final blocks = ref.read(infoBlocksProvider(sid));
    debugPrint('[BlockBadge] _syncAllBlockStatuses: sessionId=$sid, blocks=${blocks.length}');
    if (blocks.isEmpty) return;

    // Group by messageId and compute aggregated status.
    final byMsg = <String, List<InfoBlock>>{};
    for (final b in blocks) {
      byMsg.putIfAbsent(b.messageId, () => []).add(b);
    }

    for (final entry in byMsg.entries) {
      final msgId = entry.key;
      final mb = entry.value;
      String status;
      if (mb.any((b) => b.status == BlockRunStatus.running)) {
        status = 'running';
      } else if (mb.any((b) => b.status == BlockRunStatus.error)) {
        status = 'error';
      } else {
        status = 'done';
      }
      debugPrint('[BlockBadge] _syncAllBlockStatuses: msgId=$msgId status=$status count=${mb.length}');
      unawaited(_bridge!.updateBlockStatus(msgId, status));
    }
  }

  Future<void> applyIdentity({
    String? charName,
    String? charColor,
    String? personaName,
    String? charAvatarPath,
    String? personaAvatarPath,
    int? greetingTotal,
  }) {
    final bridge = _bridge;
    if (bridge == null || !_ready) return Future.value();
    return bridge.setIdentity(
      charName: charName ?? widget.charName,
      charColor: charColor ?? widget.charColor,
      personaName: personaName ?? widget.personaName,
      layout: widget.chatLayout,
      charAvatarPath: charAvatarPath ?? widget.charAvatarPath,
      personaAvatarPath: personaAvatarPath ?? widget.personaAvatarPath,
      greetingTotal: greetingTotal ?? widget.greetingTotal,
    );
  }

  bool _identityChanged(ChatWebViewWidget old) {
    return widget.charName != old.charName ||
        widget.charColor != old.charColor ||
        widget.personaName != old.personaName ||
        widget.charAvatarPath != old.charAvatarPath ||
        widget.personaAvatarPath != old.personaAvatarPath ||
        widget.chatLayout != old.chatLayout ||
        widget.greetingTotal != old.greetingTotal;
  }

  Future<void> _applySessionSwitch(ChatWebViewWidget old) async {
    final bridge = _bridge;
    if (bridge == null) return;

    unawaited(bridge.evalJs('window.bridge?.clearAll();'));
    if (mounted) setState(() => _sessionSwitching = true);
    if (widget.charId != old.charId) {
      await bridge.setIdentity(
        charName: widget.charName,
        charColor: widget.charColor,
        personaName: widget.personaName,
        layout: widget.chatLayout,
        charAvatarPath: widget.charAvatarPath,
        personaAvatarPath: widget.personaAvatarPath,
        greetingTotal: widget.greetingTotal,
      );
      await _applyThemeToBridge();

      await bridge.setBackgroundNoise(
        widget.bgNoiseOpacity,
        widget.bgNoiseIntensity,
      );
      await bridge.setChatFont(
        fontName: widget.chatFontName,
        fontDataUrl: widget.chatFontDataUrl,
        fontSize: widget.chatFontSize,
        letterSpacing: widget.chatLetterSpacing,
      );
    } else {
      await bridge.setIdentity(
        charName: widget.charName,
        charColor: widget.charColor,
        personaName: widget.personaName,
        layout: widget.chatLayout,
        charAvatarPath: widget.charAvatarPath,
        personaAvatarPath: widget.personaAvatarPath,
        greetingTotal: widget.greetingTotal,
      );
    }

    await bridge.clearAll();
    await bridge.setMessages(
      widget.messages,
      visibleStartIndex: widget.visibleStartIndex,
    );
    // Restore block badges after session switch.
    unawaited(_syncAllBlockStatuses());
    Future.delayed(const Duration(milliseconds: 150), () {
      bridge.scrollToBottom();
      if (mounted) setState(() => _sessionSwitching = false);
    });
    _wasGenerating = widget.isGenerating;
    _streamingSent = false;
  }

  @override
  void didUpdateWidget(ChatWebViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready || _bridge == null) return;

    if (widget.memoryEntries != oldWidget.memoryEntries || widget.memoryDrafts != oldWidget.memoryDrafts) {
      _bridge!.updateMemoryBookData(
        entries: widget.memoryEntries.map((e) => {'status': e.status, 'messageIds': e.messageIds}).toList(),
        pendingDrafts: widget.memoryDrafts.map((e) => {'messageIds': e.messageIds}).toList(),
      );
    }

    if (widget.charId != oldWidget.charId || widget.sessionId != oldWidget.sessionId) {
      unawaited(_applySessionSwitch(oldWidget));
      return;
    }

    if (_identityChanged(oldWidget)) {
      _bridge!.setIdentity(
        charName: widget.charName,
        charColor: widget.charColor,
        personaName: widget.personaName,
        layout: widget.chatLayout,
        charAvatarPath: widget.charAvatarPath,
        personaAvatarPath: widget.personaAvatarPath,
        greetingTotal: widget.greetingTotal,
      );
    }

    if (widget.themeSyncKey != oldWidget.themeSyncKey ||
        widget.chatLayout != oldWidget.chatLayout ||
        widget.elementOpacity != oldWidget.elementOpacity ||
        widget.elementBlur != oldWidget.elementBlur ||
        widget.chatFontSize != oldWidget.chatFontSize) {
      _bridge!.applyTheme(_buildThemeMap());
    }

    if (widget.bgImagePath != oldWidget.bgImagePath ||
        widget.bgBlur != oldWidget.bgBlur ||
        widget.bgOpacity != oldWidget.bgOpacity ||
        widget.bgDim != oldWidget.bgDim) {
      _bridge!.setBackgroundImage(widget.bgImagePath, widget.bgBlur.toInt(), widget.bgOpacity);
      _bridge!.applyTheme({'bg-dim': widget.bgDim.toStringAsFixed(2)});
    }

    if (widget.bgNoiseOpacity != oldWidget.bgNoiseOpacity ||
        widget.bgNoiseIntensity != oldWidget.bgNoiseIntensity) {
      _bridge!.setBackgroundNoise(widget.bgNoiseOpacity, widget.bgNoiseIntensity);
    }

    if (widget.chatFontName != oldWidget.chatFontName ||
        widget.chatFontDataUrl != oldWidget.chatFontDataUrl ||
        widget.chatFontSize != oldWidget.chatFontSize ||
        widget.chatLetterSpacing != oldWidget.chatLetterSpacing) {
      _bridge!.setChatFont(
        fontName: widget.chatFontName,
        fontDataUrl: widget.chatFontDataUrl,
        fontSize: widget.chatFontSize,
        letterSpacing: widget.chatLetterSpacing,
      );
    }

    if (widget.isSelectionMode != oldWidget.isSelectionMode) {
      _bridge!.setSelectionMode(widget.isSelectionMode);
    }

    if (widget.batterySaver != oldWidget.batterySaver ||
        widget.hideMessageId != oldWidget.hideMessageId ||
        widget.hideGenerationTime != oldWidget.hideGenerationTime ||
        widget.hideTokenCount != oldWidget.hideTokenCount ||
        widget.disableSwipeRegeneration != oldWidget.disableSwipeRegeneration) {
      _bridge!.setMessageSettings(
        batterySaver: widget.batterySaver,
        hideMessageId: widget.hideMessageId,
        hideGenerationTime: widget.hideGenerationTime,
        hideTokenCount: widget.hideTokenCount,
        disableSwipeRegeneration: widget.disableSwipeRegeneration,
      );
    }

    if (widget.searchQuery != oldWidget.searchQuery || widget.searchCurrentIndex != oldWidget.searchCurrentIndex) {
      if (widget.searchQuery != null && widget.searchQuery!.isNotEmpty) {
        _bridge!.setSearch(query: widget.searchQuery!, activeIndex: widget.searchCurrentIndex);
      } else {
        _bridge!.setSearch(query: '', activeIndex: -1);
      }
    }

    if (widget.bottomInset != oldWidget.bottomInset) {
      _bridge!.setBottomPadding(widget.bottomInset);
    }

    if (widget.topInset != oldWidget.topInset) {
      _bridge!.setTopPadding(widget.topInset);
    }

    final anyGenerating = widget.isGenerating || widget.isGeneratingImage;
    final oldAnyGenerating = oldWidget.isGenerating || oldWidget.isGeneratingImage;
    if (anyGenerating != oldAnyGenerating || widget.isGenerating != oldWidget.isGenerating) {
      _bridge!.isGenerating = widget.isGenerating;
      _bridge!.isGeneratingImage = widget.isGeneratingImage;
      _bridge!.evalJs('if (window.bridge) { window.bridge.setGenerating(${widget.isGenerating}); window.bridge.isGeneratingImage = ${widget.isGeneratingImage}; }');
      if (!anyGenerating && widget.messages.isNotEmpty) {
        // Generation finished → mark the actual last message; bridge injects
        // the regen button only when that last message is from the user.
        _bridge?.setLastMessage(widget.messages.last.id);
      } else if (widget.isGenerating) {
        // Generation started → remove regen button
        _bridge?.setLastMessage(null);
      }
    }

    if (_wasGenerating && !widget.isGenerating) {
      final finishedRegenId = oldWidget.regenTargetId;
      if (finishedRegenId != null) {
        final finalMsg = widget.messages.where((m) => m.id == finishedRegenId).firstOrNull;
        if (finalMsg != null) {
          _bridge?.updateMessage(finalMsg);
        }
      }
      if (!_regenStreamingSent) {
        _bridge?.removeMessage(_kStreamingId);
      }
      _streamingSent = false;
      _regenStreamingSent = false;
    }

    // Sync messages BEFORE injecting the typing placeholder, so the new user
    // message lands at its correct position (placeholder is appended after).
    if (!identical(oldWidget.messages, widget.messages) &&
        !_listsEqual(oldWidget.messages, widget.messages)) {
      _syncMessages(oldWidget.messages);
    }

    // Fresh generation started (no regenTargetId) → inject typing placeholder immediately
    final shouldInjectPlaceholder = !_wasGenerating &&
        widget.isGenerating &&
        widget.regenTargetId == null &&
        !_streamingSent;
    _wasGenerating = widget.isGenerating;
    if (shouldInjectPlaceholder) {
      final typingMsg = ChatMessage(
        id: _kStreamingId,
        role: 'assistant',
        content: '',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isTyping: true,
      );
      _bridge?.appendMessage(typingMsg);
      _streamingSent = true;
    }
  }

  static bool _listsEqual(List<ChatMessage> a, List<ChatMessage> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  void _syncMessages(List<ChatMessage> oldMsgs) {
    if (_sessionSwitching) return;
    final oldIds = oldMsgs.map((m) => m.id).toList();
    final newIds = widget.messages.map((m) => m.id).toList();
    final skipLast = widget.isGenerating && _streamingSent;
    final newLen = newIds.length - (skipLast ? 1 : 0);

    if (oldIds.isEmpty) {
      _bridge?.setMessages(widget.messages, visibleStartIndex: widget.visibleStartIndex);
      return;
    }

    if (newIds.isEmpty) {
      _bridge?.clearAll();
      return;
    }

    if (newIds.length > oldIds.length) {
      final oldFirstId = oldIds.first;
      final newIdx = newIds.indexOf(oldFirstId);
      if (newIdx > 0) {
        _bridge?.prependMessages(
          widget.messages.sublist(0, newIdx),
          visibleStartIndex: widget.visibleStartIndex,
        );
        return;
      }
      if (newLen > oldIds.length) {
        final appends = widget.messages.sublist(
          oldIds.length,
          newLen,
        );
        _bridge?.appendMessages(
          appends,
          startIndex: widget.visibleStartIndex + oldIds.length,
        );
        if (appends.isNotEmpty && !widget.isGenerating) {
          _bridge?.setLastMessage(widget.messages.lastOrNull?.id);
        }
        return;
      }
    }

    if (newIds.length < oldIds.length) {
      final newFirstId = newIds.first;
      final oldIdx = oldIds.indexOf(newFirstId);
      if (oldIdx > 0) {
        for (int i = 0; i < oldIdx; i++) {
          _bridge?.removeMessage(oldIds[i]);
        }
        return;
      }
      final newLastId = newIds.last;
      final oldLastIdx = oldIds.indexOf(newLastId);
      if (oldLastIdx >= 0 && newIds.length == oldLastIdx + 1) {
        for (int i = oldIds.length - 1; i > oldLastIdx; i--) {
          _bridge?.removeMessage(oldIds[i]);
        }
        if (!widget.isGenerating) {
          _bridge?.setLastMessage(widget.messages.lastOrNull?.id);
        }
        return;
      }
      _bridge?.clearAll();
      _bridge?.setMessages(widget.messages, visibleStartIndex: widget.visibleStartIndex);
      return;
    }

    // Same length - check for updates
    final minLen = newLen < oldIds.length ? newLen : oldIds.length;
    for (int i = 0; i < minLen; i++) {
      if (i >= newIds.length) break;
      if (newIds[i] != oldIds[i]) {
        _bridge?.clearAll();
        _bridge?.setMessages(widget.messages, visibleStartIndex: widget.visibleStartIndex);
        return;
      }
      final o = oldMsgs[i];
      final n = widget.messages[i];
      
      final contentChanged = o.content != n.content;
      final swipeChanged = o.swipeId != n.swipeId;
      final swipeTotalChanged = o.swipes.length != n.swipes.length;
      final hiddenChanged = o.isHidden != n.isHidden;
      final typingChanged = o.isTyping != n.isTyping;
      final errorChanged = o.isError != n.isError;
      final guidanceChanged = o.guidanceText != n.guidanceText;
      final greetingChanged = o.greetingIndex != n.greetingIndex;
      
      final needsUpdate = contentChanged || swipeChanged || hiddenChanged || 
                         swipeTotalChanged || typingChanged || errorChanged ||
                         guidanceChanged || greetingChanged;
      
      if (needsUpdate) {
        _bridge?.updateMessage(n);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final character = ref.watch(characterByIdProvider(widget.charId));
    final effectivePersona = ref.watch(effectivePersonaForChatProvider(
      (charId: widget.charId, sessionId: widget.sessionId),
    ));
    final displayRegexes = ref.watch(displayRegexesProvider).valueOrNull ?? [];
    
    if (_bridge != null) {
      _bridge!.setRegexContext(displayRegexes, character, effectivePersona);
    }

    // Re-render all messages when display regex list changes (toggle, add, remove).
    ref.listen<AsyncValue<List<PresetRegex>>>(
      displayRegexesProvider,
      (prev, next) {
        if (!_ready || _bridge == null) return;
        final oldList = prev?.valueOrNull ?? [];
        final newList = next.valueOrNull ?? [];
        if (_regexListChanged(oldList, newList)) {
          _bridge!.setRegexContext(newList, character, effectivePersona);
          _bridge!.setMessages(widget.messages, visibleStartIndex: widget.visibleStartIndex);
        }
      },
    );

    ref.listen<String?>(
      editingMessageIdProvider(widget.charId),
      (prev, next) {
        if (!_ready || _bridge == null) return;
        if (prev != null && prev != next) {
          _bridge!.stopEdit(prev);
          final oldMsg = widget.messages.where((m) => m.id == prev).firstOrNull;
          if (oldMsg != null) {
            _bridge!.updateMessage(oldMsg);
          }
        }
        if (next != null) {
          _bridge!.startEdit(next);
        }
      },
    );

    ref.listen<StreamingState>(
      streamingStateProvider(widget.charId),
      (prev, next) {
        if (!_ready || _bridge == null) return;
        if (next.text.isEmpty && next.reasoning == null) return;

        final regenId = widget.regenTargetId;
        if (regenId != null) {
          final idx = widget.messages.indexWhere((m) => m.id == regenId);
          if (idx >= 0) {
            final original = widget.messages[idx];
            final updated = original.copyWith(
              content: next.text,
              reasoning: next.reasoning ?? original.reasoning,
              isTyping: true,
            );
            _bridge?.updateMessage(updated);
            _regenStreamingSent = true;
          }
          return;
        }

        final msg = ChatMessage(
          id: _kStreamingId,
          role: 'assistant',
          content: next.text,
          reasoning: next.reasoning,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          isTyping: true,
        );

        if (!_streamingSent) {
          _bridge?.appendMessage(msg);
          _streamingSent = true;
        } else {
          _bridge?.updateMessage(msg);
        }
      },
    );

    // Listen to infoBlocks changes and update the ext-block badge for each
    // affected message. Computes aggregated status from the block lists
    // directly so it doesn't depend on notifier state timing.
    //
    // NOTE: we do NOT gate on `_ready` here. The initial DB load fires
    // shortly after the notifier is created ([] → [stored blocks]). If
    // the WebView happens to be ready by then we push immediately; if not
    // we schedule via _syncAllBlockStatuses which is called once _ready=true.
    final sessionId = widget.sessionId;
    if (sessionId != null && sessionId.isNotEmpty) {
      ref.listen<List<InfoBlock>>(
        infoBlocksProvider(sessionId),
        (prev, next) {
          if (_bridge == null) return;
          // Compute aggregated status from a flat list of blocks.
          String? aggStatus(List<InfoBlock> blocks, String msgId) {
            final mb = blocks.where((b) => b.messageId == msgId).toList();
            if (mb.isEmpty) return null;
            if (mb.any((b) => b.status == BlockRunStatus.running)) return 'running';
            if (mb.any((b) => b.status == BlockRunStatus.error)) return 'error';
            return 'done';
          }
          final prevList = prev ?? [];
          // Collect all unique messageIds appearing in either list.
          final allIds = {
            for (final b in prevList) b.messageId,
            for (final b in next) b.messageId,
          };
          for (final msgId in allIds) {
            final oldStatus = aggStatus(prevList, msgId);
            final newStatus = aggStatus(next, msgId);
            if (newStatus != oldStatus) {
              // If the bridge isn't ready yet, defer until it is.
              if (_ready) {
                unawaited(_bridge!.updateBlockStatus(msgId, newStatus));
              } else {
                // Will be picked up by _syncAllBlockStatuses() once ready.
              }
            }
          }
        },
      );
    }

    final bgImageBytes = ref.watch(bgImageBytesProvider);

    return Stack(
      children: [
        // Theme surface color — always visible behind the transparent WebView
        // so there's no white flash when no bg image is set.
        Positioned.fill(
          child: ColoredBox(color: Theme.of(context).colorScheme.surface),
        ),
        // Background image rendered in Flutter so it shows through the
        // transparent WebView. Uses decoded bytes (same as GlazeBackground)
        // because preset.bgImage is a base64 data URI, not a file path.
        if (bgImageBytes != null) ...[
          Positioned.fill(
            child: Opacity(
              opacity: widget.bgOpacity,
              child: widget.bgBlur > 0
                  ? ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: widget.bgBlur,
                        sigmaY: widget.bgBlur,
                        tileMode: TileMode.clamp,
                      ),
                      child: Image.memory(
                        bgImageBytes,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    )
                  : Image.memory(
                      bgImageBytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
            ),
          ),
          if (widget.bgDim > 0)
            Positioned.fill(
              child: Container(color: Colors.black.withValues(alpha: widget.bgDim)),
            ),
        ],
        AnimatedOpacity(
          opacity: _sessionSwitching ? 0.45 : 1.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: _sessionSwitching,
            child: InAppWebView(
          keepAlive: chatWebViewKeepAlive,
          initialFile: 'assets/chat_webview/index.html',
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            domStorageEnabled: true,
            transparentBackground: chatWebViewTransparentBackground(),
            isInspectable: true,
            useHybridComposition: true,
            cacheEnabled: true,
            useWideViewPort: true,
            loadWithOverviewMode: true,
            allowFileAccess: true,
            allowContentAccess: true,
            allowFileAccessFromFileURLs: true,
            allowUniversalAccessFromFileURLs: true,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
          ),
          onWebViewCreated: (controller) async {
            _bridge = ChatBridgeController(controller);
            // Register bridge in the registry so services can access it.
            ref.read(chatBridgeRegistryProvider(widget.charId).notifier).state = _bridge;
            unawaited(controller.evaluateJavascript(source: 'if(window.bridge) window.bridge.clearAll();'));
            _bridge!.onMessageContext = (id, isUser, isSystem, content) {
              final allMsgs = ref.read(chatProvider(widget.charId)).value?.messages ?? [];
              final idx = allMsgs.indexWhere((m) => m.id == id);
              if (idx < 0) return;
              widget.messageActions.onMessageContext?.call(idx, id, isUser, isSystem, content);
            };
            _bridge!.onSwipe = (id, direction) {
              widget.messageActions.onSwipe?.call(id, direction);
            };
            _bridge!.onChangeGreeting = (id, dir) {
              widget.messageActions.onChangeGreeting?.call(id, dir);
            };
            _bridge!.onHeaderScroll = (hidden) {
              widget.scrollActions.onHeaderScroll?.call(hidden);
            };
            _bridge!.onScrollToBottomVisibility = (visible) {
              widget.scrollActions.onScrollToBottomVisibility?.call(visible);
            };
            _bridge!.onRegenerate = (id) {
              widget.messageActions.onRegenerate?.call(id);
            };
            _bridge!.onSelectionAction = (action, text) {
              widget.miscActions.onSelectionAction?.call(action, text);
            };
            _bridge!.onSelectionChange = (ids) {
              widget.miscActions.onSelectionChange?.call(ids);
            };
            _bridge!.onEditSave = (id, text) {
              widget.editActions.onEditSave?.call(id, text);
            };
            _bridge!.onEditCancel = (id) {
              widget.editActions.onEditCancel?.call(id);
            };
            _bridge!.onEditFocusChange = (id, focused) {
              widget.editActions.onEditFocusChange?.call(id, focused);
            };
            _bridge!.onImageClick = (imageUrl) {
              widget.miscActions.onImageClick?.call(imageUrl);
            };
            _bridge!.onGuidedSwipe = (id, guidanceText) {
              widget.messageActions.onGuidedSwipe?.call(id, guidanceText);
            };
            _bridge!.onMemoryClick = (id) {
              widget.messageActions.onMemoryClick?.call(id);
            };
            _bridge!.onToggleHidden = (id) {
              widget.messageActions.onToggleHidden?.call(id);
            };
            _bridge!.onInjectClick = (id) {
              widget.messageActions.onInjectClick?.call(id);
            };
            _bridge!.onImgRetry = (instruction, messageId) {
              widget.imageGenActions.onImgRetry?.call(instruction, messageId);
            };
            _bridge!.onImgFind = (instruction, messageId) {
              widget.imageGenActions.onImgFind?.call(instruction, messageId);
            };
            _bridge!.onImgRegen = (instruction, messageId) {
              widget.imageGenActions.onImgRegen?.call(instruction, messageId);
            };
            _bridge!.onImgCancel = () {
              widget.imageGenActions.onImgCancel?.call();
            };
            _bridge!.onStop = () {
              widget.miscActions.onStop?.call();
            };
            _bridge!.onLinkClick = (url) {
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            };
            _bridge!.onLoadMore = () {
              ref.read(chatProvider(widget.charId).notifier).loadOlderMessages();
            };
            _bridge!.onExtBlocksClick = (messageId) async {
              final sessionId = widget.sessionId;
              if (sessionId == null || sessionId.isEmpty) return;
              final blocks = ref
                  .read(infoBlocksProvider(sessionId).notifier)
                  .getByMessageId(messageId)
                  .map((InfoBlock b) => b.toMap())
                  .toList();
              await _bridge?.showExtBlocksPanel(messageId, blocks);
            };
            _bridge!.onExtBlockStop = (blockId, messageId) {
              ref.read(extensionPostGenServiceProvider).cancelBlocks();
            };
            _bridge!.onExtBlockRegen = (blockId, messageId) async {
              final sessionId = widget.sessionId;
              if (sessionId == null || sessionId.isEmpty) return;
              final chatState = ref.read(chatProvider(widget.charId)).value;
              if (chatState == null) return;
              final character = ref.read(characterByIdProvider(widget.charId));
              if (character == null) return;
              await ref.read(extensionPostGenServiceProvider).rerunBlock(
                blockId: blockId,
                messageId: messageId,
                sessionId: sessionId,
                charId: widget.charId,
                messages: chatState.messages,
                character: character,
                persona: null,
              );
            };
            _bridge!.onExtBlockEdit = (blockId, messageId) async {
              final sessionId = widget.sessionId;
              if (sessionId == null || sessionId.isEmpty) return;
              final blocks = ref
                  .read(infoBlocksProvider(sessionId))
                  .where((b) =>
                      b.messageId == messageId && b.blockId == blockId)
                  .toList();
              if (blocks.isEmpty) return;
              final block = blocks.first;
              if (!mounted) return;
              final newContent = await _promptEditBlock(
                context: context,
                blockName: block.blockName,
                initialContent: block.content,
              );
              if (newContent == null) return;
              await ref
                  .read(infoBlocksProvider(sessionId).notifier)
                  .updateContent(block.id, newContent);
              await _bridge?.showExtBlocksPanel(
                messageId,
                ref
                    .read(infoBlocksProvider(sessionId).notifier)
                    .getByMessageId(messageId)
                    .map((b) => b.toMap())
                    .toList(),
              );
            };
            _bridge!.onExtBlockDelete = (blockId, messageId) async {
              final sessionId = widget.sessionId;
              if (sessionId == null || sessionId.isEmpty) return;
              final blocks = ref
                  .read(infoBlocksProvider(sessionId))
                  .where((b) =>
                      b.messageId == messageId && b.blockId == blockId)
                  .toList();
              if (blocks.isEmpty) return;
              final block = blocks.first;
              if (!mounted) return;
              final confirmed = await _confirmDeleteBlock(
                context: context,
                blockName: block.blockName,
              );
              if (!confirmed) return;
              await ref
                  .read(infoBlocksProvider(sessionId).notifier)
                  .delete(block.id);
              await _bridge?.showExtBlocksPanel(
                messageId,
                ref
                    .read(infoBlocksProvider(sessionId).notifier)
                    .getByMessageId(messageId)
                    .map((b) => b.toMap())
                    .toList(),
              );
            };

            final isAlive = await controller.isLoading() == false;
            if (isAlive && !_ready) {
              await _initWebView();
            }
          },
          onLoadStop: (controller, url) async {
            if (_bridge == null || _ready) return;
            unawaited(controller.evaluateJavascript(source: '''
              (function() {
                var els = [document.documentElement, document.body, document.getElementById('chat-container'), document.getElementById('loading-screen')];
                els.forEach(function(el) {
                  if (!el) return;
                  var cs = getComputedStyle(el);
                  console.log('DIAG ' + (el.id || el.tagName) + ' bg=' + cs.backgroundColor + ' opacity=' + el.style.opacity);
                });
              })();
            '''));
            await _initWebView();
          },
          onConsoleMessage: (controller, consoleMessage) {
            debugPrint('[JS] ${consoleMessage.message}');
          },
            ),
          ),
        ),
        if (_sessionSwitching)
          const Center(child: CircularProgressIndicator(strokeWidth: 3)),
        if (widget.bottomInset > 0)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.02),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Map<String, String> _buildThemeMap() {
    final glaze = context.colors;
    final cs = context.cs;
    final primary = cs.primary;
    return {
      'bg-color': _colorHex(cs.surface),
      'text-color': _colorHex(cs.onSurface),
      'ui-bg-rgb': _colorRgb(cs.surface),
      'vk-blue-rgb': _colorRgb(primary),
      'primary-rgb': _colorRgb(primary),
      'user-bubble-color-rgb': _colorRgb(glaze.userBubble),
      'char-bubble-color-rgb': _colorRgb(glaze.charBubble),
      'user-text-color': _colorHex(glaze.userText ?? cs.onSurface),
      'char-text-color': _colorHex(glaze.charText ?? cs.onSurface),
      'user-quote-color': _colorHex(glaze.userQuote ?? cs.primary),
      'char-quote-color': _colorHex(glaze.charQuote ?? cs.primary),
      'user-italic-color': _colorHex(glaze.userItalic ?? cs.primary),
      'char-italic-color': _colorHex(glaze.charItalic ?? cs.primary),
      'primary-color': _colorHex(primary),
      'error-color': _colorHex(cs.error),
      'element-opacity': widget.elementOpacity.clamp(0.0, 1.0).toStringAsFixed(2),
      'element-blur': '${widget.elementBlur.clamp(0.0, 64.0).round()}px',
      'font-size': '${widget.chatFontSize}px',
      'chat-font-size': '${widget.chatFontSize}px',
      'chat-layout': widget.chatLayout ?? 'default',
      'bg-dim': widget.bgDim.clamp(0.0, 1.0).toStringAsFixed(2),
    };
  }

  Future<void> _applyThemeToBridge() async {
    await _bridge?.applyTheme(_buildThemeMap());
  }

  String _colorRgb(Color c) {
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    return '$r, $g, $b';
  }

  String _colorHex(Color c) {
    final a = c.a;
    final r = (c.r * 255).round();
    final g = (c.g * 255).round();
    final b = (c.b * 255).round();
    if (a >= 0.99) {
      return '#${r.toRadixString(16).padLeft(2, '0')}'
          '${g.toRadixString(16).padLeft(2, '0')}'
          '${b.toRadixString(16).padLeft(2, '0')}';
    }
    final alphaR = (r * a + 255 * (1 - a)).round().clamp(0, 255);
    final alphaG = (g * a + 255 * (1 - a)).round().clamp(0, 255);
    final alphaB = (b * a + 0 * (1 - a)).round().clamp(0, 255);
    return '#${alphaR.toRadixString(16).padLeft(2, '0')}'
        '${alphaG.toRadixString(16).padLeft(2, '0')}'
        '${alphaB.toRadixString(16).padLeft(2, '0')}';
  }

  Future<void> scrollToBottom() {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.scrollToBottom();
  }

  Future<void> scrollToMessage(String id) {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.scrollToMessage(id);
  }

  Future<void> setSearch(String q, int i) {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.setSearch(query: q, activeIndex: i);
  }

  Future<void> toggleMessageSelection(String id) {
    final b = _bridge;
    if (b == null) return Future.value();
    return b.toggleMessageSelection(id);
  }

  Future<String?> _promptEditBlock({
    required BuildContext context,
    required String blockName,
    required String initialContent,
  }) {
    final controller = TextEditingController(text: initialContent);
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Редактировать «$blockName»'),
          content: SizedBox(
            width: 500,
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLines: 12,
              minLines: 6,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
              ),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Содержимое блока…',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('Сохранить'),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _confirmDeleteBlock({
    required BuildContext context,
    required String blockName,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Удалить «$blockName»?'),
          content: const Text('Блок будет удалён из базы данных. Это нельзя отменить.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Удалить'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }
}
