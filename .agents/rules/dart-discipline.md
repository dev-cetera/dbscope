---
# Path-scoped (Claude Code): auto-loads only when a matching file is read or edited.
paths:
  - "**/*.dart"
---

# Dart / Flutter Discipline

The standing rules for any Dart or Flutter code in any project, layered on top of the standard Dart style rules: covering behaviour, safety, simplicity, and pattern consistency. Read this file before running `/dart-audit-code` or `/dart-improve-code`; both commands enforce these rules and this file is the single source of truth.

## Rule 1: Behaviour preservation

Every change must preserve observable behaviour unless the user has explicitly asked for a behaviour change.

**Why:** A change that quietly alters observable behaviour while presenting as a refactor is the most expensive kind of regression: reviewers trust the "no behaviour change" framing and skim. Preserving behaviour by default keeps that trust intact.

- Do **not** "improve" algorithms, switch data structures, or rewrite control flow when the existing version works. A working ugly function stays ugly until someone asks otherwise.
- Do **not** introduce abstractions, base classes, mixins, generics, or extension methods that the current call sites don't require.
- Do **not** rename public APIs (class names, public method names, exported symbols): these may be referenced by other packages, generated code, or stored data.
- Do **not** change file paths or move declarations between files unless explicitly requested.
- If a refactor is genuinely worth doing but is larger than a local edit, **report it, don't do it**.

When in doubt: leave it alone.

## Rule 2: No `late`

`late` defers a null-safety violation from compile time to runtime. Treat it as forbidden in application code.

**Why:** The whole point of null-safety is that the compiler catches missing initialisation. `late` opts back out and turns the same bug into a runtime `LateInitializationError` at the worst possible moment.

Replacements (in order of preference):

1. Make it `final` with an initialiser at the declaration site.
2. Make it `final` and initialise in a constructor initializer list (`Foo() : _x = computeX();`).
3. If the value genuinely arrives later, make it nullable (`Foo? _foo`) and read through `_foo!` only at sites that can prove non-null, or better, return the value from a method rather than caching it.
4. For `StatefulWidget.initState` work, prefer `final` fields initialised in `initState` body if the type allows, or fall back to nullable.

The only acceptable `late` is `late final` for a value that is genuinely impossible to compute eagerly **and** is part of a documented external contract (e.g. a generated binding). These are rare; if you reach for `late`, the answer is "restructure".

## Rule 3: Avoid unnecessary nulls

Nullability is a real type system feature, not a default. Use it only when the absence of a value is part of the domain.

**Why:** A `T?` is a contract with every downstream caller and every branch. Used loosely it sprinkles `?.` and `??` through the whole call tree; used narrowly it documents the one place where "no value" is a real outcome the caller must handle.

- A field that is "always set before use" is not nullable: it's a constructor parameter.
- A list that "might be empty" is not nullable: it's `const []` or `<T>[]`.
- A string that "might be missing" is usually `''` if downstream code treats empty and absent identically.
- Function parameters: if the function cannot meaningfully run with `null`, take a non-nullable parameter and let the caller guard.
- Return types: only return `T?` if "no value" is a real outcome the caller must distinguish from `T`. Don't use `null` to signal errors: throw or return a result type.

When a nullable type is justified, handle it at the **boundary** (the point where the value enters your scope), not by scattering `?.` and `??` through the body.

## Rule 4: Single source of truth for names and keys

Any string used as a map key, JSON field name, query parameter, storage key, collection or table name, route name, event name, flag name, or DB column **must be declared once**. A closed set of NAMES is an enum (4a); the KEYS of one record are constants (4b).

**Why:** A string literal repeated as a key is a typo waiting to happen, and the failure mode is a silently missing field rather than a crash. A single named constant makes the read and the write provably refer to the same key.

### 4a: A closed set of names is an enum, and `.name` is the string

Storage collections, preference slots, events, flags, jobs, permissions, error codes, asset names: each is a value chosen from a known set, so it is an enum whose UPPER_SNAKE member IS the string.

```dart
enum CacheCollection { ITEMS, GROUPS, ACTIVITIES_ENVELOPE }

final store = stringMapStoreFactory.store(CacheCollection.ITEMS.name); // 'ITEMS'
final parsed = CacheCollection.values.valueOf(raw) ?? (throw FormatException('Unknown collection: $raw'));
```

