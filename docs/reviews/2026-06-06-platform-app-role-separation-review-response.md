# Review response: platform/app-owner role separation branch

Date: 2026-06-06
Branch: `feat/app-owner-role-separation`
Responding to: `docs/reviews/2026-06-06-platform-app-role-separation-review.md`

Each item below is marked **Addressed**, **Partially addressed**, or **Declined**,
with what changed and why. Verification re-run after changes: `bash -n
scripts/onboard-app.sh`, `uv run ruff check`, `uv run pyright`, and `git diff
--check main...HEAD` all pass.

---

## 1. Blocker — onboarding can create firewall drift unless the new app ID is committed

**Status: Addressed.**

The concern is correct: the script edits `Pulumi.prod.yaml` and applies it
directly from a local checkout, so an uncommitted `trusted_app_ids` change can be
reverted by the next CI `pulumi up` from `main`, recreating issue #10. It also
contradicted the README's "merging to `main` is the only way to apply changes".

Changes:
- `scripts/onboard-app.sh` now **asserts `Pulumi.prod.yaml` is clean** before it
  edits config, so the resulting diff is exactly this run's change and is easy to
  review/commit.
- On a config change the script prints the **exact `git add` / `commit` / `push`**
  to run, with an inline warning that not pushing will let CI drop the app from
  the firewalls.
- `README.md` "Onboarding a new app" now states this is the one sanctioned
  exception to the merge-to-`main` rule and instructs the admin to commit+push the
  `trusted_app_ids` change immediately.
- `README.md` CI section reworded from "the only way" to "the normal way … the one
  exception is admin app onboarding", cross-linked to the onboarding section.

I kept onboarding as a direct-apply script (per the approved design) rather than
splitting it into a PR step, but made the persistence model explicit and
fail-safe, which was the reviewer's primary ask.

## 2. Blocker — the Pulumi config append command is malformed

**Status: Addressed.**

Verified against the local Pulumi CLI (`v3.232.0`): `pulumi config set --help`
documents `--path` with path and value as **separate** arguments
(`'names[0]' a`) and there is no `[+]` append syntax. So
`pulumi config set --path "trusted_app_ids[+]=${APP_ID}"` is treated as a single
path key with no value and would prompt/hang.

Changes (script + spec + plan, since the reviewer flagged the malformed form is
copy-pasteable):
- `scripts/onboard-app.sh` now computes the next index and membership from
  `pulumi config --json` (the `objectValue` array — confirmed empirically against
  the live `prod` config), then calls
  `pulumi config set --path "trusted_app_ids[${NEXT_INDEX}]" "${APP_ID}" --stack prod`
  with path and value as separate args.
- `docs/superpowers/specs/2026-06-06-platform-app-role-separation-design.md:90`
  and `docs/superpowers/plans/2026-06-06-platform-app-role-separation.md:346`
  updated to the corrected approach with a note that Pulumi has no append-path
  syntax.

## 3. High — temporary admin firewall access is not cleaned up on failure

**Status: Addressed.**

Changes to `scripts/onboard-app.sh`:
- Added an `EXIT` trap that runs `remove_admin_ip` (re-fetch firewall, drop only
  our IP, preserving the Pulumi-reconciled app rules). It is armed **after** the
  admin IP is added, so cleanup runs on success, error (`set -e`), and Ctrl-C.
  Cleanup is best-effort (`|| true` / `|| return 0`) so a failure to clean up
  can't mask the original error, but the common failure paths (`psql` missing,
  DB timeout, missing schema/db) now always attempt removal.
- Replaced the fixed `/tmp/onboard_fw*.json` paths with a `mktemp -d` working dir,
  also removed by the trap.

## 4. High — the stated secret-isolation boundary is incomplete for Valkey

**Status: Addressed (as documentation; Valkey is deliberately shared).**

The reviewer is right that the README implied stronger isolation than the outputs
enforce. Per the design's threat model ("accidents + isolation of *privileged
admin* secrets among *trusted* users — not multi-tenant isolation"), the shared
Valkey credential is an accepted tradeoff, not a leak to fix. So I documented it
rather than removing the output (apps actively consume `redis_url`).

Changes to `README.md`:
- The app-owner Roles bullet now says they cannot read **privileged** platform
  secrets "notably the Postgres `doadmin` password", instead of "platform secrets"
  flatly.
