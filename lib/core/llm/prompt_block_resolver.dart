import '../models/character.dart';
import '../models/chat_message.dart';
import '../models/persona.dart';
import 'macro_engine.dart';

class NotifyObj {
  Map<String, String> sessionVars = {};
  Map<String, String> globalVars = {};
  bool varsChanged = false;
}

class ResolvedContent {
  final String role;
  /// Fully expanded content — this is what actually gets sent to the LLM
  /// (all macros resolved: {{summary}}, {{memory}}, {{lorebooks}}, etc.).
  final String content;
  /// Accounting-only content — dynamic macro injections (summary, memory,
  /// lorebooks, guidance) are blanked out so that the preset's "static
  /// chrome" tokens are not double-counted. See docs/INVARIANTS.md INV-PS5.
  final String contentForAccounting;
  const ResolvedContent({
    required this.role,
    required this.content,
    required this.contentForAccounting,
  });
}

ResolvedContent? resolveBlockContent({
  required String id,
  required String rawContent,
  required String role,
  required Character char,
  required Persona? persona,
  required MacroContext macroCtx,
  required Map<String, String> sessionVars,
  required Map<String, String> globalVars,
  required NotifyObj notifyObj,
  required String? summaryContent,
  required String? summaryPrefix,
  AuthorsNote? authorsNote,
}) {
  String content;
  String resolvedRole = role;

  switch (id) {
    case 'char_card':
      content = rawContent.isNotEmpty ? rawContent : (char.description ?? '');
    case 'char_personality':
      content = char.personality ?? '';
    case 'scenario':
      content = char.scenario ?? '';
    case 'example_dialogue':
      content = char.mesExample ?? '';
    case 'user_persona':
      content = _userPersonaContent(persona);
    case 'chat_history':
      return ResolvedContent(role: resolvedRole, content: '', contentForAccounting: '');
    case 'summary':
      if (summaryContent != null && summaryContent.isNotEmpty) {
        final prefix = summaryPrefix ?? 'Summary: ';
        content = '[$prefix$summaryContent]';
      } else {
        return null;
      }
    case 'guided_generation':
      if (macroCtx.guidanceText == null || macroCtx.guidanceText!.trim().isEmpty) {
        return null;
      }
      content = rawContent;
    case 'authors_note':
      if (authorsNote == null || !authorsNote.enabled || authorsNote.content.isEmpty) {
        return null;
      }
      content = authorsNote.content;
      resolvedRole = authorsNote.role.isNotEmpty ? authorsNote.role : role;
    default:
      content = rawContent;
  }

  if (content.isEmpty) return null;

  // Fully-expanded content (everything resolved, what the LLM actually sees).
  final macroResult = replaceMacros(content, macroCtx);
  if (macroResult.varsChanged) {
    notifyObj.sessionVars = macroResult.sessionVars;
    notifyObj.globalVars = macroResult.globalVars;
    notifyObj.varsChanged = true;
  }

  if (macroResult.text.trim().isEmpty) return null;

  // Accounting content: same as `content` but with dynamic macro injections
  // (summary, memory, lorebooks, guidance) blanked out, so that the preset's
  // "static chrome" tokens are attributed to `sourceTokens['preset']` and
  // NOT to `sourceTokens['memory']`/`sourceTokens['summary']`/etc. The
  // dynamic content is counted separately via dedicated StaticBlocks
  // (hard block injection) or via macroTokens (per-caller accounting in
  // `prompt_builder.dart`). Static macros ({{char}}, {{user}}, {{setvar}},
  // {{getvar}}, etc.) still expand so the lengths stay comparable.
  final accountingCtx = macroCtx.copyWith(
    summaryContent: null,
    memoryContent: null,
    lorebooksContent: null,
    guidanceText: null,
  );
  final accountingResult = replaceMacros(content, accountingCtx);

  return ResolvedContent(
    role: resolvedRole,
    content: macroResult.text,
    contentForAccounting: accountingResult.text,
  );
}

String _userPersonaContent(Persona? persona) {
  final buf = StringBuffer();
  buf.writeln('User Name: ${persona?.name ?? 'User'}');
  if (persona?.prompt != null && persona!.prompt!.isNotEmpty) {
    buf.writeln('User Description: ${persona.prompt}');
  }
  return buf.toString().trimRight();
}
