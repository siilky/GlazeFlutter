# Known Bugs

## Vector / Embedding

- **~~Memory book embeddings entirely missing.~~** Fixed — `MemoryEmbeddingService` + vector search in `MemoryInjectionService` + reindex/clear UI in MemoryBooksSheet.
- **~~No rate limit cooldown UI.~~** Fixed — lorebook editor shows countdown after 429.
- **~~No error classification for embeddings.~~** Fixed — `EmbeddingErrorLabel.classify()` with 8 types, shown as tooltip on error badge in entry list.
- **~~No freshness check during vector search.~~** Fixed — `LorebookVectorSearch` now verifies `textHash` against current entry content and skips stale vectors.
- **~~`embeddingTarget` setting is a no-op.~~** Fixed — `LorebookEmbeddingService` now respects per-lorebook `embeddingTarget` (content/keys).
- **~~No "Delete All Indexes" button.~~** Fixed — added to lorebook editor toolbar.
- **~~No "Retry Failed" button.~~** Fixed — added to lorebook editor toolbar.
- **~~`characterFilter` not applied during vector search.~~** Fixed — entries with character filters are now excluded.
- **~~`keywordVectorSplit` unused.~~** Already implemented in `lorebook_merger.dart`.

## Memory Books

- **No custom prompt manager.** JS has `MemoryPromptManagerSheet` to add/edit/delete custom prompt templates. Flutter only has built-in presets.
- **No quick model selector.** JS fetches models from the API and shows a picker. Flutter only has a text field for model name.

## Backup Import

- **~~iOS backup import crashes with FileType.custom error.~~** Fixed — `backup_screen.dart` was using `FileType.any` with `allowedExtensions`, which iOS rejects. Changed to `FileType.custom`.
- **~~Duplicate template API config created on recover.~~** Fixed — moved `topLevel['apiPresets']` extraction before the `presets.isEmpty` fallback, so the "Default" template is only created when no presets exist from any source.
- **~~IMG-GEN API key not restored from backup.~~** Fixed — (1) remove `gz_imggen_settings` during import so migration re-runs; (2) extended `_migrateFromJsKeys()` to read 12 more fields (routmy/naistera model, aspectRatio, quality, sendAvatar, gemini size, ru-routmy key).

## Tokenizer / Prompt Counting

- **~~Stale token counts after hide/unhide.~~** Fixed — added `ref.listen(chatProvider)` in TokenizerSheet, MagicDrawerPanel, ContextInfoSheet, PromptPreviewScreen to auto-recalculate when session changes. Also fixed `historyText` to exclude hidden messages.
- **~~Preset tokens counted before macro expansion.~~** Fixed — root cause was `blockId` lost in `_assembleMessages`. All `PromptMessage` objects got `id: 'static'`, so `_sourceForBlock` defaulted everything to `'preset'`. Now each message carries its actual blockId (`char_card`, `persona`, `summary`, `lorebook`, `memory`, etc.) and token breakdown is accurate per source.
- **~~No per-source token breakdown.~~** Fixed — same root cause as above. Now `_sourceForBlock` correctly maps block IDs including `memory` and `char_depth_prompt`.
- **~~Tokenizer total ≠ prompt fill indicator.~~** Fixed — was a symptom of stale token counts (now auto-refreshed via `ref.listen`) and misattributed blockId (now correctly mapped per source).

## Regex

- **~~Preset-level regexes not connected to presets.~~** Fixed — two-tier system: active preset regexes + global regexes merged at prompt-build time. Regex list now shows sections. JS backup `regex_scripts` imported to global tier.
- **~~Scroll resets on regex toggle.~~** Fixed — replaced FutureBuilder+invalidate with `presetsListProvider` + `skipLoadingOnReload: true` + `PageStorageKey`.

## UI

- **Character menu scrolls with lag.** The character list/menu has noticeable scroll latency/jank.
