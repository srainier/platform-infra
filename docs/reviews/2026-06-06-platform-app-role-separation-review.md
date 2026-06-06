# Review: platform/app-owner role separation branch

Scope reviewed: current branch `feat/app-owner-role-separation` against
`main` (`ed94d8014fdabe2b770799a2351fc0099dcfb14d`), with context from
`/Users/srainier/dev/side_projects/hello-platform-DEPLOY-HANDOFF.md` and
`docs/superpowers/specs/2026-06-06-platform-app-role-separation-design.md`.

Overall direction is right: the branch moves the shared database firewalls from
out-of-band drift into Pulumi config, removes the exported Postgres admin
password, adds public App Platform connection outputs, and makes the privileged
per-app steps explicit in an admin-owned onboarding script. The main remaining
risks are around how the new declarative state is persisted and how robust the
admin script is under failure.

## Ordered feedback

1. **Blocker: onboarding can still create firewall drift unless the new app ID is committed.**

   `scripts/onboard-app.sh` mutates `Pulumi.prod.yaml` via `pulumi config set`
   and immediately runs `pulumi up` (`scripts/onboard-app.sh:47-54`), but the
   README does not tell the admin to commit that config change. Since
   `trusted_app_ids` is stored in the repo config file (`Pulumi.prod.yaml:7-11`),
   an admin can successfully onboard an app locally, leave the working tree
   dirty, and later have CI or another admin run `pulumi up` from `main` without
   that app ID. That would remove the app rule and recreate issue #10.

   This also conflicts with the README's current CI statement that "Merging to
   `main` is the only way to apply changes to production" (`README.md:198`),
   because the onboarding script applies production directly from a local
   checkout.

   Recommendation: make the persistence model explicit before merging. Either:
   require the admin to run the script from `main`, commit/push the
   `trusted_app_ids` config change immediately after a successful run, and update
   the README accordingly; or split onboarding into a PR/config step plus a
   post-merge grant step. The script should probably assert a clean working tree
   and print the exact files that must be committed.

2. **Blocker: the Pulumi config append command is malformed.**

   The script uses:

   ```bash
   pulumi config set --path "trusted_app_ids[+]=${APP_ID}" --stack prod
   ```

   at `scripts/onboard-app.sh:51`. `pulumi config set --path` still expects the
   path and value as separate arguments, e.g. `pulumi config set --path
   'trusted_app_ids[0]' value`. With the current command, the UUID is part of the
   key/path and no value argument is supplied, so the command can prompt or fail
   instead of appending the app ID. The same malformed example appears in the
   implementation plan/spec text (`docs/superpowers/specs/...:91` and
   `docs/superpowers/plans/...:350`), so this mistake is easy to propagate.

   Recommendation: fix the script and docs to use a real append strategy. If
   Pulumi CLI does not support `trusted_app_ids[+]` as a path, compute the next
   index from the current list and call `pulumi config set --path
   "trusted_app_ids[${next_index}]" "${APP_ID}" --stack prod`.

3. **High: temporary admin firewall access is not cleaned up on failure.**

   The script adds the admin's public IP to the Postgres firewall
   (`scripts/onboard-app.sh:62-75`) and only removes it after `psql` succeeds
   (`scripts/onboard-app.sh:78-98`). With `set -e`, any failure between those
   points leaves the admin IP trusted until someone notices or the next Pulumi
   reconciliation removes it. The most likely failures are `psql` not installed,
   a transient DB timeout, the schema/database not existing yet, or the DO API
   taking longer than five seconds to apply the firewall rule.

   Recommendation: add an `EXIT` trap after the temporary rule is added so cleanup
   runs on success, error, and Ctrl-C. Use `mktemp` instead of fixed
   `/tmp/onboard_fw*.json` paths while touching this code.

