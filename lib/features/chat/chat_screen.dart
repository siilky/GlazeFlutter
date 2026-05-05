import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/llm/prompt_builder.dart';
import '../../core/llm/prompt_isolate.dart';
import '../../core/models/chat_message.dart';
import '../../core/state/active_selection_provider.dart';
import '../../core/state/character_provider.dart';
import '../../core/state/db_provider.dart';
import '../../shared/theme/app_colors.dart';
import '../../shared/widgets/glaze_scaffold.dart';
import 'chat_provider.dart';
import 'widgets/widgets.dart';

class ChatScreen extends ConsumerWidget {
  final String charId;
  const ChatScreen({super.key, required this.charId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatStateAsync = ref.watch(chatProvider(charId));
    final chatState = chatStateAsync.value;

    final chars = ref.watch(charactersProvider).value ?? [];
    final character = chars.where((c) => c.id == charId).firstOrNull;
    final title = character?.name ?? 'Chat';
    final sessionName = chatState?.session != null
        ? 'Session #${chatState!.session!.sessionIndex}'
        : 'Loading...';

    return GlazeScaffold(
      extendBodyBehindHeader: true,
      title: title,
      titleWidget: character != null
          ? ChatHeaderTitle(character: character, sessionName: sessionName)
          : null,
      onBack: () => context.go('/'),
      actions: [
        IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: () => context.go('/character/$charId'),
          color: AppColors.accent,
        ),
        chatStateAsync.when(
          data: (state) => state.isGenerating
              ? IconButton(
                  icon: const Icon(Icons.stop_circle),
                  color: AppColors.accent,
                  onPressed: () =>
                      ref.read(chatProvider(charId).notifier).abortGeneration(),
                )
              : const SizedBox.shrink(),
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
        ),
        Theme(
          data: Theme.of(
            context,
          ).copyWith(iconTheme: const IconThemeData(color: AppColors.accent)),
          child: PopupMenuButton<String>(
            iconColor: AppColors.accent,
            onSelected: (value) {
              switch (value) {
                case 'preset':
                  _showPresetPicker(context, ref);
                case 'persona':
                  _showPersonaPicker(context, ref);
                case 'raw':
                  _showRawPrompt(context, ref);
                case 'clear':
                  _confirmClearChat(context, ref);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'preset',
                child: Row(
                  children: [
                    Icon(Icons.tune, size: 18),
                    SizedBox(width: 8),
                    Text('Preset'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'persona',
                child: Row(
                  children: [
                    Icon(Icons.person, size: 18),
                    SizedBox(width: 8),
                    Text('Persona'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'raw',
                child: Row(
                  children: [
                    Icon(Icons.data_object, size: 18),
                    SizedBox(width: 8),
                    Text('View Raw Prompt'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(Icons.delete_sweep, size: 18, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Clear Chat', style: TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
      body: chatStateAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (state) => Stack(
          children: [
            _MessageList(
              messages: state.messages,
              streamingText: state.isGenerating ? state.streamingText : null,
              streamingReasoning: state.isGenerating
                  ? state.streamingReasoning
                  : null,
              isGenerating: state.isGenerating,
              charId: charId,
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
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
                  InputBar(
                    onSend: (text) {
                      if (text.trim().isEmpty) return;
                      ref.read(chatProvider(charId).notifier).sendMessage(text);
                    },
                    isGenerating: state.isGenerating,
                    onStop: state.isGenerating
                        ? () => ref
                              .read(chatProvider(charId).notifier)
                              .abortGeneration()
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRawPrompt(BuildContext context, WidgetRef ref) async {
    final chatState = ref.read(chatProvider(charId)).value;
    if (chatState == null || chatState.session == null) return;

    final charRepo = ref.read(characterRepoProvider);
    final presetRepo = ref.read(presetRepoProvider);
    final personaRepo = ref.read(personaRepoProvider);
    final apiConfigRepo = ref.read(apiConfigRepoProvider);

    final character = await charRepo.getById(charId);
    if (character == null) return;

    final apiConfigs = await apiConfigRepo.getAll();
    if (apiConfigs.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No API config')));
      }
      return;
    }
    final apiConfig = apiConfigs.first;

    final activePresetId = ref.read(activePresetIdProvider);
    final activePersonaId = ref.read(activePersonaIdProvider);

    final presets = await presetRepo.getAll();
    final preset = activePresetId != null
        ? presets.where((p) => p.id == activePresetId).firstOrNull
        : (presets.isNotEmpty ? presets.first : null);

    final personas = await personaRepo.getAll();
    final persona = activePersonaId != null
        ? personas.where((p) => p.id == activePersonaId).firstOrNull
        : (personas.isNotEmpty ? personas.first : null);

    final payload = PromptPayload(
      character: character,
      persona: persona,
      preset: preset,
      history: chatState.session!.messages,
      apiConfig: apiConfig,
      sessionVars: chatState.session!.sessionVars,
      globalVars: ref.read(globalVarsProvider),
    );

    final result = await buildPromptInIsolate(payload);

    final rawJson = const JsonEncoder.withIndent('  ').convert({
      'model': apiConfig.model,
      'messages': result.messages.map((m) => m.toApiMap()).toList(),
      'max_tokens': apiConfig.maxTokens,
      'temperature': apiConfig.temperature,
      'top_p': apiConfig.topP,
      'stream': apiConfig.stream,
    });

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Text('Raw Prompt'),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: rawJson));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              },
            ),
          ],
        ),
        content: SizedBox(
          width: MediaQuery.of(context).size.width * 0.8,
          height: MediaQuery.of(context).size.height * 0.7,
          child: SelectableText(
            rawJson,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showPresetPicker(BuildContext context, WidgetRef ref) async {
    final presets = await ref.read(presetRepoProvider).getAll();
    final activeId = ref.read(activePresetIdProvider);
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select Preset'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              setActivePreset(ref, null);
              Navigator.pop(ctx);
            },
            child: Row(
              children: [
                if (activeId == null) const Icon(Icons.check, size: 16),
                const SizedBox(width: 8),
                const Text('Default (first)'),
              ],
            ),
          ),
          ...presets.map(
            (p) => SimpleDialogOption(
              onPressed: () {
                setActivePreset(ref, p.id);
                Navigator.pop(ctx);
              },
              child: Row(
                children: [
                  if (activeId == p.id) const Icon(Icons.check, size: 16),
                  const SizedBox(width: 8),
                  Text(p.name),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showPersonaPicker(BuildContext context, WidgetRef ref) async {
    final personas = await ref.read(personaRepoProvider).getAll();
    final activeId = ref.read(activePersonaIdProvider);
    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Select Persona'),
        children: [
          SimpleDialogOption(
            onPressed: () {
              setActivePersona(ref, null);
              Navigator.pop(ctx);
            },
            child: Row(
              children: [
                if (activeId == null) const Icon(Icons.check, size: 16),
                const SizedBox(width: 8),
                const Text('Default (first)'),
              ],
            ),
          ),
          ...personas.map(
            (p) => SimpleDialogOption(
              onPressed: () {
                setActivePersona(ref, p.id);
                Navigator.pop(ctx);
              },
              child: Row(
                children: [
                  if (activeId == p.id) const Icon(Icons.check, size: 16),
                  const SizedBox(width: 8),
                  Text(p.name),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmClearChat(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Chat'),
        content: const Text('Delete all messages? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(chatProvider(charId).notifier).clearChat();
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

class _MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final String? streamingText;
  final String? streamingReasoning;
  final bool isGenerating;
  final String charId;

  const _MessageList({
    required this.messages,
    this.streamingText,
    this.streamingReasoning,
    required this.isGenerating,
    required this.charId,
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final _scrollController = ScrollController();

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final showStreaming =
        widget.streamingText != null && widget.streamingText!.isNotEmpty;

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 80, bottom: 180),
      itemCount: widget.messages.length + (showStreaming ? 1 : 0),
      itemBuilder: (context, index) {
        if (index < widget.messages.length) {
          final msg = widget.messages[index];
          return MessageBubble(
            content: msg.content,
            isUser: msg.role == 'user',
            isSystem: msg.role == 'system',
            reasoning: msg.reasoning,
            genTime: msg.genTime,
            tokens: msg.tokens,
            isHidden: msg.isHidden,
            isError: msg.isError,
            messageIndex: index,
            isLast: index == widget.messages.length - 1,
            isGenerating: widget.isGenerating,
            charId: widget.charId,
          );
        }
        return MessageBubble(
          content: widget.streamingText!,
          isUser: false,
          isStreaming: true,
          reasoning: widget.streamingReasoning,
          messageIndex: -1,
          isLast: false,
          isGenerating: true,
          charId: widget.charId,
        );
      },
    );
  }
}
