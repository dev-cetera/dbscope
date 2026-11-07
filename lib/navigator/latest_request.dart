/// Hands out a ticket per request and says whether a ticket is still the
/// newest. A caller takes a ticket before it starts async work and checks it
/// after every `await`: a request that was overtaken by a newer one drops
/// its result instead of overwriting the newer request's.
class LatestRequest {
  var _latest = 0;

  /// Starts a new request, making every earlier ticket stale.
  int begin() => ++_latest;

  /// True while [ticket] is the newest one handed out.
  bool isCurrent(int ticket) => ticket == _latest;
}
