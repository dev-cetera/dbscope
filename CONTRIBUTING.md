# Contributing to dbscope

Thanks for helping! dbscope is **vibe coded**: most of the code was written by
an AI (Claude Code) with a human steering, reviewing and testing. That means
two things for you:

- There are rough edges. Bug reports are genuinely useful, even small ones.
- The architecture and its rules are written down, because the AI needed them
  too. Read [`CLAUDE.md`](CLAUDE.md) before a non-trivial change — it is the
  best map of the codebase, for humans and agents alike.

## Reporting a bug

[Open an issue](https://github.com/dev-cetera/dbscope/issues/new/choose) and
pick the bug template. The most useful details are: OS + version, which
backend (Postgres / Cloud SQL / SQLite / on-device / web proxy), the Postgres
version if relevant, and the steps to reproduce.

Never paste passwords, API keys or `.dbscopeconn` files into an issue.
Security problems go through [`SECURITY.md`](SECURITY.md), not public issues.

## Getting set up

Flutter is pinned via [FVM](https://fvm.app) in `.fvmrc`.

```sh
fvm install
fvm flutter pub get
fvm flutter run -d macos
```

Before opening a PR:

```sh
fvm flutter analyze
fvm flutter test
```

CI runs the same two commands on every PR.

## Making a change

- Look for issues labelled
  [`good first issue`](https://github.com/dev-cetera/dbscope/labels/good%20first%20issue)
  or [`help wanted`](https://github.com/dev-cetera/dbscope/labels/help%20wanted).
  Comment on one before starting something large so work isn't duplicated.
- Each file under `test/` opens with a comment stating the contract it pins
  down. Read it before editing the code it covers, and keep it true.
- The SQL safety invariants in `CLAUDE.md` are non-negotiable: identifiers go
  through `quoteIdent`, values are positional parameters, cell edits keep the
  optimistic-concurrency check.
- New database backends, themes, tabs, menus and sidebar actions are all
  plugins (`DbscopePlugin`). Prefer a plugin over editing the core.
- Match the style of the surrounding code. Keep PRs focused — one fix or
  feature per PR.

Using an AI assistant for your PR is welcome; just review what it wrote as
carefully as you'd review a stranger's code, and make sure the tests pass.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
