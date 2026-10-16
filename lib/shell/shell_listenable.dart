import 'package:flutter/foundation.dart';

import '../connection/registry.dart';
import 'app_state.dart';

/// Everything the shell chrome (tab strip, body, footer) renders from.
/// One shared instance so each subscriber doesn't build its own merge.
final shellListenable = Listenable.merge([
  AppState.instance,
  ConnectionRegistry.instance,
]);
