import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/crash_recovery_service.dart';
import '../chat_provider.dart';

class SessionLifecycleTracker extends ConsumerStatefulWidget {
  final String charId;
  final Widget child;
  const SessionLifecycleTracker({super.key, required this.charId, required this.child});

  @override
  ConsumerState<SessionLifecycleTracker> createState() => _SessionLifecycleTrackerState();
}

class _SessionLifecycleTrackerState extends ConsumerState<SessionLifecycleTracker> with WidgetsBindingObserver {
  DateTime? _enteredAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _markActive();
    _enteredAt = DateTime.now();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _doMarkClosed();
    _flushTime();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) _markActive();
      _enteredAt = DateTime.now();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (mounted) _doMarkClosed();
      _flushTime();
    }
  }

  Future<void> _markActive() async {
    final service = ref.read(crashRecoveryProvider);
    final chatState = ref.read(chatProvider(widget.charId)).value;
    final sessionId = chatState?.session?.id ?? '';
    if (sessionId.isNotEmpty) {
      await service.markSessionActive(sessionId, widget.charId);
    }
  }

  void _doMarkClosed() {
    try {
      final service = ref.read(crashRecoveryProvider);
      service.markSessionClosed();
    } catch (_) {}
  }

  Future<void> _flushTime() async {
    if (_enteredAt == null) return;
    final elapsed = DateTime.now().difference(_enteredAt!).inSeconds;
    _enteredAt = null;
    if (elapsed <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'chat_time_${widget.charId}';
      final prev = prefs.getInt(key) ?? 0;
      await prefs.setInt(key, prev + elapsed);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
