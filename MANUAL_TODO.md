# Manual TODO

> [!IMPORTANT]
> **This file is for people. `TODO.md` is for coding agents.**
>
> Everything here needs something a coding agent in a terminal can't do: a login, a card, a key, a decision only the owner can make, a real device, legal or tax advice. It lives apart from `TODO.md` so an agent working through that list never gets stuck on an item it can't finish.

Don't read this file whole. Search it first:

```sh
rg -n --max-count 5 '<topic>' MANUAL_TODO.md
```

## Where things go

| What closing it needs | Where it goes |
|---|---|
| Writing or changing code | `TODO.md` |
| A decision, then code | `TODO.md`, with `Blocker: needs a decision on X` |
| Clicks in a dashboard you're signed in to | here, under *A browser agent can do these* |
| A card, a new account, a key, artwork, legal advice, a real device, another person | here, under *Only a person can do these* |

If an item has both halves (a human step, then code), file one half in each file and make each half name the other.

## Entry format

```text
#### <what needs doing>

- **Why.** What it unblocks.
- **Steps.** The exact click path or command, as far as it is known.
- **Related.** The TODO.md or BUGS.md entry waiting on it, if any.
- **Added.** YYYY-MM-DD
```

## A browser agent can do these

Only clicks in a dashboard you're already signed in to, with you watching (Claude in Chrome or a similar tool). Nothing that needs a password typed, a card or a decision.

### P0

### P1

### P2

## Only a person can do these

### P0

#### Turn on keyless Firebase deploys from GitHub Actions

- **Why.** `.github/workflows/web.yml` builds the web app but skips the deploy until the GCP_WIF_PROVIDER / GCP_DEPLOY_SA repo variables exist, so dbscope-prod.web.app stays on the last manual deploy.
- **Steps.** `gcloud auth login` (the stored session expired), then `bash scripts/setup_firebase_deploy.sh` to see the plan, then `bash scripts/setup_firebase_deploy.sh --yes`, then `gh workflow run web.yml -R dev-cetera/dbscope`.
- **Related.** none
- **Added.** 2026-10-30

#### Sign and notarize the macOS release

- **Why.** Unsigned builds are rejected by Gatekeeper until the user runs `xattr -dr com.apple.quarantine` or clicks Open Anyway; most LinkedIn visitors will give up there.
- **Steps.** Apple Developer Program → create a "Developer ID Application" certificate → export as .p12 → add repo secrets MACOS_CERT_P12_BASE64, MACOS_CERT_PASSWORD, APPLE_ID, APPLE_APP_PASSWORD (appleid.apple.com app-specific password), APPLE_TEAM_ID → delete the draft v0.1.0 release → `git tag v0.1.0 && git push origin v0.1.0`. Alternatively publish the unsigned draft as-is.
- **Related.** none
- **Added.** 2026-10-30

### P1

#### Add a screenshot or demo video to the landing page and README

- **Why.** The landing page hero shows nothing until `site/assets/screenshot.png` exists; a product page without a picture converts poorly.
- **Steps.** Capture the app (table + navigator + AI panel), save as `site/assets/screenshot.png`, add it near the top of `README.md`, push.
- **Related.** none
- **Added.** 2026-10-30

#### Restrict the Firebase web API key to the hosting domains

- **Why.** gitleaks flags the key in `lib/firebase_options.dart`. It is public by design, but an unrestricted key can be used from any origin.
- **Steps.** GCP Console → dbscope-prod → APIs & Services → Credentials → the browser key → Application restrictions: HTTP referrers `dbscope-prod.web.app/*`, `dbscope-prod.firebaseapp.com/*`, `localhost/*`.
- **Related.** none
- **Added.** 2026-10-30
