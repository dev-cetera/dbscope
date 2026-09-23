import 'package:uuid/uuid.dart';

import '../query/cancel_token.dart';

/// Base type for every tab kind shown in the main area. Each concrete
/// tab lives in its own feature folder (e.g. `lib/table/table_tab.dart`,
/// `lib/query/query_tab.dart`) and registers itself with `AppState`
/// via the same `tabs` list.
///
/// State that should persist across app restarts goes here or on the
/// subclass; transient state (in-flight Futures, scroll controllers)
/// lives on the matching view widget.
abstract class TabModel {
  final String id;
  final String connectionId;
  CancelToken? cancelToken;

  /// Pinned tabs survive [AppState] auto-eviction and the
  /// "Close others / to right / to left" actions.
  bool pinned = false;

  /// Monotonic counter snapshot from `AppState._tabClock` at last
  /// activation. Used as the LRU key when evicting beyond
  /// `AppState.maxTabs`.
  int lastActivatedAt = 0;

  TabModel({String? id, required this.connectionId})
    : id = id ?? const Uuid().v4();

  String get title;
}
