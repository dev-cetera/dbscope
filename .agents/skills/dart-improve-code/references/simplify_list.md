# Simplify list (Step 5 of /dart-improve-code)

Apply what fits, one file at a time. If unsure an edit is "same behaviour" by reading the diff, skip it and list it under "Skipped".

- **Rule 7** Expand cryptic identifiers (`ctx` → `context`, `ctrl` → `controller`, `cs` → `colorScheme`, `tt` → `textTheme`, `desc` → `description`, `msg` → `message`, `idx` → `index`, `curr` → `current`). Only local variables, parameters and private members; never public APIs, generated bindings or names matching external schemas.
- **Rule 7** `var` on fields / parameters / return types: write the type. Leave `var` on locals whose right-hand side makes the type obvious. Skip fields when `analysis_options.yaml` enables `omit_obvious_property_types` (that lint requires `var` there).
- **Rule 7** Integer literals on `double` properties: add `.0` (`16` → `16.0` for `fontSize`). If the type is unclear, skip.
- **Rule 7** A private `_buildFoo()` returning a `Widget`, used in one file: extract to a `Widget` class, placed per `<layout-rules>`. If it closes over local state so extraction is not trivial, skip and list it.
- **Rule 7** Magic numbers in non-obvious context: `const _kFoo = N;` at file scope.
- **Rule 9** `if (x) return true; else return false;` → `return x;`. Delete commented-out code (git remembers). Replace a hand-written null-passthrough ternary with the project's helper only if one exists.
- **Rule 9** Generic names (`data`, `info`, `helper`, `manager`): propose a better name in the report; do not rename without proposing first.
- **Rule 6** A function called from exactly one place that does not aid naming: inline it. Skip if it is tested directly or exported.
- **Rule 6** Nesting deeper than 3 levels in one function: use a guard clause if a clean one exists. Do not split into several new helpers.
