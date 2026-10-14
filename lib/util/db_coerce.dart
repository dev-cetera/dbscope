// Lenient value coercion for DbExecutor result rows. Backends return
// inconsistent shapes: the Postgres driver hands back typed numerics
// straight from the wire protocol; HTTP-mediated backends (e.g.
// pg_proxy) come back as JSON strings via Python `str()`. These helpers
// let one call site work across all of them — the catalog SQL itself
// guarantees the column's semantic type, so a lenient parse here is
// safe.

int? toInt(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = num.tryParse(value);
    return parsed?.toInt();
  }
  return null;
}

/// Lenient bool parse. Python `str(True)` is `"True"`; flitescope's
/// gzipped JSON path may also send `"true"` or `1`. Treat unrecognised
/// values as false (catalog queries always select a `bool` cast).
bool toBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final lower = value.toLowerCase();
    return lower == 'true' || lower == 't' || lower == '1';
  }
  return false;
}
