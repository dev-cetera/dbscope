/// Makes result-set column names unique for a target that refuses
/// duplicates (a SQLite table): the second `id` becomes `id_2`, the third
/// `id_3`, skipping any suffix that is already taken. Order is kept.
List<String> uniqueColumnNames(List<String> names) {
  final taken = <String>{for (final n in names) n.toLowerCase()};
  final seen = <String>{};
  final out = <String>[];
  for (final name in names) {
    final key = name.toLowerCase();
    if (seen.add(key)) {
      out.add(name);
      continue;
    }
    var n = 2;
    while (taken.contains('${key}_$n')) {
      n++;
    }
    final unique = '${name}_$n';
    taken.add(unique.toLowerCase());
    seen.add(unique.toLowerCase());
    out.add(unique);
  }
  return out;
}
