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

## Accepted limitations

Bugs we decided not to fix. Each one says why, and what would change the decision.

<!-- Move an entry here instead of deleting it when the answer is "won't fix". -->