- Added an explicit "Note on shared Valkey": no per-app credential exists, so
  `redis_password`/`redis_url` are a deliberately shared secret readable by every
  app-owner via `StackReference`, and per-app cache isolation is a future story.
- Marked both rows in the outputs table "(secret, shared across all apps)".

## 5. Medium — app-owner DigitalOcean role assumptions need verification

**Status: Partially addressed (documented as a required, unverified check).**

I can't fully resolve this in this branch: it requires issuing a real
`app-deployer`-scoped DO token and running app-owner self-service end-to-end
against DigitalOcean, which is a live admin checkpoint (no token available here).
Claiming it works without that test would be false confidence.

What I did: added an explicit **"Unverified — verify before relying on this
boundary"** callout to the README "Granting a new app-owner → DigitalOcean"
section. It names the specific risk (whether creating a per-app database/user/pool
in an existing shared cluster and reading the generated connection attributes
classify as `database:create`/`read` vs `database:update`), states the failure
mode, and makes "run first onboarding with a real scoped token and record the
sufficient scopes" a required step.

## 6. Medium — `onboard-app.sh` trusts app-name-derived SQL identifiers too much

**Status: Addressed (fail closed on unexpected names).**

`scripts/onboard-app.sh` now validates `APP_NAME` against
`^[a-z][a-z0-9-]*[a-z0-9]$` immediately and exits with a clear error before
deriving `DB_NAME`/`DB_USER` or building the `GRANT`. Anything outside the
template's naming convention fails closed rather than constructing an unexpected
identifier, which addresses the SQL-injection-via-name and wrong-grant concerns.

I kept the derive-from-name approach (it matches the template's deterministic
`<app>_user` convention) rather than fetching the live DB/user name, but gated it
behind validation with a comment to keep the regex in sync with
platform-app-template.

## 7. Medium — historical docs are marked stale but still contain executable old examples

**Status: Addressed.**

Strengthened the dated notes at the top of
`docs/plans/2026-04-13_platform-infra-brief.md` and
`docs/plans/2026-04-13_platform-infra-phase-1-plan.md`. They now say
"**historical; do not copy the code/output examples below**", call out specifically
that `postgres_admin_password` is no longer exported and that apps must use the
**public** hosts, and point to the current README/spec for the real output
contract. I preserved the historical narrative rather than rewriting the old
snippets.

## 8. Low — app/cluster discovery has scaling and uniqueness assumptions

**Status: Addressed (the uniqueness half; paging deferred).**

`scripts/onboard-app.sh` now:
- **Fails closed if more than one** App Platform app matches the requested name
  (was: silently picked the first), and
- Accepts an explicit app UUID override as a second positional arg (or `APP_ID`
  env), bypassing name resolution entirely.

I left the `per_page=200` single-page fetch rather than adding full pagination:
it's sufficient for the current account, the multi-match guard + explicit-UUID
escape hatch cover the correctness risk the reviewer raised, and full paging is
YAGNI until the account approaches that size. The override gives a clean path if
it ever does.

---

## Net file changes

- `scripts/onboard-app.sh` — items 1, 2, 3, 6, 8 (clean-tree assertion, index
  computation, EXIT-trap cleanup + `mktemp`, name validation, multi-match guard +
  UUID override, commit/push reminder).
- `README.md` — items 1, 4, 5 (onboarding commit step + CI exception, Valkey
  shared-secret clarification, DO role verification caveat).
- `docs/superpowers/specs/2026-06-06-platform-app-role-separation-design.md` — item 2.
- `docs/superpowers/plans/2026-06-06-platform-app-role-separation.md` — item 2.
- `docs/plans/2026-04-13_platform-infra-brief.md`,
  `docs/plans/2026-04-13_platform-infra-phase-1-plan.md` — item 7.

## Verification

- `bash -n scripts/onboard-app.sh` — pass
- `uv run ruff check` — pass
- `uv run pyright` — 0 errors, 0 warnings
- `git diff --check main...HEAD` — pass
- `pulumi config --json` `objectValue` shape confirmed against live `prod` config
  (next-index/membership logic).
- Not run (requires a live admin `DIGITALOCEAN_TOKEN` checkpoint): `pulumi
  preview`, executing `onboard-app.sh` against DigitalOcean, and the item-5
  `app-deployer` scope validation.
