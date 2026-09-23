// Lenient value coercion for DbExecutor result rows. Backends return
// inconsistent shapes: the Postgres driver hands back typed numerics
// straight from the wire protocol; HTTP-mediated backends (e.g.
// pg_proxy) come back as JSON strings via Python `str()`. These helpers
// let one call site work across all of them — the catalog SQL itself
// guarantees the column's semantic type, so a lenient parse here is
// safe.

int? toInt(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  if (v is String) {
    final parsed = num.tryParse(v);
    return parsed?.toInt();
  }
  return null;
}

/// Lenient bool parse. Python `str(True)` is `"True"`; flitescope's
/// gzipped JSON path may also send `"true"` or `1`. Treat unrecognised
/// values as false (catalog queries always select a `bool` cast).
bool toBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    return s == 'true' || s == 't' || s == '1';
  }
  return false;
}