- Never type the name a second time: not as `static const ITEMS = 'items';`, and not as a constructor argument that repeats the member (`ITEMS('items')`).
- When an outsider dictates the spelling (a file on disk, a URL segment, a vendor's lowercase word), derive it from `.name` in ONE getter on the enum: `String get fileBase => name.toLowerCase();`. A constructor parameter is only for data the name cannot give (a label, a vendor number).
- Parse with one helper that ignores case and returns null on a miss (for example df_type's `X.values.valueOf(s)`) and decide at the call what a miss means (`?? (throw …)`, `?? X.DEFAULT`). Never a hand `values.firstWhere((e) => e.name == s)` in a `try`, never `byName` (it throws), never a `switch` on the raw string.
- In a const context, key by the member (`Map<CacheCollection, …>`), not by its string.
- Changing a stored spelling is a data migration: plan it with the schema or cache version, never as a drive-by rename.

### 4b: The keys of one record are constants

The field names of a JSON object, a map, a template's variables, or a query string name the parts of one shape, not a value chosen from a set. Keep them as constants (generated `XxxFieldNames` where a generator owns the shape):

```dart
// keys.dart (or co-located with the consumer)
abstract final class UserKeys {
  static const id = 'id';
  static const name = 'name';
  static const createdAt = 'createdAt';
}

// usage
final name = json[UserKeys.name] as String;
final body = {UserKeys.id: id, UserKeys.name: name};
```

Rules:

- Never write the same string literal as a map key in two places. The second occurrence is a bug waiting to happen.
- Group related keys in an `abstract final class` (acts as a namespace, can't be instantiated). If the class's members are names of things rather than fields of one shape, it is 4a: make it an enum.
- Name the constant exactly the same as the string it holds: `name = 'name'`, `createdAt = 'createdAt'`. This keeps the field ↔ constant ↔ key chain visually aligned and obvious.
- If a key is used only inside one file, declare it `const` at file scope (`const _kRouteName = 'home';`).
- When you see a string literal map key during review, the question is not "is this fine". The question is "where else is this string used".

## Rule 5: Defensive measures without convoluting code

Defend at boundaries. Trust internals.

**Why:** Defensive code inside trusted internals adds comprehension cost without preventing real failures. Bad data crosses boundaries; the right place to validate is the boundary, not every layer downstream.

- **Validate** at the points where data enters the program: HTTP responses, file parsing, user input, IPC, database rows. Once validated, downstream code can assume the data is well-formed.
- **Do not** add null checks, range checks, type checks, or try/catch inside private helpers that are only called from already-validated code. Internal asserts are fine if they document an invariant (`assert(items.isNotEmpty);`).
- **Do not** wrap every `await` in a try/catch. Catch only where there's a meaningful response to the error (retry, fallback, user-facing message, structured log). Otherwise let it propagate.
- **Do not** add `if (foo == null) return;` early returns to non-nullable values "just in case". If the type says non-null, trust the type.
- Prefer **types** to runtime checks. If a value must be one of three states, use an enum or a sealed class: don't accept `String` and check the string content.
- A defensive check that has never fired in production is more often a comprehension cost than a safety net. If you can't articulate the failure mode it prevents, delete it.

## Rule 6: Short, simple, dumb

The reader is tired. Optimise for them.

**Why:** A short, boring function is faster to understand than a clever one, even when the clever one is fewer characters. Code is read far more often than it is written; comprehension cost dominates every other axis.

- A function that fits on one screen is easier to understand than two clever helpers.
- A flat `if/else` chain beats a polymorphic hierarchy with three subclasses.
- Three similar lines beat a parametric helper that handles all three.
- Inline a function that is called from exactly one place and doesn't aid naming.
- Prefer the boring construct: `for` over `fold` when accumulating with side-effects, `if` over ternary when the branches are not symmetric, named methods over anonymous closures when the closure is more than one line.
- Cyclomatic complexity inside a single function should stay manageable: if a function has more than 3 levels of nesting, extract a guard clause or a named helper.

This is **not** a licence to introduce abstractions. Inline simplification is preferred over restructuring.

## Rule 7: Readability over shortcuts

Kill cryptic abbreviations, untyped escape hatches, and magic literals.

**Why:** Short names and clever shortcuts trade keystrokes during writing for confusion during reading. Code is read far more than written, so the trade rarely pays off.

- No cryptic abbreviations. `controller`, not `ctrl`. `context`, not `ctx`. `colorScheme`, not `cs`. `description`, not `desc`. (See the existing Dart style rules for the full list.)
- No `_buildFoo()` helper methods. Extract a `Widget` class.
- No `dynamic` unless the type genuinely is dynamic (`Map<String, dynamic>` for JSON is fine; `dynamic foo = ...` in normal code is not).
- No `var` for fields, parameters, or return types: write the type. `var` is acceptable for local variables where the RHS makes the type obvious.
- No `as` casts where a typed parse is possible. `json['x'] as String` is fine at a boundary; `someObject as MySubclass` deeper inside the code usually means a missing abstraction or a pattern match.
- No magic numbers: `const _kMaxRetries = 3;`, not `for (var i = 0; i < 3; i++)`.
- Doubles always `16.0`, never `16`.

## Rule 8: Consistent patterns

Within a single codebase, the same problem should be solved the same way every time. Pattern consistency is *more* important than picking the optimal pattern: a uniform codebase is one you can skim; a varied one you have to read.

**Why:** The cost of mixed patterns compounds across every future change: every reader has to recognise which variant they're in, every author has to decide which to follow. A uniform codebase removes that tax even when the chosen pattern is not the locally optimal one.

Concretely:

- If repositories return `Future<Result<T>>` in one place, they do everywhere.
- If state lives in one state library (riverpod, bloc, df_pod, signals), it lives there everywhere. No second library for new screens.
- If a section of UI is extracted as `class FooCard extends StatelessWidget` in one screen, similar sections in other screens are also extracted.
- If errors are thrown in one layer and caught in another, that boundary holds for the whole layer.
- Spelling, casing, and field-order conventions on serialised JSON match the back-end schema everywhere, not just in the new code.

When you see two ways of doing the same thing in the codebase, flag it during `/dart-audit-code` and let the human decide which to standardise on: don't unilaterally rewrite either.

## Rule 9: Anti-pattern catalogue

Direct things to flag and (where safe) fix. Each anti-pattern has a one-line "why" because the *why* is what tells you whether an edge case applies.

**Why:** A named catalogue of failure modes makes review faster and more consistent: both for humans and for `/dart-audit-code`. Naming the failure mode also makes it easier to argue about edge cases instead of debating taste.

- **`late` field**: defers null-safety to runtime crash. Make `final`, nullable, or restructure.
- **Magic-string map key**: a typo is a silent bug. Promote to a constant (see Rule 4).
- **String literal as enum value**: `if (status == 'ACTIVE')`. Use an enum or sealed class.
- **Name typed twice**: `static const ITEMS = 'items';`, or an enum member whose constructor repeats it (`ITEMS('items')`). Use the enum's `.name` (Rule 4a).
- **Hand-rolled enum lookup**: `values.firstWhere((e) => e.name == s)` in a `try`/`orElse`, `byName(s)`, `asNameMap()[s]`, or a `switch` on the string. Use the project's one lookup helper (for example df_type's `valueOf`) and handle the miss at the call.
- **`dynamic` in normal application code**: defeats the type system. Type it.
- **`!` on nullable without context**: if `foo!` is safe, why is the type nullable? Either narrow the type or handle the null.
- **`?? throw` on a value that should never be null**: the type is wrong; tighten it.
- **`_buildFoo()` helper method**: extract a `Widget` class.
- **Business logic in `build()`**: push into services / repos / pods.
- **`setState` in a project that uses a state library (or the reverse)**: pick one and stick to it.
- **`print` / `debugPrint`**: use the project's logger (`package:logging`, `df_log` or whatever it already depends on).
- **Try/catch swallowing exceptions silently**: at minimum log; preferably let it propagate.
- **`Future` that fires-and-forgets without `unawaited()`**: explicit `unawaited(foo())` documents intent.
- **`StreamController` exposed publicly**: expose `Stream`, keep the controller private.
- **Repeated literal lists / maps as defaults**: `const` them once at file scope.
- **Generic name that loses meaning**: `data`, `info`, `helper`, `manager`, `util`. Name the actual thing.
- **`if (x) return true; else return false;`**: `return x;`.
- **Boolean parameter at a call site without a name**: `doThing(true)` is unreadable. Use a named parameter or an enum.
- **`Map<String, dynamic>` floating past the boundary**: decode into a model at the boundary; downstream code gets a typed model.
- **Constructor with more than 4 positional args**: promote to named.
- **Field initialised in `initState` that could be `final` in a constructor**: make it `final`.
- **Re-implementing a utility the project already depends on**: check the existing packages in `pubspec.yaml` for an equivalent first.
- **`Widget? _foo;` cached widget reference held across rebuilds**: recompute or extract.
- **String concatenation for paths / URLs**: use `path.join`, `Uri`.
- **`identical` used where `==` was meant (or vice versa)**: `identical` checks reference, `==` checks value. Almost always want `==`.

## How the commands relate

- `/dart-audit-code` reads code and reports violations of this file. **No edits.**
- `/dart-improve-code` edits code in one pass: it first hardens (removes `late`, reduces nullability, defends at boundaries, dedupes map keys: Rules 2, 3, 4, 5), then simplifies (simplicity, readability, consistency: Rules 6, 7, 8, parts of 9). **Behaviour-preserving.**

**How to apply:**

- Run `/dart-audit-code` first when reviewing unfamiliar Dart code: it reports violations of every rule above without touching the source.
- Reach for `/dart-improve-code` when the audit finds Rule 2-8 violations to fix.
- In either command, Rule 1 (preserve behaviour) is non-negotiable. If a fix would change behaviour, flag it for the human instead of applying it.
- When two valid patterns coexist (Rule 8), flag the divergence and stop: do not unilaterally rewrite either side.
