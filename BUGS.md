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

### `scripts/add_changelog_line.sh` can't add any line: `CHANGELOG.md` has no `---` line

- **Where.** `CHANGELOG.md` header; the check is in `scripts/add_changelog_line.sh` (the awk `END` block)
- **Failure.** `bash scripts/add_changelog_line.sh "<line>"` exits 1 with `CHANGELOG.md needs a --- line under its header`, so no change since then has a changelog line. The SEO landing-page change of 2026-11-02 is missing one: "Landing page: canonical URL, fuller social tags, SoftwareApplication and FAQPage structured data, a visible FAQ, sitemap.xml and llms.txt, checked on every Pages deploy by scripts/check_site_seo.sh".
- **Noticed.** 2026-11-02, finishing `/find-seo-aeo-improvements`.
- **Confidence.** confirmed (script output)
- **Why not fixed on the spot.** Agents are blocked from reading `CHANGELOG.md`; a person needs to add the `---` line under its header, then re-run the script with the line above.

### Query result headers show `Type(oid:2950)` instead of the Postgres type name

- **Where.** `lib/db/postgres_executor.dart:54` (`PostgresExecutor.execute`, `typeName: column.type.toString().split('.').last`)
- **Failure.** Run any query in a Query tab against Postgres: the column headers read `Type(oid:2950)` for a `uuid` column and `Type(oid:25)` for `text`, because `pg.Type.toString()` prints the oid, not a name. Anything keyed on `DbColumn.typeName` (the typed-cell colours in `lib/grid/typed_value_text.dart`) likely gets no match for query results.
- **Noticed.** 2026-10-30, while cropping screenshots of the AI SQL feature for a social post.
- **Confidence.** likely (seen in the screenshot, not traced through the colour mapping)
- **Why not fixed on the spot.** Outside the task (marketing assets only, no app code changed).

## Accepted limitations

Bugs we decided not to fix. Each one says why, and what would change the decision.

<!-- Move an entry here instead of deleting it when the answer is "won't fix". -->
