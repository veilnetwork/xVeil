import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/profile_model_work.dart';

final profileModelWorkProvider = Provider<ProfileModelWork>((ref) {
  final owner = ProfileModelWork();
  ref.onDispose(() => unawaited(owner.retire()));
  return owner;
});
