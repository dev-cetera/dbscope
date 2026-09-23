// Generate a portable, passphrase-encrypted `.dbscopeconn` connection link
// from the command line — no GUI needed.
//
// The DB password and the encryption passphrase are read from the
// environment (or flags) so the secret never has to be typed on a command
// line that lands in shell history.
//
// Example (compledo prod — run after `gcloud auth login`):
//
// cd path/to/dbscope
// DB_PASSWORD="$(cd ../compledo/backend/infra/envs/prod && terraform output -raw db_password)" \
// LINK_PASSPHRASE='choose-a-passphrase' \
// dart run tool/make_connection_link.dart \
// --kind cloudsql \
// --name 'compledo prod' \
// --instance compledo-prod:australia-southeast1:compledo-db-prod \
// --database compledo --username app --port 9480 \
// --out ~/Desktop/compledo-prod.dbscopeconn
//
// Load it later in dbscope via File → "Import connection link…".

import 'dart:io';

import 'package:dbscope/connection/connection_link.dart';
import 'package:dbscope/connection/profile.dart';
import 'package:dbscope/db/cloudsql/cloudsql_config.dart';

Map<String, String> _parseFlags(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (!a.startsWith('--')) continue;
    final key = a.substring(2);
    final eq = key.indexOf('=');
    if (eq >= 0) {
      out[key.substring(0, eq)] = key.substring(eq + 1);
    } else if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
      out[key] = args[++i];
    } else {
      out[key] = 'true';
    }
  }
  return out;
}

Never _fail(String msg) {
  stderr.writeln('error: $msg');
  exit(2);
}

Future<void> main(List<String> args) async {
  final f = _parseFlags(args);
  final env = Platform.environment;

  final kind = f['kind'] ?? kCloudSqlKind;
  final name = f['name'] ?? 'connection';
  final database = f['database'] ?? 'postgres';
  final username = f['username'] ?? 'postgres';
  final port = int.tryParse(f['port'] ?? '') ?? 9480;
  final out = f['out'] ?? '$name.${ConnectionLink.fileExtension}';

  // Trust-auth backends (local dev Postgres) have no password. Allow an
  // empty one when --trust is passed; the link still round-trips (it just
  // encrypts an empty string).
  final trust = (f['trust'] ?? 'false') != 'false';
  var password = f['password'] ?? env['DB_PASSWORD'];
  if (password == null || password.isEmpty) {
    if (trust) {
      password = '';
    } else {
      _fail('no password — set DB_PASSWORD, pass --password, or use --trust');
    }
  }
  final passphrase = f['passphrase'] ?? env['LINK_PASSPHRASE'];
  if (passphrase == null || passphrase.isEmpty) {
    _fail('no passphrase — set LINK_PASSPHRASE or pass --passphrase');
  }

  final ConnectionProfile profile;
  if (kind == kCloudSqlKind) {
    final instance = f['instance'] ?? env['DB_INSTANCE'];
    if (instance == null || instance.split(':').length != 3) {
      _fail('cloudsql needs --instance project:region:instance');
    }
    final segs = instance.split(':');
    final cfg = CloudSqlConfig(
      instanceConnectionName: instance,
      gcpProject: f['project'] ?? segs.first,
      instanceName: segs.last,
      localPort: port,
      assignPublicIp: (f['assign-ip'] ?? 'true') != 'false',
    );
    profile = ConnectionProfile(
      kind: kCloudSqlKind,
      name: name,
      host: '127.0.0.1',
      port: port,
      database: database,
      username: username,
      password: password,
      readOnly: (f['read-only'] ?? 'true') != 'false',
      extra: cfg.toExtra(),
    );
  } else {
    profile = ConnectionProfile(
      kind: kind,
      name: name,
      host: f['host'] ?? 'localhost',
      port: port == 9480 ? 5432 : port,
      database: database,
      username: username,
      password: password,
      readOnly: (f['read-only'] ?? 'false') != 'false',
    );
  }

  final json = await ConnectionLink.encode(
    profile: profile,
    passphrase: passphrase,
  );
  final file = File(out);
  await file.writeAsString(json);
  stdout.writeln('Wrote ${file.absolute.path}');
  stdout.writeln(
    'Import it in dbscope: File → "Import connection link…" '
    '(passphrase required).',
  );
}
