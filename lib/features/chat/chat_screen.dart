import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/state/character_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_bottom_sheet.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import '../../shared/widgets/glaze_toast.dart';
import 'chat_actions_service.dart';
import 'chat_provider.dart';
import 'chat_state.dart';
import 'widgets/chat_header.dart';
import 'widgets/chat_input_bar.dart';
import '../image_gen/widgets/image_gen_sheet.dart';
import 'widgets/magic_drawer.dart';
import 'widgets/message_list.dart';
import 'widgets/prompt_preview_screen.dart';
import 'widgets/session_lifecycle_tracker.dart';

class SearchMatch {
  final int messageIndex;
  final int matchIndexInMessage;
  const SearchMatch(this.messageIndex, this.matchIndexInMessage);
}

const String _kKeyboardHeightPref = 'chat_last_keyboard_height';
const double _kDefaultKeyboardHeight = 320;

class ChatScreen extends ConsumerStatefulWidget {
  final String charId;
  final int? initialSessionIndex;
  final bool forceNewSession;
  const ChatScreen({
    super.key,
    required this.charId,
    this.initialSessionIndex,
    this.forceNewSession = false,
  });

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with SingleTickerProviderStateMixin {
  bool _sessionApplied = false;
  bool _showSearch = false;
  String _searchQuery = '';
  int _searchCurrentIndex = 0;
  List<SearchMatch> _searchMatches = [];
  final TextEditingController _searchController = TextEditingController();

  // Telegram-style input panel state. The input area swaps between three
  // exclusive bottom-anchored modes: idle, keyboard, drawer.
  final FocusNode _inputFocus = FocusNode();
  bool _drawerOpen = false;
  double _lastKeyboardHeight = _kDefaultKeyboardHeight;
  late final AnimationController _drawerAnimController;
  late final Animation<double> _drawerAnim;

  @override
  void initState() {
    super.initState();
    _drawerAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _drawerAnim = CurvedAnimation(
      parent: _drawerAnimController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _inputFocus.addListener(_onFocusChanged);
    _restoreKeyboardHeight();
    if (widget.forceNewSession || widget.initialSessionIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applySessionPreference();
      });
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _inputFocus.removeListener(_onFocusChanged);
    _inputFocus.dispose();
    _drawerAnimController.dispose();
    super.dispose();
  }

  Future<void> _restoreKeyboardHeight() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getDouble(_kKeyboardHeightPref);
      if (saved != null && saved > 100 && mounted) {
        setState(() => _lastKeyboardHeight = saved);
      }
    } catch (_) {}
  }

  Future<void> _persistKeyboardHeight(double height) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kKeyboardHeightPref, height);
    } catch (_) {}
  }

  void _onFocusChanged() {
    // Keyboard about to come up: drawer must yield (Telegram semantics —
    // exactly one of keyboard/drawer can occupy the bottom panel).
    if (_inputFocus.hasFocus && _drawerOpen) {
      setState(() => _drawerOpen = false);
    }
  }

  void _toggleDrawer() {
    if (_drawerOpen) {
      setState(() => _drawerOpen = false);
      _drawerAnimController.reverse();
    } else {
      // Hide keyboard first so its slide-out and the drawer slide-in cover
      // the same bottom region without a visible gap.
      _inputFocus.unfocus();
      HapticFeedback.selectionClick();
      setState(() => _drawerOpen = true);
      _drawerAnimController.forward();
    }
  }

  void _closeDrawer() {
    if (!_drawerOpen) return;
    setState(() => _drawerOpen = false);
    _drawerAnimController.reverse();
  }

  Future<void> _applySessionPreference() async {
    if (_sessionApplied) return;
    _sessionApplied = true;
    final notifier = ref.read(chatProvider(widget.charId).notifier);
    if (widget.forceNewSession) {
      await notifier.createNewSession();
    } else if (widget.initialSessionIndex != null) {
      await notifier.switchSession(widget.initialSessionIndex!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final charId = widget.charId;
    final chatStateAsync = ref.watch(chatProvider(charId));
    final chatState = chatStateAsync.value;

    final chars = ref.watch(charactersProvider).value ?? [];
    final character = chars.where((c) => c.id == charId).firstOrNull;
    final title = character?.name ?? 'Chat';
    final sessionName = chatState?.session != null
        ? 'Session #${chatState!.session!.sessionIndex}'
        : 'Loading...';
    final sessionIndex = chatState?.session?.sessionIndex ?? 0;

    // Track the OS keyboard height so the drawer can match it exactly.
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboardHeight > 100 &&
        (keyboardHeight - _lastKeyboardHeight).abs() > 1) {
      _lastKeyboardHeight = keyboardHeight;
      _persistKeyboardHeight(keyboardHeight);
    }
    // If the system keyboard appears while the drawer is open (e.g. external
    // keyboard, IME race), hide the drawer — keyboard wins.
    if (keyboardHeight > 0 && _drawerOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _drawerOpen) _closeDrawer();
      });
    }

    // Final (post-animation) inset for layout-only consumers (MessageList).
    // Animated visual positioning of the input + drawer is driven by
    // _drawerAnim inside _ChatBody so list paddings don't churn each frame.
    final targetDrawerInset = _drawerOpen ? _lastKeyboardHeight : 0.0;
    final targetBottomPanelInset = math.max(targetDrawerInset, keyboardHeight);

    return SessionLifecycleTracker(
      charId: charId,
      child: GlazeScaffold(
        extendBodyBehindHeader: true,
        resizeToAvoidBottomInset: false,
        title: title,
        titleWidget: _showSearch
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
                decoration: InputDecoration(
                  hintText: 'Search messages...',
                  hintStyle: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.5)),
                  border: InputBorder.none,
                  isDense: true,
                  suffixIcon: _searchQuery.isNotEmpty 
                      ? IconButton(
                          icon: const Icon(Icons.close, color: AppColors.textPrimary, size: 20),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchQuery = '';
                              _searchMatches = [];
                              _searchCurrentIndex = 0;
                            });
                          },
                        )
                      : null,
                ),
                onChanged: (q) {
                  final matches = <SearchMatch>[];
                  if (q.isNotEmpty && chatState != null) {
                    final lower = q.toLowerCase();
                    for (int i = 0; i < chatState.messages.length; i++) {
                      final content = chatState.messages[i].content.toLowerCase();
                      int startIndex = 0;
                      int matchIndex = 0;
                      while (true) {
                        final idx = content.indexOf(lower, startIndex);
                        if (idx == -1) break;
                        matches.add(SearchMatch(i, matchIndex));
                        matchIndex++;
                        startIndex = idx + lower.length;
                      }
                    }
                  }
                  setState(() {
                    _searchQuery = q;
                    _searchMatches = matches;
                    _searchCurrentIndex = 0;
                  });
                },
              )
            : (character != null
                ? ChatHeader(
                    character: character,
                    sessionName: sessionName,
                    currentSessionIndex: sessionIndex,
                  )
                : null),
        onBack: () {
          if (_showSearch) {
            _searchController.clear();
            setState(() {
              _showSearch = false;
              _searchQuery = '';
              _searchMatches = [];
              _searchCurrentIndex = 0;
            });
          } else {
            context.go('/');
          }
        },
        actions: _showSearch
            ? const []
            : [
          chatStateAsync.when(
            data: (state) => state.isGenerating
                ? IconButton(
                    icon: const Icon(Icons.stop_circle),
                    color: AppColors.accent,
                    onPressed: () => ref
                        .read(chatProvider(charId).notifier)
                        .abortGeneration(),
                  )
                : const SizedBox.shrink(),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            color: AppColors.accent,
            onPressed: () {
              setState(() {
                _showSearch = true;
                _searchQuery = '';
                _searchMatches = [];
                _searchCurrentIndex = 0;
                _searchController.clear();
              });
            },
          ),
        ],
        body: chatStateAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (state) => _ChatBody(
            charId: charId,
            state: state,
            inputFocus: _inputFocus,
            drawerOpen: _drawerOpen,
            drawerHeight: _lastKeyboardHeight,
            keyboardHeight: keyboardHeight,
            targetBottomPanelInset: targetBottomPanelInset,
            drawerAnim: _drawerAnim,
            showSearchControls: _showSearch,
            searchQuery: _searchQuery,
            searchMatches: _searchMatches,
            searchCurrentIndex: _searchCurrentIndex,
            onSearchPrev: _searchCurrentIndex > 0
                ? () => setState(() => _searchCurrentIndex--)
                : null,
            onSearchNext: _searchCurrentIndex < _searchMatches.length - 1
                ? () => setState(() => _searchCurrentIndex++)
                : null,
            onCloseDrawer: _closeDrawer,
            onToggleDrawer: _toggleDrawer,
          ),
        ),
      ),
    );
  }
}

