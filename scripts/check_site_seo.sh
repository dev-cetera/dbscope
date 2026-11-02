#!/usr/bin/env bash
# Checks the landing page's SEO plumbing: JSON-LD parses, FAQ JSON-LD matches the visible FAQ, canonical = og:url = sitemap <loc>, llms.txt exists.
# Usage: bash scripts/check_site_seo.sh [site-dir]   (default: site). Used by .github/workflows/pages.yml.
set -euo pipefail

SITE="${1:-site}"
[ -f "$SITE/index.html" ] || { echo "usage: check_site_seo.sh [site-dir] (no $SITE/index.html)" >&2; exit 2; }

python3 -I - "$SITE" <<'PY'
import html, json, re, sys, pathlib

site = pathlib.Path(sys.argv[1])
page = (site / "index.html").read_text()
problems = []

def meta(attr, name):
    m = re.search(rf'<meta {attr}="{re.escape(name)}" content="([^"]*)"', page)
    return m.group(1) if m else None

for tag in ("description",):
    if not meta("name", tag):
        problems.append(f"missing <meta name={tag}>")
for tag in ("og:title", "og:description", "og:url", "og:image"):
    if not meta("property", tag):
        problems.append(f"missing <meta property={tag}>")
if not re.search(r"<title>[^<]+</title>", page):
    problems.append("missing <title>")

canon = re.search(r'<link rel="canonical" href="([^"]+)"', page)
canon = canon.group(1) if canon else None
if not canon:
    problems.append("missing <link rel=canonical>")
elif meta("property", "og:url") != canon:
    problems.append(f"og:url {meta('property', 'og:url')} != canonical {canon}")

sitemap = site / "sitemap.xml"
if not sitemap.exists():
    problems.append("missing sitemap.xml")
elif canon and f"<loc>{canon}</loc>" not in sitemap.read_text():
    problems.append(f"sitemap.xml has no <loc>{canon}</loc>")

if not (site / "llms.txt").exists():
    problems.append("missing llms.txt")

blocks = {}
for attrs, body in re.findall(r'<script type="application/ld\+json"([^>]*)>(.*?)</script>', page, re.S):
    try:
        data = json.loads(body)
    except json.JSONDecodeError as e:
        problems.append(f"JSON-LD does not parse: {e}")
        continue
    blocks[data.get("@type")] = data
if "SoftwareApplication" not in blocks:
    problems.append("no SoftwareApplication JSON-LD")

visible = [(html.unescape(q), html.unescape(a))
           for q, a in re.findall(r"<dt>(.*?)</dt><dd>(.*?)</dd>", page)]
faq = blocks.get("FAQPage")
if visible and not faq:
    problems.append("visible FAQ has no FAQPage JSON-LD")
elif faq:
    ld = [(e["name"], e["acceptedAnswer"]["text"]) for e in faq["mainEntity"]]
    if ld != visible:
        problems.append("FAQPage JSON-LD does not match the visible FAQ (#faq dt/dd)")

for p in problems[:40]:
    print(p)
print("site SEO: ok" if not problems else f"site SEO: {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
PY
