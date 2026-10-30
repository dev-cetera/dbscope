# Writing code

Rules for any code in this folder. The rules in the root `AGENTS.md` apply too.

## Write code a person can read at a glance

Someone should be able to open a file and know what it does without tracing a value through four layers. That beats clever, short and personal taste.

- **Name things.** A mode is an enum with a name, not a boolean passed down four levels.
- **One function, one job.** If it branches into very different paths on a flag, it is two functions.
- **Keep rules out of UI code.** Logic that can be subtly wrong (permissions, dates, money) goes in a named place you can test.
- **Group arguments that always travel together** into one type with a name.
- **Make bad states impossible.** Two optional fields that must never both be set are a bug waiting to happen. Use a type that can only hold one.
- **Prefer boring.** A plain `if` chain beats an abstraction. Three similar lines beat a helper nobody else needs.

If a change makes a file harder to skim, it isn't finished.

## Fail loudly, never guess

When something unexpected happens, make it visible. Don't quietly swap in a default that looks reasonable.

- **No silent fallbacks.** A `?? default`, a `catch` that returns an empty value, or a `default:` branch that hides an unknown case is a bug, unless the default is a product decision written down somewhere.
- **Throw the right error.** A caller's mistake is a clean client error. A bug in our code throws and gets reported.
- **Only catch to log.** Where throwing would hurt the user, keep the safe behaviour and log the error so someone sees it.
- **No catch-all enum values** like `UNKNOWN` or `OTHER` that swallow values nobody mapped.
- **Clean up as you go.** Remove whatever your fix leaves unused in the same change.

## Before you finish

Run the checks listed under "After making changes" in the root `AGENTS.md`. A bug you noticed but didn't fix goes in `BUGS.md`, not in your diff.
