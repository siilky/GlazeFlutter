# План рефакторинга

## P0 — Архитектурные нарушения (сделать первыми)

| # | Что | Почему | Файлы |
|---|-----|--------|-------|
| 1 | Перенести `SyncDeletionTracker` из `features/` в `core/services/` | `core/state/` импортирует `features/` — нарушение направления зависимостей | `core/state/character_provider.dart`, `core/state/lorebook_provider.dart` |
| 2 | Создать `generateId()` в `core/utils/id_generator.dart` | 16 дубликатов `DateTime.now().millisecondsSinceEpoch.toRadixString(36)` | backup_service, chat_provider, preset_editor, persona_list, и ещё 8 файлов |
| 3 | Создать `currentTimestampSeconds()` в `core/utils/time_helpers.dart` | 37 дубликатов `DateTime.now().millisecondsSinceEpoch ~/ 1000` | chat_provider (12!), backup_service, chat_generation_service, и ещё 10 файлов |

## P1 — Расщепление god-объектов

| # | Что | Строк | Результат |
|---|-----|-------|-----------|
| 4 | `ChatNotifier` → `ChatSessionNotifier` + `ChatMessageEditor` + делегирование генерации | 542 | Каждый <150 строк, одна ответственность |
| 5 | `MagicDrawerPanel` → `MagicDrawerLayoutService` + `MagicDrawerStatsService` + виджеты | 894 | Статы через Riverpod provider, а не императивно в виджете |
| 6 | `BackupService` → `BackupExporter` + `JsonlChatExporter/Importer` + `PngCharacterExporter` + `SillyTavernExporter` | 1399 | Каждый формат — свой класс |
| 7 | `GlazeBottomSheet` → models.dart + 5 виджет-файлов | 993 | 7 моделей + 14 виджетов в одном файле |
| 8 | Вынести бизнес-логику из `chat_screen.dart` в `ChatActionsService` | 604 | `_generateSummary`, `_exportChat`, `_importChat` не должны быть в UI |
| 9 | Перенести провайдеры из экранов в отдельные файлы | — | `PersonaListNotifier`, `ApiListNotifier`, `ChatHistoryNotifier` |

## P2 — Устранение обхода provider-слоя

| # | Что | Масштаб |
|---|-----|---------|
| 10 | UI напрямую вызывает `repo.put()` — создать provider-facade | 13 экранов, ~40 вызовов |
| 11 | UI напрямую импортирует `core/llm/` сервисы — обернуть в providers | 13 виджетов |
| 12 | `GlazeTextField` — использовать везде вместо 66 дубликатов `InputDecoration` | 66 мест |
| 13 | `ImageGenSettings` → Freezed модель (убрать 75 строк ручной сериализации) | `image_gen_provider.dart` |
| 14 | `ActiveSelectionProvider` → нормальный AsyncNotifier (убрать дублирование WidgetRef/Ref) | `active_selection_provider.dart` |

## P3 — Крупные экраны

| # | Что | Строк |
|---|-----|-------|
| 15 | `PresetEditorScreen` → orchestrator + `PresetBlockEditor` + `PresetRegexEditor` + `PresetEditorNotifier` | 1320 |
| 16 | `CharacterDetailScreen` → вынести цвет-токены + 9 виджетов по файлам | 695 |
