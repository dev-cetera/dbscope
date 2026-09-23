// Dev entrypoint. Delegates to the canonical `main()` in `main.dart` so
// `fvm flutter run -t lib/main_dev.dart` works the same as the default.
// If you later split per-flavor config (e.g. dev points at staging,
// prod at production), put the divergence here.

import 'main.dart' as app;

Future<void> main(List<String> args) => app.main(args);
