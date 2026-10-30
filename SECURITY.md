# Security policy

dbscope holds database credentials and API keys, so security reports are
taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report privately through
[GitHub's private vulnerability reporting](https://github.com/dev-cetera/dbscope/security/advisories/new)
or by email to robert@dev-cetera.com.

Include what you found, how to reproduce it, and the impact you expect. You
should hear back within a week.

## Scope

Of particular interest:

- Credential handling: keychain storage, `.dbscopeconn` link encryption,
  anything that could leak a password or API key (logs, UI, crash output).
- SQL injection via identifiers, values, metadata or AI-generated SQL.
- Bypasses of read-only mode or of the metadata access-control policy.
- `dbscope_pg_proxy` exposing a database to clients it shouldn't.

The macOS build intentionally runs without the App Sandbox (it shells out to
`adb`, `xcrun`, `gcloud` and `cloud-sql-proxy`); that alone is not a
vulnerability.

## Supported versions

Only the latest release receives fixes.