class _ChatBody extends ConsumerWidget {
  final String charId;
  final ChatState state;
  final FocusNode inputFocus;
  final bool drawerOpen;
  final double drawerHeight;
  final double keyboardHeight;

  /// Final (post-animation) inset for layout-only consumers like
  /// [MessageList]. Doesn't churn per frame.
  final double targetBottomPanelInset;

  /// 0..1 progress of the drawer reveal — drives the visual slide and the
  /// input-bar lift each frame.
  final Animation<double> drawerAnim;

  final bool showSearchControls;
  final String searchQuery;
  final List<SearchMatch> searchMatches;
  final int searchCurrentIndex;
  final VoidCallback? onSearchPrev;
  final VoidCallback? onSearchNext;
  final VoidCallback onCloseDrawer;
  final VoidCallback onToggleDrawer;

  const _ChatBody({
    required this.charId,
    required this.state,
    required this.inputFocus,
    required this.drawerOpen,
    required this.drawerHeight,
    required this.keyboardHeight,
    required this.targetBottomPanelInset,
    required this.drawerAnim,
    required this.showSearchControls,
    required this.searchQuery,
    required this.searchMatches,
    required this.searchCurrentIndex,
    this.onSearchPrev,
    this.onSearchNext,
    required this.onCloseDrawer,
    required this.onToggleDrawer,
  });

