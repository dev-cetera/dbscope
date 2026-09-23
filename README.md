# dbscope

A Flutter desktop Postgres viewer and editor for macOS, Windows, and Linux. Browse schemas, run queries, edit rows, and navigate foreign-key relationships across huge tables.

## Getting started

Flutter is pinned to 3.41.9 via FVM (see `.fvmrc`). Prefix commands with `fvm` to pick up the right SDK.

```
fvm flutter pub get
fvm flutter run -d macos     # or -d windows / -d linux
```

That's it - the app launches, and you add a connection profile from the UI.

## Other useful commands

```
fvm flutter analyze          # lint
fvm flutter test             # run tests
```