4. **High: the stated secret-isolation boundary is incomplete for Valkey.**

   The README says app-owners cannot read platform secrets (`README.md:14-18`)
   and justifies removing `postgres_admin_password` because app-owners have Read
   on the platform stack (`README.md:167`). But `infra/outputs.py` still exports
   `redis_password` and `redis_url` as stack secrets (`infra/outputs.py:33-35`),
   and the README tells app repos to consume `redis_url` (`README.md:138,
   README.md:160-162`). If app-owners can read stack outputs through
   `StackReference`, they can receive the shared Valkey credential. That may be
   an acceptable trusted-users tradeoff, but it contradicts the current wording.

   Recommendation: either document Valkey as a deliberately shared credential
   with no per-app isolation, remove it from app-owner-readable platform outputs,
   or introduce a per-app cache/credential story. Do not leave the README implying
   stronger secret isolation than the outputs actually enforce.

5. **Medium: app-owner DigitalOcean role assumptions need verification.**

   The design and README define `app-deployer` as App Platform create/read/update/delete
   plus database create/read, with no database update (`README.md:109-120`). That
   is directionally aligned with "no firewall or cluster mutation", but the branch
   does not prove this role can do everything the app template's Pulumi stack
   needs: create a database, user, and connection pool inside an existing shared
   cluster; read the generated per-app user/pool connection attributes; and update
   App Platform env vars/specs over time. If any of those DO API calls are
   classified as database update rather than create/read, app-owner self-service
   fails before admin onboarding.

   Recommendation: make this a required verification item, ideally with a real
   token assigned to the custom role. Record the exact DO permissions that were
   sufficient, or loosen the docs if DO's model cannot express the intended
   boundary exactly.

6. **Medium: `onboard-app.sh` trusts app-name-derived SQL identifiers too much.**

   The script derives `DB_NAME` and `DB_USER` by replacing hyphens with
   underscores (`scripts/onboard-app.sh:21-22`) and then injects the role name
   directly into SQL (`scripts/onboard-app.sh:78-81`). This works for
   `hello-platform -> hello_platform_user`, but it is coupled to the template's
   current naming convention and has no validation. A future app name with an
   unexpected character, a template naming change, or a manually chosen DB/user
   name will grant the wrong role or fail.

   Recommendation: validate app names with the same regex the template supports,
   or fetch/accept the actual DB name and user name. If continuing with derived
   identifiers, quote them safely or fail closed on anything outside the expected
   pattern.

7. **Medium: historical docs are marked stale, but still contain executable old examples.**

   The dated notes added to `docs/plans/*` are a reasonable way to avoid editing
   history, but those files still include old examples that consume
   `postgres_admin_password`, private `postgres_host`, and private `redis_url`
   (`docs/plans/2026-04-13_platform-infra-brief.md:129-138,
   docs/plans/2026-04-13_platform-infra-brief.md:399-404,
   docs/plans/2026-04-13_platform-infra-phase-1-plan.md:188-189`). The top note
   helps, but a reader landing on the old snippets from search could still copy
   the wrong pattern.

   Recommendation: either make the top warning more explicit ("do not copy the
   output examples below") or replace the old executable snippets with a pointer
   to the current README/spec while preserving the historical narrative.

8. **Low: the app/cluster discovery code is intentionally small but has scaling and uniqueness assumptions.**

   `onboard-app.sh` searches only the first 200 apps/databases and chooses the
   first app whose spec name matches (`scripts/onboard-app.sh:27-45`). That is
   fine for today's account, but the behavior should be named if the platform is
   expected to grow or if app names can be reused across environments.

   Recommendation: page through DO API results or allow an explicit app UUID
   override. At minimum, fail if multiple apps match the requested name.

## Verification performed

- `uv run pyright` passed.
- `uv run ruff check` passed.
- `bash -n scripts/onboard-app.sh` passed.
- `git diff --check main...HEAD` passed.
- Did not run `pulumi preview` or `scripts/onboard-app.sh` against DigitalOcean;
  those still require an admin `DIGITALOCEAN_TOKEN` checkpoint.