  static const double _inputBarApproxHeight = 130;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Reserve space below the message list for: input bar + (keyboard or
    // drawer) + the bottom safe area. We pass the FINAL inset so the list's
    // padding doesn't churn per animation frame.
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final messageListBottom =
        _inputBarApproxHeight + targetBottomPanelInset + safeBottom;

    return Stack(
      children: [
        Positioned.fill(
          child: MessageList(
            messages: state.messages,
            streamingText: state.isGenerating ? state.streamingText : null,
            streamingReasoning:
                state.isGenerating ? state.streamingReasoning : null,
            isGenerating: state.isGenerating,
            charId: charId,
            bottomInset: messageListBottom,
            searchQuery: searchQuery,
            searchMatches: searchMatches,
            searchCurrentIndex: searchCurrentIndex,
          ),
        ),
        // Animated bottom region: drawer slides up from below, the input
        // bar tracks the same reveal so they move as one piece.
        AnimatedBuilder(
          animation: drawerAnim,
          builder: (context, _) {
            final progress = drawerAnim.value;
            final animatedDrawerInset = drawerHeight * progress;
            final animatedBottomPanelInset =
                math.max(animatedDrawerInset, keyboardHeight);
            // Keep the panel mounted while the close animation runs out.
            final renderDrawer = drawerOpen || progress > 0.001;

            return Stack(
              children: [
                if (renderDrawer)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -drawerHeight * (1 - progress),
                    height: drawerHeight,
                    child: MagicDrawerPanel(
                      charId: charId,
                      onClose: onCloseDrawer,
                    ),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: animatedBottomPanelInset,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          child: Text(
                            state.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ChatInputBar(
                        focusNode: inputFocus,
                        showSearchControls: showSearchControls,
                        searchQuery: searchQuery,
                        searchMatchCount: searchMatches.length,
                        searchCurrentIndex: searchCurrentIndex,
                        onSearchNext: onSearchNext,
                        onSearchPrev: onSearchPrev,
                        isDrawerOpen: drawerOpen,
                        onSend: (text) {
                          if (text.trim().isEmpty) return;
                          ref
                              .read(chatProvider(charId).notifier)
                              .sendMessage(text);
                        },
                        onSendWithGuidance: (text, guidance) {
                          if (text.trim().isEmpty) return;
                          ref
                              .read(chatProvider(charId).notifier)
                              .sendMessage(text, guidanceText: guidance);
                        },
                        isGenerating: state.isGenerating,
                        onStop: state.isGenerating
                            ? () => ref
                                  .read(chatProvider(charId).notifier)
                                  .abortGeneration()
                            : null,
                        onMagicDrawer: onToggleDrawer,
                        onImageGen: () => GlazeBottomSheet.show(
                          context,
                          child: const ImageGenSheet(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}



class _ChatSearchBar extends StatelessWidget {
  final String query;
  final int matchCount;
  final int currentIndex;
  final ValueChanged<String> onChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onClose;

  const _ChatSearchBar({
    required this.query,
    required this.matchCount,
    required this.currentIndex,
    required this.onChanged,
    this.onPrevious,
    this.onNext,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary, fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Search messages...',
              hintStyle: TextStyle(color: AppColors.textSecondary.withValues(alpha: 0.5)),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 8),
            ),
            onChanged: onChanged,
          ),
        ),
        if (query.isNotEmpty) ...[
          Text(
            matchCount > 0 ? '${currentIndex + 1}/$matchCount' : '0/0',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 24, color: AppColors.textPrimary),
            onPressed: onPrevious,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 24, color: AppColors.textPrimary),
            onPressed: onNext,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
        IconButton(
          icon: const Icon(Icons.close, size: 24, color: AppColors.textPrimary),
          onPressed: onClose,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        ),
      ],
    );
  }
}
