// The value shown in place of a masked cell.
//
// Masked columns are selected as `NULL AS "col"`, so the real value never
// leaves the database; this sentinel then replaces the NULL so the grid,
// the inspector, copy/TSV/CSV and exports all show the mask instead of an
// empty cell. (Primary keys are the one exception: they are always fetched
// for paging, and replaced with the sentinel after the cursor is taken.)

class MaskedValue {
  const MaskedValue();

  static const instance = MaskedValue();
  static const text = '••••';

  @override
  String toString() => text;
}

/// Replaces the cells at [maskedIndexes] in every row with [MaskedValue].
List<List<Object?>> maskRows(
  List<List<Object?>> rows,
  Set<int> maskedIndexes,
) {
  if (maskedIndexes.isEmpty) return rows;
  return [
    for (final row in rows)
      [
        for (var i = 0; i < row.length; i++)
          maskedIndexes.contains(i) ? MaskedValue.instance : row[i],
      ],
  ];
}
