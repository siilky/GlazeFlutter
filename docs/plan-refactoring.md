# План рефакторинга

## P0 — Архитектурные нарушения ✅

| # | Что | Почему | Статус |
|---|-----|--------|--------|
| 1 | Перенести `SyncDeletionTracker` из `features/` в `core/utils/` | `core/state/` импортирует `features/` — нарушение зависимостей | ✅ |
| 2 | Создать `generateId()` в `core/utils/id_generator.dart` | 16 дубликатов | ✅ |
| 3 | Создать `currentTimestampSeconds()` в `core/utils/time_helpers.dart` | 37 дубликатов | ✅ |

## P1 — God-объекты и бизнес-логика в UI ✅

| # | Что | Было | Стало | Статус |
|---|-----|------|-------|--------|
| 4 | `ChatNotifier` → `ChatSessionService` + `ChatMessageService` + делегирование | 542 | 326 + 139 + 98 | ✅ |
| 5 | Вынести бизнес-логику из `MagicDrawerPanel` в `MagicDrawerStatsService` | 876 | 755 + 115 | ✅ |
| 6 | `BackupService` → 9 классов в `backup/` | 1568 | 55 + 9×~150 | ✅ |
| 8 | Вынести бизнес-логику из `chat_screen.dart` в `ChatActionsService` | 604 | 527 + 93 | ✅ |
| 9 | Перенести провайдеры из экранов в отдельные файлы | — | 3 provider-файла | ✅ |

## P2 — Устранение обхода provider-слоя

| # | Что | Масштаб | Статус |
|---|-----|---------|--------|
| 10 | UI напрямую вызывает `repo.put()` — создать provider-facade | 9 экранов, разовые вызовы | ⏭️ Низкий ROI |
| 11 | UI напрямую импортирует `core/llm/` сервисы — обернуть в providers | 13 виджетов | ⏭️ Низкий ROI |
| 12 | `GlazeTextField` — использовать везде вместо 66 дубликатов `InputDecoration` | 66 мест | ⏭️ Механическая замена |
| 13 | `ImageGenSettings` → Freezed модель | `image_gen_models.dart` | ✅ Уже Freezed |
| 14 | `ActiveSelectionProvider` → AsyncNotifier | `active_selection_provider.dart` | ⏭️ StateProvider работает, риск > пользы |
