import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/profile_model_work.dart';

final profileModelWorkProvider = Provider<ProfileModelWork>(
  (_) => ProfileModelWork(),
);
