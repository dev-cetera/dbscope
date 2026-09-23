// The on-disk plugin id for the local-file SQLite kind. Kept in its own
// file (no postgres / sqlite imports) so non-native call sites — including
// the web build — can reference the constant without dragging in
// dart:io- or FFI-bound dependencies.

const String kSqliteKind = 'sqlite';
