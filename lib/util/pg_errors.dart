// Backend-agnostic error classifier. We deliberately do NOT import
// package:postgres here so this file compiles on web (where package:postgres
// uses dart:io Socket and won't build).
//
// `ServerException` / `PgException` from package:postgres expose `.code`,
// `.message`, and `.constraintName` as instance fields. We read those via
// dynamic dispatch so the classifier works whether or not postgres is on
// the classpath, and falls back to the error's toString() on web/non-pg
// backends.

enum PgErrorKind {
  connection,
  readOnlyTransaction,
  syntax,
  permission,
  checkViolation,
  other,
}

class ClassifiedError {
  final PgErrorKind kind;
  final String message;
  final String? constraintName;
  final Object original;

  ClassifiedError(
    this.kind,
    this.message,
    this.original, {
    this.constraintName,
  });

  @override
  String toString() => message;
}

({String? code, String? message, String? constraintName}) _probe(Object error) {
  String? code;
  String? message;
  String? constraint;
  try {
    final dyn = error as dynamic;
    final c = dyn.code;
    if (c is String) code = c;
  } catch (_) {}
  try {
    final dyn = error as dynamic;
    final m = dyn.message;
    if (m is String) message = m;
  } catch (_) {}
  try {
    final dyn = error as dynamic;
    final n = dyn.constraintName;
    if (n is String) constraint = n;
  } catch (_) {}
  return (code: code, message: message, constraintName: constraint);
}

ClassifiedError classify(Object error) {
  final typeName = error.runtimeType.toString();
  final probed = _probe(error);
  final code = probed.code ?? '';
  final msg = probed.message ?? error.toString();
  final constraint = probed.constraintName;

  if (typeName.contains('ServerException')) {
    if (code == '25006' || msg.contains('read-only transaction')) {
      return ClassifiedError(
        PgErrorKind.readOnlyTransaction,
        'This connection is read-only.',
        error,
      );
    }
    if (code == '23514') {
      final friendly = constraint != null
          ? 'Check constraint "$constraint" failed: $msg'
          : 'Check constraint failed: $msg';
      return ClassifiedError(
        PgErrorKind.checkViolation,
        friendly,
        error,
        constraintName: constraint,
      );
    }
    if (code.startsWith('42')) {
      return ClassifiedError(
        PgErrorKind.syntax,
        msg,
        error,
        constraintName: constraint,
      );
    }
    if (code.startsWith('28') || code.startsWith('42501')) {
      return ClassifiedError(
        PgErrorKind.permission,
        msg,
        error,
        constraintName: constraint,
      );
    }
    return ClassifiedError(
      PgErrorKind.other,
      msg,
      error,
      constraintName: constraint,
    );
  }
  if (typeName.contains('PgException')) {
    return ClassifiedError(PgErrorKind.connection, msg, error);
  }
  return ClassifiedError(PgErrorKind.other, msg, error);
}
