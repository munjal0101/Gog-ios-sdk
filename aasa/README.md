# AASA — ready to serve

**Team ID `82K69CSWA7`**, read from the portal 2026-08-31. Not a secret: it is published in
every association file on the internet, and it is half of every `appIDs` entry.

Two files, two hosts, **neither may redirect** and both must answer every IP and User-Agent.
Full serving rules, cache reality and runbook: `claude/backend-brief-aasa.md`.

```
https://hub.godofgaming.online/.well-known/apple-app-site-association   <- hub.apple-app-site-association.json
https://link.godofgaming.online/.well-known/apple-app-site-association  <- link.apple-app-site-association.json
```

| File | What it is |
|---|---|
| `hub.apple-app-site-association.json` | **Final.** One unconditional entry, `online.godofgaming.hub` claiming `/auth`. Never empty — see brief §4, divergence 1. |
| `link.apple-app-site-association.json` | **Correct as of 2026-08-31.** The fourteen games whose App IDs exist. |
| `link.apple-app-site-association.EXPECTED-WHEN-COMPLETE.json` | What the generator must emit once Crowd Arena's App ID exists too. Use it as the generator's fixture. |
| `populate-ios-identifiers.sql` | Adds `games.ios_team_id`, re-points the `ios_bundle_id` comment, and fills both columns for all fifteen games. Idempotent. |

## Three things that are easy to get wrong

**Lower-case the UUID.** `components` matching is case-sensitive. Swift's `UUID(uuidString:)`
is not — so a case mismatch fails at OS routing while looking perfectly valid to every piece of
code that inspects the link. The files here are already lower-cased; make sure the hub emits
lower case too.

**Exact path, no wildcard, and never constrain `?` or `#`.** Association decides *which app
receives the URL* and must do that identically whether or not a credential is attached. The
launch-code delimiter is still an open decision; constraining either would bake in an answer
nobody has given.

**Do not gate on `is_published`.** The predicate is `deleted_at IS NULL AND ios_bundle_id IS NOT
NULL AND ios_team_id IS NOT NULL`. Apple's cache is measured in weeks, so this file is a
statement about the future — registering early lets the cache warm before launch day. Brief §4,
divergence 2.

## What is registered

Fifteen App IDs exist on `82K69CSWA7`, each with **Associated Domains** enabled: the hub
(`online.godofgaming.hub`) and fourteen games. Verified against Apple's own confirmation screen
at creation, which lists the enabled capabilities.

**One missing on purpose:** `com.godofgaming.crowdarean` (Crowd Arena). Its Android package
spells it "crowdarean", not "crowdarena", and mirroring Android faithfully carries the typo into
a bundle ID that becomes permanent the moment a build is uploaded. Held for a decision. The
files here already carry that spelling — change both if the answer is to fix it.

## Before deploying

⚠️ The enrolment behind this Team ID is an **Individual** one in a personal name. If the apps
eventually ship under a company account, that is a new enrolment plus an app transfer, and
Apple's transfer docs are explicit that the bundle ID survives while the **Team ID changes** —
breaking exactly this file, with no purge API and a rollout measured in weeks. Confirm the
publishing entity, then deploy. See `claude/apple-account-findings.md` §4.

Building and testing the generator against `82K69CSWA7` is safe today. Serving it is the step
to hold.

## Verifying after deploy

```bash
# Apple's own smoke test — unusual User-Agent must not be refused
curl -A "MyAgent-Bot/*" https://link.godofgaming.online/.well-known/apple-app-site-association

# what Apple's CDN currently holds; any query parameter forces a re-fetch
curl "https://app-site-association.cdn-apple.com/a/v1/link.godofgaming.online?bust=1"
```
