import 'package:postgres/postgres.dart' as pg;

/// Postgres's geometric types. None of them has a usable `=` (point, path
/// and polygon have none at all; box and circle compare areas), and the
/// driver can't send most of them back as a bind parameter, so the edit
/// guard compares them as Postgres text (see `CellEditor`).
const pgGeometricTypes = {'point', 'line', 'lseg', 'box', 'path', 'polygon', 'circle'};

/// [value] in Postgres's input syntax when it is one of the driver's
/// geometric objects (`Point(1.0,2.0)` → `(1.0,2.0)`), else [value]
/// unchanged. Dart's shortest round-trip doubles parse back to the same
/// float8, so the server reads exactly the value it sent.
Object? pgGeometryText(Object? value) => switch (value) {
  pg.Point() => _point(value),
  pg.Line() => '{${value.a},${value.b},${value.c}}',
  pg.LineSegment() => '[${_point(value.p1)},${_point(value.p2)}]',
  pg.Box() => '${_point(value.p1)},${_point(value.p2)}',
  // Path extends Polygon, so it has to come first.
  pg.Path() => value.open ? '[${_points(value)}]' : '(${_points(value)})',
  pg.Polygon() => '(${_points(value)})',
  pg.Circle() => '<${_point(value.center)},${value.radius}>',
  _ => value,
};

String _point(pg.Point point) => '(${point.latitude},${point.longitude})';

String _points(pg.Polygon polygon) => polygon.points.map(_point).join(',');
