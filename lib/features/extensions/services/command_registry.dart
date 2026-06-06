import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/trigger_mode.dart';

/// One executable glaze slash-command. Commands are the audit-friendly
/// alternative to direct method calls — they show up clearly in
/// `CommandRegistry.list()`, can be tested in isolation, and can be
/// re-used by features other than the JS bridge (e.g. the chat input
/// bar could accept `/command` invocations in the future).
///
/// The MVP command set is intentionally small: `/trigger`, `/getvar`,
/// `/setvar`, `/inject`, `/toast`. Full STScript compatibility is out of
/// scope per the plan.
class GlazeCommand {
  const GlazeCommand({
    required this.name,
    required this.summary,
    required this.handler,
  });

  /// The slash-prefixed name (e.g. `'/trigger'`). Always starts with `/`.
  final String name;

  /// Short human-readable description for the editor / docs.
  final String summary;

  /// Async handler. `args` is whatever the caller passed — for the JS
  /// bridge it's the JS `params.args` object. The handler must NEVER
  /// throw — it must return a [CommandResult] describing success or
  /// failure so the bridge can serialize the result back to JS.
  final FutureOr<CommandResult> Function(
    Map<String, dynamic> args,
    CommandContext context,
  ) handler;
}

/// Per-call context. The dispatcher fills in `charId` and `presetId`
/// from the caller. The handler can use it to address the right
/// character/preset.
class CommandContext {
  const CommandContext({this.charId, this.presetId});

  final String? charId;
  final String? presetId;
}

/// Result of a `/command` invocation. The bridge serializes this back
/// to the JS SDK. `ok: true` makes the promise resolve, `ok: false`
/// makes the SDK throw.
class CommandResult {
  const CommandResult({required this.ok, this.message, this.data});

  const CommandResult.ok({String? message, Object? data})
      : this(ok: true, message: message, data: data);

  const CommandResult.error(String message)
      : this(ok: false, message: message);

  final bool ok;
  final String? message;
  final Object? data;

  Map<String, dynamic> toMap() => {
    'ok': ok,
    if (message != null) 'message': message,
    if (data != null) 'data': data,
  };
}

/// Lookup-based command registry. The MVP ships with five commands
/// (`/trigger`, `/getvar`, `/setvar`, `/inject`, `/toast`). The
/// registry is a plain `Map<String, GlazeCommand>` exposed via
/// `list()` for the UI.
class CommandRegistry {
  CommandRegistry();

  final Map<String, GlazeCommand> _commands = {};

  /// Register or replace a command. Returns `this` for chaining.
  CommandRegistry register(GlazeCommand command) {
    if (!command.name.startsWith('/')) {
      throw ArgumentError(
        'Command name must start with "/" (got "${command.name}")',
      );
    }
    _commands[command.name] = command;
    return this;
  }

  /// Run a command. Unknown commands return a `CommandResult.error`
  /// with the available-command list appended.
  Future<CommandResult> run(
    String name,
    Map<String, dynamic> args, {
    CommandContext context = const CommandContext(),
  }) async {
    final cmd = _commands[name];
    if (cmd == null) {
      return CommandResult.error(
        'Unknown command "$name". Available: ${_commands.keys.join(", ")}',
      );
    }
    try {
      return await cmd.handler(args, context);
    } catch (e) {
      if (kDebugMode) debugPrint('[CommandRegistry] $name failed: $e');
      return CommandResult.error(e.toString());
    }
  }

  /// Returns the registered commands. Used by the editor UI and by
  /// the bridge's help text.
  List<GlazeCommand> list() => _commands.values.toList(growable: false);
}

/// Convenience builder that wires up the MVP commands.
///
/// The handlers are intentionally trivial — they show that the
/// `executeCommand` bridge method can call back into existing
/// capabilities (`triggerGeneration`, `setVariables`, etc.) without
/// re-implementing them. The MVP does **not** route to
/// `GlazeCommand` handlers from the JS bridge yet (the bridge still
/// uses the dedicated methods). The command registry is exposed so
/// that future UI surfaces (settings, macro cheat sheet) can
/// discover the available commands.
CommandRegistry buildDefaultCommandRegistry() {
  final registry = CommandRegistry();
  registry.register(
    GlazeCommand(
      name: '/trigger',
      summary: 'Trigger a chat generation. Args: { mode?: "continue" | "regenerate" | "auto" }',
      handler: (args, context) async {
        // Real wiring: in production, the registry is given a
        // dispatch closure by the bridge wiring. The MVP just echoes
        // the call so the contract is testable without a full Riverpod
        // container.
        return CommandResult.ok(
          message: 'trigger ${args['mode'] ?? TriggerMode.auto.name} '
              'for charId=${context.charId ?? '(none)'}',
        );
      },
    ),
  );
  registry.register(
    GlazeCommand(
      name: '/getvar',
      summary: 'Read a JS variable. Args: { scope: "chat"|"character"|"global"|"message", path: string }',
      handler: (args, context) async {
        return CommandResult.ok(
          message: 'getvar scope=${args['scope']} path=${args['path']}',
        );
      },
    ),
  );
  registry.register(
    GlazeCommand(
      name: '/setvar',
      summary: 'Write a JS variable. Args: { scope, path?, values? }',
      handler: (args, context) async {
        return CommandResult.ok(
          message: 'setvar scope=${args['scope']}',
        );
      },
    ),
  );
  registry.register(
    GlazeCommand(
      name: '/inject',
      summary: 'Inject a runtime prompt block. Args: { id, content, depth?, role? }',
      handler: (args, context) async {
        return CommandResult.ok(message: 'inject id=${args['id']}');
      },
    ),
  );
  registry.register(
    GlazeCommand(
      name: '/toast',
      summary: 'Show a toast. Args: { message, severity? }',
      handler: (args, context) async {
        return CommandResult.ok(message: 'toast: ${args['message']}');
      },
    ),
  );
  return registry;
}
