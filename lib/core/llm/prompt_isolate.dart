import 'prompt_builder.dart';

// NOTE: Isolate.run removed — o200k_base encoder lives in the main isolate
// and cannot be shared with spawned isolates (isolates don't share memory).
// buildPrompt is fast enough (~few ms) to run on the main thread.
Future<PromptResult> buildPromptInIsolate(PromptPayload payload) async {
  return buildPrompt(payload);
}
