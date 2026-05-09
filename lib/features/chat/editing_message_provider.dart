import 'package:flutter_riverpod/flutter_riverpod.dart';

final editingMessageIndexProvider =
    StateProvider.family<int?, String>((ref, charId) => null);
