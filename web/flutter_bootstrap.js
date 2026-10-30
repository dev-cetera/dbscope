{{flutter_js}}
{{flutter_build_config}}

// No service worker: Flutter's is deprecated, and caching is handled by
// per-deploy URLs (scripts/stage_web_build.sh) instead.
_flutter.loader.load();
