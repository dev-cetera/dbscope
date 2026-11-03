// Contract: pgGeometryText writes the Postgres driver's geometric objects
// in Postgres's input syntax (so the server can parse them back for the
// cell-edit guard and the editor), and leaves every other value alone.

import 'package:dbscope/db/pg_geometry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart' as pg;

void main() {
  test('writes each geometric type in Postgres input syntax', () {
    const a = pg.Point(1.5, -2);
    const b = pg.Point(0, 0);
    expect(pgGeometryText(a), '(1.5,-2.0)');
    expect(pgGeometryText(pg.Line(1, -1, 0.25)), '{1.0,-1.0,0.25}');
    expect(pgGeometryText(pg.LineSegment(a, b)), '[(1.5,-2.0),(0.0,0.0)]');
    expect(pgGeometryText(pg.Box(a, b)), '(1.5,0.0),(0.0,-2.0)');
    expect(pgGeometryText(pg.Path(const [a, b], open: true)), '[(1.5,-2.0),(0.0,0.0)]');
    expect(pgGeometryText(pg.Path(const [a, b], open: false)), '((1.5,-2.0),(0.0,0.0))');
    expect(pgGeometryText(pg.Polygon(const [a, b])), '((1.5,-2.0),(0.0,0.0))');
    expect(pgGeometryText(pg.Circle(b, 2)), '<(0.0,0.0),2.0>');
  });

  test('leaves other values unchanged', () {
    expect(pgGeometryText('x'), 'x');
    expect(pgGeometryText(3), 3);
    expect(pgGeometryText(null), isNull);
  });
}
