import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/models/chat_message.dart';
import '../../../shared/theme/app_colors.dart';
import '../chat_screen.dart';
import 'message.dart';

/// Threshold (px from bottom) below which we treat the user as "at bottom":
/// auto-scroll keeps applying, scroll-button stays hidden.
const double _kStickToBottomThreshold = 100;

/// If we're farther than this from the bottom, prefer instant scroll over
/// smooth — animating across thousands of px is jarring and slow.
const double _kInstantScrollDistance = 3000;

class MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final String? streamingText;
  final String? streamingReasoning;
  final bool isGenerating;
  final String charId;

  /// Extra space at the bottom of the list to keep the last message above the
  /// input bar / drawer / keyboard. Owner of the layout passes this in so the
  /// list and the scroll-to-bottom button stay in sync with the bottom UI.
  final double bottomInset;

  final String searchQuery;
  final List<SearchMatch> searchMatches;
  final int searchCurrentIndex;

  const MessageList({
    super.key,
    required this.messages,
    this.streamingText,
    this.streamingReasoning,
    required this.isGenerating,
    required this.charId,
    this.bottomInset = 180,
    this.searchQuery = '',
    this.searchMatches = const [],
    this.searchCurrentIndex = 0,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final _scrollController = ScrollController();

  bool _wasAtBottom = true;
  bool _showScrollButton = false;
  bool _isProgrammaticScrolling = false;
  Timer? _programmaticUnlockTimer;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(smooth: false, force: true);
    });
  }

  @override
  void dispose() {
    _programmaticUnlockTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  int _itemCount(MessageList w) {
    final showStreaming =
        w.streamingText != null && w.streamingText!.isNotEmpty;
    final showTyping = w.isGenerating &&
        !showStreaming &&
        (w.messages.isEmpty || w.messages.last.role == 'user');
    return w.messages.length + (showStreaming || showTyping ? 1 : 0);
  }

  @override
  void didUpdateWidget(covariant MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newCount = _itemCount(widget);
    final oldCount = _itemCount(oldWidget);
    final streamingChanged =
        widget.streamingText != oldWidget.streamingText ||
        widget.streamingReasoning != oldWidget.streamingReasoning;

    // Auto-stick to bottom only while user was already there. New items
    // appended while user is scrolled up should not yank them back —
    // instead we surface the scroll-to-bottom button.
    if (_wasAtBottom && (newCount > oldCount || streamingChanged)) {
      // Streaming chunks: no animation (would constantly retrigger).
      // New full messages: smooth if close, instant if far.
      _scrollToBottom(smooth: !streamingChanged);
    }

    if (widget.bottomInset != oldWidget.bottomInset && _wasAtBottom) {
      // The bottom UI changed size (drawer toggled, input grew, keyboard
      // appeared). Stay pinned to bottom so the latest message remains
      // visible above the new bottom edge.
      _scrollToBottom(smooth: false);
    }

    int oldTargetIndex = -1;
    if (oldWidget.searchMatches.isNotEmpty && oldWidget.searchCurrentIndex < oldWidget.searchMatches.length) {
      oldTargetIndex = oldWidget.searchMatches[oldWidget.searchCurrentIndex].messageIndex;
    }
    int newTargetIndex = -1;
    if (widget.searchMatches.isNotEmpty && widget.searchCurrentIndex < widget.searchMatches.length) {
      newTargetIndex = widget.searchMatches[widget.searchCurrentIndex].messageIndex;
    }

    if (newTargetIndex != -1 && newTargetIndex != oldTargetIndex) {
      final pos = _scrollController.position;
      if (pos.hasContentDimensions) {
        final max = pos.maxScrollExtent;
        final total = widget.messages.length;
        if (total > 0) {
          // If the message is far away, we do a rough jump so ListView builds it.
          // Message.didUpdateWidget will then trigger an exact Scrollable.ensureVisible.
          if (oldTargetIndex == -1 || (newTargetIndex - oldTargetIndex).abs() > 5) {
            final targetOffset = (newTargetIndex / total) * max;
            // Use jumpTo to prevent fighting with Message's smooth ensureVisible.
            _scrollController.jumpTo(targetOffset);
          }
        }
      }
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_isProgrammaticScrolling) return;
    final pos = _scrollController.position;
    if (!pos.hasContentDimensions) return;

    final distance = pos.maxScrollExtent - pos.pixels;
    final atBottom = distance < _kStickToBottomThreshold;
    final wantsButton = distance > _kStickToBottomThreshold;

    if (atBottom != _wasAtBottom || wantsButton != _showScrollButton) {
      setState(() {
        _wasAtBottom = atBottom;
        _showScrollButton = wantsButton;
      });
    }
  }

  void _beginProgrammaticScroll() {
    _isProgrammaticScrolling = true;
    _programmaticUnlockTimer?.cancel();
  }

  void _endProgrammaticScroll({Duration delay = const Duration(milliseconds: 50)}) {
    _programmaticUnlockTimer?.cancel();
    _programmaticUnlockTimer = Timer(delay, () {
      if (!mounted) return;
      _isProgrammaticScrolling = false;
    });
  }

  Future<void> _scrollToBottom({bool smooth = true, bool force = false}) async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (!pos.hasContentDimensions) return;

      final target = pos.maxScrollExtent;
      final distance = target - pos.pixels;
      if (!force && distance.abs() < 0.5) return;

      // Long jumps: never animate. Stay close to Vue's behavior.
      final useSmooth = smooth && distance.abs() < _kInstantScrollDistance;

      _beginProgrammaticScroll();
      try {
        if (useSmooth) {
          await _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          );
          // Re-pin in case content grew during the animation (streaming).
          if (mounted && _scrollController.hasClients) {
            _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
          }
        } else {
          _scrollController.jumpTo(target);
        }
      } finally {
        _endProgrammaticScroll(
          delay: useSmooth
              ? const Duration(milliseconds: 250)
              : const Duration(milliseconds: 50),
        );
      }

      if (mounted && (_showScrollButton || !_wasAtBottom)) {
        setState(() {
          _wasAtBottom = true;
          _showScrollButton = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final showStreaming =
        widget.streamingText != null && widget.streamingText!.isNotEmpty;
    final showTyping =
        widget.isGenerating &&
        !showStreaming &&
        (widget.messages.isEmpty || widget.messages.last.role == 'user');

    return Stack(
      children: [
        ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.only(top: 80, bottom: widget.bottomInset),
          itemCount:
              widget.messages.length + (showStreaming || showTyping ? 1 : 0),
          itemBuilder: (context, index) {
            if (index < widget.messages.length) {
              final msg = widget.messages[index];
              final msgMatches = widget.searchMatches.where((m) => m.messageIndex == index).toList();
              final isMatch = msgMatches.isNotEmpty;
              final activeMatchIndex = (widget.searchMatches.isNotEmpty && 
                  widget.searchMatches[widget.searchCurrentIndex].messageIndex == index) 
                  ? widget.searchMatches[widget.searchCurrentIndex].matchIndexInMessage 
                  : -1;
              return Message(
                content: msg.content,
                isUser: msg.role == 'user',
                isSystem: msg.role == 'system',
                reasoning: msg.reasoning,
                genTime: msg.genTime,
                tokens: msg.tokens,
                isHidden: msg.isHidden,
                isError: msg.isError,
                messageIndex: index,
                totalMessages: widget.messages.length,
                isLast: index == widget.messages.length - 1,
                isGenerating: widget.isGenerating,
                charId: widget.charId,
                swipes: msg.swipes,
                swipeId: msg.swipeId,
                greetingIndex: msg.greetingIndex,
                memoryCoverage: msg.memoryCoverage,
                isSearchMatch: isMatch,
                searchQuery: widget.searchQuery,
                activeMatchIndex: activeMatchIndex,
              );
            }

            if (showStreaming) {
              return Message(
                content: widget.streamingText!,
                isUser: false,
                isStreaming: true,
                reasoning: widget.streamingReasoning,
                messageIndex: -1,
                totalMessages: widget.messages.length,
                isLast: false,
                isGenerating: true,
                charId: widget.charId,
              );
            }

            return Message(
              content: '',
              isUser: false,
              isTyping: true,
              messageIndex: -1,
              totalMessages: widget.messages.length,
              isLast: false,
              isGenerating: true,
              charId: widget.charId,
            );
          },
        ),
        Positioned(
          right: 16,
          bottom: widget.bottomInset + 8,
          child: _ScrollDownButton(
            visible: _showScrollButton,
            onTap: () => _scrollToBottom(smooth: true, force: true),
          ),
        ),
      ],
    );
  }
}

class _ScrollDownButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;

  const _ScrollDownButton({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: ScaleTransition(scale: anim, child: child),
      ),
      child: !visible
          ? const SizedBox.shrink(key: ValueKey('hide'))
          : ClipOval(
              key: const ValueKey('show'),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Material(
                  color: const Color(0xFF1E1E1E).withValues(alpha: 0.78),
                  shape: const CircleBorder(
                    side: BorderSide(color: AppColors.glassBorder),
                  ),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onTap,
                    child: const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        color: AppColors.accent,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
