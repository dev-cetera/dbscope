# Bugs

Every open bug, suspected or confirmed. Usually something an agent or a person ran into while doing something else and couldn't fix on the spot. Newest first.

This file is for things with a real failure: wrong output, a crash, lost data, a check that can never fire. Work that has no failure goes in `TODO.md`. Fixed bugs are deleted from here and get a line in `CHANGELOG.md`.

Don't read this file whole. Search it for the file or symbol first:

```sh
rg -n --max-count 5 '<file or symbol>' BUGS.md
```

## Entry format

```text
### <one-line claim of what's wrong>

- **Where.** `path/to/file:123` (`SymbolName`)
- **Failure.** Concrete input or state, then the wrong output, crash or loss.
- **Noticed.** YYYY-MM-DD, while <what you were doing>.
- **Confidence.** suspected | likely | confirmed
- **Why not fixed on the spot.** For example: outside the task, needs a decision, would blow up the diff.
```

## Open

<!-- New entries go here, newest first. -->

### Editing a point, path or polygon cell on Postgres always fails

- **Where.** `lib/db/dml.dart` (`CellEditor._postgresGuard`).
- **Failure.** Edit a `point` (also `path`, `polygon`) cell in a table grid: the optimistic guard `"p" IS NOT DISTINCT FROM $3` fails with `operator does not exist: point = unknown`, because these types have no `=` operator. Casting both sides to text doesn't help: the driver decodes the old value into a `Point` whose `toString()` (`Point(1.0,2.0)`) is not Postgres's text form (`(1,2)`), so the guard matches no row and every save reads as a conflict.
- **Noticed.** 2026-11-03, while fixing the same failure for `json` and `xml` columns (checked against a local Postgres 16).
- **Confidence.** confirmed (for `point`, by running the UPDATE; `path` and `polygon` by the Postgres docs).
- **Why not fixed on the spot.** Needs a decision: compare with the type's `~=` "same as" operator, render the driver's geometric objects back to Postgres text, or make these columns read-only in the grid.

## Accepted limitations

Bugs we decided not to fix. Each one says why, and what would change the decision.

<!-- Move an entry here instead of deleting it when the answer is "won't fix". -->
