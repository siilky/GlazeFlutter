import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/models/character.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../../../shared/theme/app_colors.dart';
import '../chat_provider.dart';

class ChatHeader extends ConsumerWidget {
  final Character character;
  final String sessionName;
  final int currentSessionIndex;

  const ChatHeader({
    super.key,
    required this.character,
    required this.sessionName,
    this.currentSessionIndex = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Color avatarColor = AppColors.accent;
    if (character.color != null && character.color!.isNotEmpty) {
      try {
        final String c = character.color!.replaceFirst('#', '');
        avatarColor = Color(int.parse('FF$c', radix: 16));
      } catch (_) {}
    }

    final String initial = character.name.isNotEmpty
        ? character.name[0].toUpperCase()
        : '?';

    Widget avatar;
    if (character.avatarPath != null && character.avatarPath!.isNotEmpty) {
      avatar = CircleAvatar(
        radius: 17,
        backgroundImage: FileImage(File(character.avatarPath!)),
        onBackgroundImageError: (_, __) {},
        backgroundColor: avatarColor.withValues(alpha: 0.2),
        child: const SizedBox.shrink(),
      );
    } else {
      avatar = Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: avatarColor.withValues(alpha: 0.2),
          shape: BoxShape.circle,
        ),
        child: Center(
          child: Text(
            initial,
            style: TextStyle(
              fontSize: 16,
              color: avatarColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        avatar,
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                character.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              InkWell(
                onTap: () => _showSessionPicker(context, ref),
                borderRadius: BorderRadius.circular(4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      sessionName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.swap_horiz, size: 14, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showSessionPicker(BuildContext context, WidgetRef ref) async {
    final sessions = await ref.read(chatProvider(character.id).notifier).getSessions();

    if (!context.mounted) return;
    if (sessions.length <= 1) return;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Switch Session', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
            ),
            const Divider(height: 1),
            ...sessions.map((s) => ListTile(
              leading: Icon(
                s.sessionIndex == currentSessionIndex ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                color: s.sessionIndex == currentSessionIndex ? AppColors.accent : AppColors.textSecondary,
              ),
              title: Text('Session #${s.sessionIndex}'),
              subtitle: Text('${s.messages.length} messages', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              onTap: () {
                Navigator.pop(ctx);
                if (s.sessionIndex != currentSessionIndex) {
                  ref.read(chatProvider(character.id).notifier).switchSession(s.sessionIndex);
                }
              },
            )),
          ],
        ),
      ),
    );
  }
}
