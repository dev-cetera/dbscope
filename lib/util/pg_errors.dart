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
  ClassifiedError(
    this.kind,
    this.message,
    this.original, {
    this.constraintName,
  });
  final PgErrorKind kind;
  final String message;
  final String? constraintName;
  final Object original;

  @override
  String toString() => message;
}

({String? code, String? message, String? constraintName}) _probe(Object error) {
  String? code;
  String? message;
  String? constraint;
  try {
    final dyn = error as dynamic;
    // Duck-typed on purpose: `classify` takes anything thrown by any driver
    // (postgres, sqlite, the pg proxy), which share no type; the try/catch
    // absorbs a missing field.
    // ignore: avoid_dynamic_calls
    final rawCode = dyn.code;
    if (rawCode is String) code = rawCode;
  } catch (_) {}
  try {
    final dyn = error as dynamic;
    // Duck-typed on purpose: `classify` takes anything thrown by any driver
    // (postgres, sqlite, the pg proxy), which share no type; the try/catch
    // absorbs a missing field.
    // ignore: avoid_dynamic_calls
    final rawMessage = dyn.message;
    if (rawMessage is String) message = rawMessage;
  } catch (_) {}
  try {
    final dyn = error as dynamic;
    // Duck-typed on purpose: `classify` takes anything thrown by any driver
    // (postgres, sqlite, the pg proxy), which share no type; the try/catch
    // absorbs a missing field.
    // ignore: avoid_dynamic_calls
    final rawConstraintName = dyn.constraintName;
    if (rawConstraintName is String) constraint = rawConstraintName;
  } catch (_) {}
  return (code: code, message: message, constraintName: constraint);
}

ClassifiedError classify(Object error) {
  final typeName = error.runtimeType.toString();
  final probed = _probe(error);
  final code = probed.code ?? '';
  final message = probed.message ?? error.toString();
  final constraint = probed.constraintName;

  if (typeName.contains('ServerException')) {
    if (code == '25006' || message.contains('read-only transaction')) {
      return ClassifiedError(
        PgErrorKind.readOnlyTransaction,
        'This connection is read-only.',
        error,
      );
    }
    if (code == '23514') {
      final friendly = constraint != null
          ? 'Check constraint "$constraint" failed: $message'
          : 'Check constraint failed: $message';
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
        message,
        error,
        constraintName: constraint,
      );
    }
    if (code.startsWith('28') || code.startsWith('42501')) {
      return ClassifiedError(
        PgErrorKind.permission,
        message,
        error,
        constraintName: constraint,
      );
    }
    return ClassifiedError(
      PgErrorKind.other,
      message,
      error,
      constraintName: constraint,
    );
  }
  if (typeName.contains('PgException')) {
    return ClassifiedError(PgErrorKind.connection, message, error);
  }
  return ClassifiedError(PgErrorKind.other, message, error);
}
