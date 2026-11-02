# SEO and AEO audit

What keeps the landing page (`site/`, https://dev-cetera.github.io/dbscope/) from being found by search engines and quoted by AI answer engines. Run with `/find-seo-aeo-improvements`. Mechanical checks run on every Pages deploy via `scripts/check_site_seo.sh`.

Last full run: 2026-11-02 (first run; findings 1–8 below were fixed in the same run and deleted).

Fixed on 2026-11-02, for the record of what the check now guards: no canonical link; no sitemap; no `llms.txt`; no JSON-LD (now `SoftwareApplication` + `FAQPage`); no FAQ answering what / free / databases / platforms / large tables / privacy; description over 200 characters; title without "Postgres" or "SQLite"; social tags missing `og:site_name`, image size and alt, and Twitter title/description; no `<main>` landmark.

## Open

### 1. Hero screenshot is missing, and its hidden `<img>` 404s on every visit
Page: / · Confidence: confirmed · Found: 2026-11-02 · Status: open (needs a human)
Evidence: `site/index.html` `<figure class="shot" id="shot" hidden>` loads `assets/screenshot.png`, which does not exist.
Fix: capture the screenshot (see `MANUAL_TODO.md` "Add a screenshot or demo video to the landing page and README"); once it exists, also use it as the `screenshot` property of the `SoftwareApplication` JSON-LD.

### 2. Sitemap is not discoverable without Search Console
Page: / · Confidence: confirmed · Found: 2026-11-02 · Status: open (needs a human)
Evidence: GitHub Pages serves the project under `/dbscope/`; `robots.txt` is only read at `dev-cetera.github.io/robots.txt`, which this repo can't write.
Fix: submit `sitemap.xml` in Search Console (`MANUAL_TODO.md` "Submit the landing page sitemap to Google Search Console"). A custom domain would also allow a root `robots.txt`.

### 3. The web app at dbscope-prod.web.app has a bare `<title>dbscope</title>` and no canonical or social tags
Page: https://dbscope-prod.web.app · Confidence: confirmed · Found: 2026-11-02 · Status: deferred
Evidence: `web/index.html` head.
Fix: decide whether the web app should be indexed at all. If not, add `<meta name="robots" content="noindex">` so it doesn't compete with the landing page; if so, give it a descriptive title and a canonical pointing at itself.

Verified 2026-11-02: all entries above checked against the current source.
