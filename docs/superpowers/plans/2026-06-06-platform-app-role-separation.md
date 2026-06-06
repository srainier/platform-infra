# Platform / App-owner Role Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make per-app deploys to the shared platform safe and self-serve for trusted non-admin app-owners, with a declarative trusted-source firewall, an idempotent admin onboarding script, secret-isolated outputs, and fully consistent documentation across both repos.

**Architecture:** `platform-infra` (admin-owned) gains a declarative `trusted_app_ids` config rendered into the Postgres/Valkey firewalls, drops the admin-password output, exposes public connection strings, and ships `scripts/onboard-app.sh` for the two privileged per-app steps (trusted-source + schema grant). Docs in both repos are rewritten around two personas (infra-admin, app-owner).

**Tech Stack:** Pulumi (Python, `pulumi_digitalocean`), Bash + `curl`/`python3`/`psql`, DigitalOcean API, Markdown.

**Spec:** `docs/superpowers/specs/2026-06-06-platform-app-role-separation-design.md`

**Repos:** `platform-infra` (Tasks 1–8), `platform-app-template` (Tasks 9–11). Each repo's work lands on its own branch + PR.

**Known IDs (for seeding):**
- `hello-platform` app: `0704f1e8-d65c-44ed-b657-13462ade9dd6`
- prior app (already trusted): `fa236109-e18c-4bbe-a935-2862ea55f546`

---

## Execution progress

> Updated after each task for resumability. Branch: `feat/app-owner-role-separation` (platform-infra).

- [x] **Task 1 + 2** — trusted_app_ids → postgres + valkey firewalls — commit `9f872d9` (pyright + ruff clean). *Done as one commit; signatures use a required param (no mutable default).*
- [~] Task 3 — seed trusted_app_ids done (commit `538ed80`); `pulumi preview` PENDING user checkpoint (needs DO token)
- [x] Task 4 — outputs hygiene — commit `08dac84` (admin_password dropped, public host/uri outputs added; ruff + pyright clean)
- [x] Task 5 — onboard-app.sh script — commit `adc4dcc` (bash -n clean, idempotent, re-fetch-before-IP-removal). NOT executed.
- [ ] Task 6 — verify onboarding idempotency (CHECKPOINT: needs DO token)
- [x] Task 7 — platform-infra README role separation — commit `c00289c`
- [x] Task 8 — platform-infra docs consistency audit — commit `1b1b4c3`
- [ ] Task 9 — open platform-infra PR (push done by controller; MERGE is your checkpoint)
- [ ] Task 10 — template generated README runbook (platform-app-template)
- [ ] Task 11 — template docs consistency + PR (platform-app-template)

---

## Phase 1 — platform-infra: declarative trusted-app firewall (#10)

### Task 1: Render `trusted_app_ids` into the Postgres firewall

**Files:**
- Modify: `infra/postgres.py`
- Modify: `__main__.py`

- [ ] **Step 1: Add a `trusted_app_ids` parameter to `create_postgres` and build firewall rules from it**

In `infra/postgres.py`, change the signature and the firewall block:

```python
def create_postgres(
    region: str,
    version: str,
    size: str,
    vpc_id: pulumi.Input[str],
    trusted_app_ids: list[str],
) -> tuple[do.DatabaseCluster, do.DatabaseConnectionPool]:
    cluster = do.DatabaseCluster(
        "platform-postgres",
        name="platform-postgres",
        engine="pg",
        version=version,
        size=size,
        region=region,
        node_count=1,
        private_network_uuid=vpc_id,
    )

    # Trusted sources are declarative and exclusive: list every source that may
    # reach the cluster. App Platform apps are NOT VPC members, so each app must
    # be named here by UUID (managed via the trusted_app_ids config). Omitting an
    # app here locks it out on the next `pulumi up`.
    firewall_rules = [
        do.DatabaseFirewallRuleArgs(type="ip_addr", value="10.10.0.0/16"),
    ]
    firewall_rules += [
        do.DatabaseFirewallRuleArgs(type="app", value=app_id)
        for app_id in trusted_app_ids
    ]
    do.DatabaseFirewall(
        "platform-postgres-firewall",
        cluster_id=cluster.id,
        rules=firewall_rules,
    )

    pool = do.DatabaseConnectionPool(
        "platform-postgres-pool",
        cluster_id=cluster.id,
        name="platform-pool",
        mode="transaction",
        size=10,
        db_name="defaultdb",
        user="doadmin",
    )

    return cluster, pool
```

- [ ] **Step 2: Read the config and pass it through in `__main__.py`**

In `__main__.py`, after the existing config reads, add:

```python
trusted_app_ids: list[str] = config.get_object("trusted_app_ids") or []
```

and update the call:

```python
pg_cluster, pg_pool = postgres.create_postgres(
    region, pg_version, pg_size, vpc.id, trusted_app_ids
)
```

- [ ] **Step 3: Type-check**

Run: `uv run pyright`
Expected: `0 errors`

- [ ] **Step 4: Commit**

```bash
git add infra/postgres.py __main__.py
git commit -m "feat(infra): render trusted_app_ids into postgres firewall"
```

### Task 2: Render `trusted_app_ids` into the Valkey firewall

**Files:**
- Modify: `infra/valkey.py`
- Modify: `__main__.py`

- [ ] **Step 1: Add the parameter and rules to `create_valkey`**

In `infra/valkey.py`:

```python
def create_valkey(
    region: str,
    size: str,
    vpc_id: pulumi.Input[str],
    trusted_app_ids: list[str],
) -> do.DatabaseCluster:
    cluster = do.DatabaseCluster(
        "platform-valkey",
        name="platform-valkey",
        engine="valkey",
        version="8",
        size=size,
        region=region,
        node_count=1,
        private_network_uuid=vpc_id,
    )

    firewall_rules = [
        do.DatabaseFirewallRuleArgs(type="ip_addr", value="10.10.0.0/16"),
    ]
    firewall_rules += [
        do.DatabaseFirewallRuleArgs(type="app", value=app_id)
        for app_id in trusted_app_ids
    ]
    do.DatabaseFirewall(
        "platform-valkey-firewall",
        cluster_id=cluster.id,
        rules=firewall_rules,
    )

    return cluster
```

- [ ] **Step 2: Pass the config through in `__main__.py`**

```python
valkey_cluster = valkey.create_valkey(region, valkey_size, vpc.id, trusted_app_ids)
```

- [ ] **Step 3: Type-check**

Run: `uv run pyright`
Expected: `0 errors`

- [ ] **Step 4: Commit**

```bash
git add infra/valkey.py __main__.py
git commit -m "feat(infra): render trusted_app_ids into valkey firewall"
```

### Task 3: Seed `trusted_app_ids` and verify the preview

**Files:**
- Modify: `Pulumi.prod.yaml`

- [ ] **Step 1: Seed the currently-trusted apps**

Run (from repo root, requires `DIGITALOCEAN_TOKEN` + pulumi login):

```bash
pulumi config set --path 'trusted_app_ids[0]=fa236109-e18c-4bbe-a935-2862ea55f546' --stack prod
pulumi config set --path 'trusted_app_ids[1]=0704f1e8-d65c-44ed-b657-13462ade9dd6' --stack prod
```

- [ ] **Step 2: Confirm `Pulumi.prod.yaml` now lists them**

Run: `grep -A3 trusted_app_ids Pulumi.prod.yaml`
Expected: a `trusted_app_ids` block containing both UUIDs.

- [ ] **Step 3: Preview — firewalls should show VPC CIDR + both apps, no destructive change**

Run: `DIGITALOCEAN_TOKEN=<admin> pulumi preview --diff --stack prod`
Expected: `platform-postgres-firewall` and `platform-valkey-firewall` updated to include `type=app` rules for both UUIDs; no cluster replacement.

- [ ] **Step 4: Commit**

```bash
git add Pulumi.prod.yaml
git commit -m "chore(infra): seed trusted_app_ids with existing apps"
```

---

## Phase 2 — platform-infra: outputs hygiene (#11, #12, secret isolation)

### Task 4: Drop admin-password output, expose public connection strings

**Files:**
- Modify: `infra/outputs.py`

- [ ] **Step 1: Update exports**

In `infra/outputs.py`, replace the Postgres + Valkey export blocks with:

```python
    # Postgres
    pulumi.export("postgres_cluster_id", postgres_cluster.id)
    # Private host: only reachable from inside the VPC (Droplets, etc.).
    pulumi.export("postgres_host", postgres_cluster.private_host)
    # Public host: what App Platform apps (not VPC members) must use, gated by
    # trusted sources. Prefer this from app repos.
    pulumi.export("postgres_host_public", postgres_cluster.host)
    pulumi.export("postgres_port", postgres_cluster.port)
    pulumi.export("postgres_admin_user", postgres_cluster.user)
    pulumi.export("postgres_connection_pool_host", postgres_pool.private_host)
    pulumi.export("postgres_connection_pool_host_public", postgres_pool.host)
    # NOTE: postgres_admin_password is deliberately NOT exported. App-owners have
    # Read on this stack for StackReference; no secret may be exported. The admin
    # onboarding script reads doadmin creds directly from the DO API.

    # Valkey — exported as redis_* so app repos need no changes
    pulumi.export("redis_host", valkey_cluster.private_host)
    pulumi.export("redis_host_public", valkey_cluster.host)
    pulumi.export("redis_port", valkey_cluster.port)
    pulumi.export("redis_password", pulumi.Output.secret(valkey_cluster.password))
    # Public URI: App Platform cannot reach the private Valkey host.
    pulumi.export("redis_url", pulumi.Output.secret(valkey_cluster.uri))
    pulumi.export("redis_url_private", pulumi.Output.secret(valkey_cluster.private_uri))
```

> Rationale: `redis_url` stays the canonical key (app repos already consume it) but now resolves to the **public** URI. Private variants remain available for VPC-internal consumers. `postgres_admin_password` removed entirely.

- [ ] **Step 2: Type-check**

Run: `uv run pyright`
Expected: `0 errors`

- [ ] **Step 3: Preview — confirm no admin password output, redis_url is public**

Run: `DIGITALOCEAN_TOKEN=<admin> pulumi preview --stack prod`
Expected: clean preview; `postgres_admin_password` removed from outputs, new `*_public` outputs added.

> If `pulumi preview` warns that an app currently consumes `postgres_admin_password`, stop and reconcile that consumer first (there should be none after the template fix).

- [ ] **Step 4: Commit**

```bash
git add infra/outputs.py
git commit -m "feat(infra): drop admin-password output, export public connection strings"
```

---

## Phase 3 — platform-infra: onboarding script (#13, operationalize #10)

### Task 5: Create `scripts/onboard-app.sh`

**Files:**
- Create: `scripts/onboard-app.sh`

- [ ] **Step 1: Write the script**

Create `scripts/onboard-app.sh` with exactly:

```bash
#!/usr/bin/env bash
# Onboard a per-app deployment to the shared platform clusters.
#
# Admin-run and idempotent. Run AFTER the app-owner's first `pulumi up`
# (the App Platform app and the <app>_user DB user must already exist).
#
# Usage:
#   DIGITALOCEAN_TOKEN=<admin write token> ./scripts/onboard-app.sh <app-name>
#
# What it does:
#   1. Resolve the App Platform app UUID from its name.
#   2. Add the UUID to platform-infra's trusted_app_ids and `pulumi up`
#      (declarative trusted source on the Postgres + Valkey firewalls).
#   3. Grant the app's DB user CREATE on schema public (PG15+ requirement),
#      connecting as doadmin over the public host with a temporary IP allowlist.
set -euo pipefail

APP_NAME="${1:?usage: onboard-app.sh <app-name>}"
: "${DIGITALOCEAN_TOKEN:?set DIGITALOCEAN_TOKEN (admin, write scope)}"

DB_NAME="${APP_NAME//-/_}"
DB_USER="${DB_NAME}_user"
API="https://api.digitalocean.com/v2"
AUTH=(-H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}")
cd "$(dirname "$0")/.."   # platform-infra repo root

echo "==> Resolving app UUID for '${APP_NAME}'…"
APP_ID=$(curl -sf "${API}/apps?per_page=200" "${AUTH[@]}" | python3 -c "
import json, sys
apps = json.load(sys.stdin).get('apps', []) or []
m = [a for a in apps if a.get('spec', {}).get('name') == '${APP_NAME}']
print(m[0]['id'] if m else '')")
if [[ -z "${APP_ID}" ]]; then
  echo "ERROR: no App Platform app named '${APP_NAME}'. Has the app-owner run 'pulumi up' yet?" >&2
  exit 1
fi
echo "    app id: ${APP_ID}"

echo "==> Resolving platform-postgres cluster id…"
PG_ID=$(curl -sf "${API}/databases?per_page=200" "${AUTH[@]}" | python3 -c "
import json, sys
dbs = json.load(sys.stdin).get('databases', []) or []
m = [d for d in dbs if d.get('name') == 'platform-postgres']
print(m[0]['id'] if m else '')")
[[ -n "${PG_ID}" ]] || { echo "ERROR: platform-postgres cluster not found" >&2; exit 1; }

echo "==> Adding ${APP_ID} to trusted_app_ids (idempotent)…"
if pulumi config get --path trusted_app_ids --stack prod 2>/dev/null | grep -q "${APP_ID}"; then
  echo "    already present; skipping config change"
else
  pulumi config set --path "trusted_app_ids[+]=${APP_ID}" --stack prod
fi
echo "==> pulumi up (reconciling firewalls)…"
pulumi up --yes --stack prod

echo "==> Granting schema privileges to ${DB_USER}…"
read -r H P U PW < <(curl -sf "${API}/databases/${PG_ID}" "${AUTH[@]}" | python3 -c "
import json, sys
c = json.load(sys.stdin)['database']['connection']
print(c['host'], c['port'], c['user'], c['password'])")

MYIP=$(curl -sf https://ifconfig.me)
echo "    temporarily trusting admin IP ${MYIP}…"
curl -sf "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" -o /tmp/onboard_fw.json
python3 -c "
import json
fw = json.load(open('/tmp/onboard_fw.json'))
rules = [{'type': r['type'], 'value': r['value']} for r in fw.get('rules', [])]
ip = '${MYIP}'
if not any(r['type'] == 'ip_addr' and r['value'] == ip for r in rules):
    rules.append({'type': 'ip_addr', 'value': ip})
json.dump({'rules': rules}, open('/tmp/onboard_fw_put.json', 'w'))
"
curl -sf -X PUT "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" \
  -H "Content-Type: application/json" --data @/tmp/onboard_fw_put.json
sleep 5

PGPASSWORD="${PW}" psql \
  "host=${H} port=${P} dbname=${DB_NAME} user=${U} sslmode=require connect_timeout=20" \
  -v ON_ERROR_STOP=1 \
  -c "GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};"

echo "    grant applied; removing admin IP (preserving pulumi-managed rules)…"
# Re-fetch so we keep the app rules pulumi just reconciled, and drop only our IP.
curl -sf "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" -o /tmp/onboard_fw2.json
python3 -c "
import json
fw = json.load(open('/tmp/onboard_fw2.json'))
rules = [
    {'type': r['type'], 'value': r['value']}
    for r in fw.get('rules', [])
    if not (r['type'] == 'ip_addr' and r['value'] == '${MYIP}')
]
json.dump({'rules': rules}, open('/tmp/onboard_fw_clean.json', 'w'))
"
curl -sf -X PUT "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" \
  -H "Content-Type: application/json" --data @/tmp/onboard_fw_clean.json
rm -f /tmp/onboard_fw*.json

echo "==> Done. '${APP_NAME}' is a trusted source and ${DB_USER} can create tables."
echo "    Trigger a redeploy if the first deploy failed before onboarding."
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/onboard-app.sh`

- [ ] **Step 3: Lint the script**

Run: `bash -n scripts/onboard-app.sh`
Expected: no output (syntax OK). If `shellcheck` is installed: `shellcheck scripts/onboard-app.sh` (advisory).

- [ ] **Step 4: Commit**

```bash
git add scripts/onboard-app.sh
git commit -m "feat(infra): add idempotent per-app onboarding script"
```

### Task 6: Verify onboarding idempotency against hello-platform

- [ ] **Step 1: Run it against the already-onboarded app**

Run: `DIGITALOCEAN_TOKEN=<admin> ./scripts/onboard-app.sh hello-platform`
Expected: resolves the app id; "already present; skipping config change"; `pulumi up` reports no firewall change; grant re-applies without error; admin IP added then removed; exits 0.

- [ ] **Step 2: Confirm no firewall drift remains**

Run: `curl -sf "https://api.digitalocean.com/v2/databases/<PG_ID>/firewall" -H "Authorization: Bearer <admin>" | python3 -m json.tool`
Expected: rules = VPC CIDR + the two trusted apps; no leftover admin IP.

(No commit — verification only.)

---

## Phase 4 — platform-infra: documentation (#4) + consistency audit

### Task 7: Rewrite `platform-infra/README.md` for the two-persona model

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the intro + add a "Roles" section**

Replace the opening paragraph's "rarely touched … never create their own databases or VPCs" framing with the persona model. Add, after the intro:

```markdown
## Roles

This platform is operated by two roles. Today one person may hold both, but the
boundaries are real and enforced by Pulumi + DigitalOcean RBAC.

- **Infra-admin** — owns this repo (`platform-infra`). Pulumi org admin and
  DigitalOcean team Owner. Runs the one-time onboarding for each new app.
- **App-owner** — owns an app repo scaffolded from `platform-app-template`.
  Can self-serve deploy their app but **cannot** modify shared infra (firewall,
  clusters, VPC) or read platform secrets. They have Pulumi **Admin** on their
  own stack and **Read** on `platform-infra/prod`, plus a scoped DigitalOcean
  token (see "Granting a new app-owner").
```

- [ ] **Step 2: Add "Onboarding a new app (admin)"**

Add this section (after "Adding a New Environment / Stack"):

```markdown
## Onboarding a new app (admin)

App Platform apps are not VPC members, so each app must be registered as a
trusted source on the shared clusters, and its DB user must be granted schema
privileges (PG15+). App-owners cannot do this (by design). Run this once per
app, **after** the app-owner's first `pulumi up`:

```bash
export DIGITALOCEAN_TOKEN=<admin token, write scope>
./scripts/onboard-app.sh <app-name>
```

The script (idempotent) resolves the app's UUID, adds it to `trusted_app_ids`,
runs `pulumi up` to reconcile the firewalls, then grants the app's DB user
`CREATE` on schema `public`. Re-running it is safe.

Prerequisites: `pulumi login`, `psql` installed, and a write-scope DO token.
```

- [ ] **Step 3: Add "Granting a new app-owner" (durable, click-by-click)**

Add this section:

```markdown
## Granting a new app-owner

Do this once per person. It gives them self-serve deploy of their own apps
without admin rights to the platform.

### Pulumi Cloud
1. Go to https://app.pulumi.com/srainier → **Settings → Teams**.
2. Create (or open) a team named `app-owners`. Add the person as a member.
3. Go to the `platform-infra` project → `prod` stack → **Settings → Permissions**.
4. Grant the `app-owners` team **Read** on this stack (needed so their app's
   `StackReference` can read outputs). Do **not** grant Write/Admin.
5. The app-owner creates their own app stack; whoever creates a stack is
   automatically its Admin, so no further grant is needed for their app.

### DigitalOcean
1. Go to https://cloud.digitalocean.com → **Settings → Team → Roles** (or
   **Members**) and create a **custom role** named `app-deployer` with:
   - App Platform: **Create, Read, Update, Delete** (`app:*`)
   - Databases: **Create** and **Read** only (so they can create their per-app
     db/user/pool but cannot change firewalls or resize/delete clusters)
   - Networking/VPC: **no write** (Read at most)
   - Everything else: none
2. Invite the person to the DigitalOcean team with the `app-deployer` role.
3. Have them generate a Personal Access Token (API → Tokens). With the custom
   role applied, the token inherits those scopes. They use it as
   `DIGITALOCEAN_TOKEN` locally and as a GitHub Actions secret in their app repo.
```

- [ ] **Step 4: Fix "How App Repos Consume Outputs" + the outputs table**

Replace the code example to use public hosts and drop the admin password:

```python
import pulumi

platform = pulumi.StackReference("srainier/platform-infra/prod")

# Use the PUBLIC host from App Platform (apps are not VPC members).
postgres_host = platform.get_output("postgres_host_public")
postgres_port = platform.get_output("postgres_port")
postgres_admin_user = platform.get_output("postgres_admin_user")

redis_url = platform.get_secret_output("redis_url")  # public URI

vpc_id = platform.get_output("vpc_id")
do_region = platform.get_output("do_region")
```

Update the outputs table: remove the `postgres_admin_password` row; add
`postgres_host_public`, `postgres_connection_pool_host_public`,
`redis_host_public`, `redis_url_private` rows; mark `postgres_host` /
`postgres_connection_pool_host` / `redis_host` as "private (VPC only)" and note
that App Platform apps must use the `*_public` variants. Add a one-line note that
`postgres_admin_password` is intentionally not exported (admin reads it via the
DO API in `onboard-app.sh`).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(infra): role separation, app onboarding, app-owner grants, public outputs"
```

### Task 8: Consistency audit of remaining platform-infra docs

**Files:**
- Modify: `scripts/setup-saas.md`
- Modify: `docs/plans/2026-04-13_platform-infra-brief.md`
- Modify: `docs/plans/2026-04-13_platform-infra-phase-1-plan.md`

- [ ] **Step 1: Reconcile `scripts/setup-saas.md`**

Read it fully. Ensure the credential-ownership table reflects: `DIGITALOCEAN_TOKEN`/`PULUMI_ACCESS_TOKEN` for this repo are the **admin's**; app repos use the **app-owner's** scoped token. Add a pointer to the new "Granting a new app-owner" section. Remove any wording implying app repos use the admin token.

- [ ] **Step 2: Annotate the historical plans**

These are historical records. Do **not** rewrite them. Add a dated note at the top of each:

```markdown
> **Update 2026-06-06:** The platform now distinguishes infra-admin vs app-owner
> roles and onboards apps via `scripts/onboard-app.sh`. See
> `docs/superpowers/specs/2026-06-06-platform-app-role-separation-design.md`.
```

- [ ] **Step 3: Grep for stale assumptions**

Run: `grep -rniE "admin_password|private_host|never create|all-powerful|freely" *.md docs scripts`
Expected: no remaining text that contradicts the persona model or steers apps to private hosts/admin password (fix any hits).

- [ ] **Step 4: Commit**

```bash
git add scripts/setup-saas.md docs/plans
git commit -m "docs(infra): reconcile remaining docs with role-separation model"
```

### Task 9: Open the platform-infra PR

- [ ] **Step 1: Push the branch and open the PR**

```bash
git push -u origin feat/app-owner-role-separation
gh pr create --base main --head feat/app-owner-role-separation \
  --title "Role separation: declarative trusted apps, onboarding, public outputs, docs" \
  --body-file docs/superpowers/specs/2026-06-06-platform-app-role-separation-design.md
```

- [ ] **Step 2: Confirm CI (pulumi-preview) passes on the PR**

Run: `gh pr checks`
Expected: checks pass (or are pending). Do not merge until the user reviews — this stack touches shared production infra.

---

## Phase 5 — platform-app-template: app-owner docs (#4)

> Branch `docs/app-owner-runbook` in the `platform-app-template` repo.

### Task 10: Rewrite the generated app README runbook

**Files:**
- Modify: `template/README.md.jinja`

- [ ] **Step 1: Read the current generated README**

Run: `cat template/README.md.jinja`
Note its existing structure so the rewrite preserves anything still accurate (local dev, env vars).

- [ ] **Step 2: Add the self-serve deploy runbook + admin handoff**

Ensure the README contains a "Deploying" section with this flow (templated with `{{ app_name }}` where paths appear):

```markdown
## Deploying to the shared platform

You need: an `app-deployer` DigitalOcean token and Pulumi access (ask your
platform admin to grant you — see platform-infra → "Granting a new app-owner").

1. Set Pulumi config secrets (from `scripts/setup-saas.sh` output):
   `pulumi config set --secret {{ app_name }}:clerk_secret_key …` (and
   `flagsmith_api_key`, `sentry_dsn`, `honeycomb_api_key`). If you included the
   frontend, also: `pulumi config set {{ app_name }}:clerk_publishable_key pk_test_…`.
2. `cd infra && pulumi up` — creates your app + per-app database/user/pool.
   The first deploy may fail to reach the database — that is expected until the
   next step.
3. **Ask your platform admin to onboard this app (one-time):**
   `./scripts/onboard-app.sh {{ app_name }}` (run in platform-infra). This makes
   your app a trusted source and grants your DB user schema privileges.
4. Redeploy (push to `main`, or re-run `pulumi up`).
5. In the Flagsmith dashboard, create the `hello_banner` flag (enabled) for your
   environment so `/feature` reports it on.
6. Verify: `curl https://<app-url>/api/` shows all integrations true.
```

- [ ] **Step 3: Add the per-app credentials inventory**

Add a table:

```markdown
## Credentials reference

| Credential | Where it lives | Who provides it |
|---|---|---|
| `DIGITALOCEAN_TOKEN` (`app-deployer`) | local env + GitHub Actions secret | you (issued by admin) |
| `PULUMI_ACCESS_TOKEN` | local + GitHub Actions secret | you |
| `clerk_secret_key` | Pulumi config secret | you (Clerk **Development** instance) |
| `clerk_publishable_key` | Pulumi config (non-secret) | you (frontend only) |
| `flagsmith_api_key` | Pulumi config secret | you |
| `sentry_dsn` | Pulumi config secret | you |
| `honeycomb_api_key` | Pulumi config secret | you |
| Trusted source + schema grant | platform clusters | **platform admin** (onboard-app.sh) |
```

- [ ] **Step 4: Render + sanity-check**

Run:
```bash
copier copy --trust --defaults --data app_name=verify-app --data app_display_name="Verify App" \
  --data include_frontend=true --data include_ios=false \
  --data github_handle=srainier --data pulumi_org=srainier . /tmp/readme-verify
sed -n '1,80p' /tmp/readme-verify/README.md
```
Expected: README renders with `verify-app` substituted, runbook + table present.

- [ ] **Step 5: Commit**

```bash
git add template/README.md.jinja
git commit -m "docs(template): app-owner self-serve runbook + credentials inventory"
```

### Task 11: Consistency audit of platform-app-template top-level docs

**Files:**
- Modify: `README.md`
- Modify: `docs/plans/2026-04-13_*.md` (annotate only)

- [ ] **Step 1: Reconcile the top-level `README.md`**

Read `README.md` (the template repo's own readme). Update the "Usage" / post-scaffold steps so they reference the admin onboarding handoff and the `app-deployer` token, and link to platform-infra's role docs. Ensure it no longer implies the scaffolder has admin rights.

- [ ] **Step 2: Annotate historical plans**

Add the same dated `> Update 2026-06-06:` note (as in Task 8 Step 2) to the top of each file in `docs/plans/`.

- [ ] **Step 3: Grep for stale assumptions**

Run: `grep -rniE "sk_live|admin token|private_host|requirements.txt" README.md template/README.md.jinja`
Expected: no stale references (Clerk uses dev keys; no admin token for app-owners; no private host; no requirements.txt).

- [ ] **Step 4: Commit, push, PR**

```bash
git add README.md docs/plans
git commit -m "docs(template): reconcile docs with platform role-separation model"
git push -u origin docs/app-owner-runbook
gh pr create --base main --head docs/app-owner-runbook \
  --title "Docs: app-owner self-serve runbook + credentials + role-separation consistency" \
  --body "Companion to platform-infra role-separation. Adds the generated app runbook, per-app credentials inventory, and reconciles existing docs with the infra-admin / app-owner model."
```

---

## Self-Review

**Spec coverage:**
- Personas / RBAC model → Task 7 Steps 1,3 (docs); enforced operationally by Tasks 1–5.
- #10 declarative trusted apps → Tasks 1–3.
- Secret isolation (drop admin password) → Task 4.
- #11/#12 public outputs → Task 4 + Task 7 Step 4.
- #13 schema grant → Task 5 (script) + Task 6 (verify).
- Onboarding script → Tasks 5–6.
- Docs (#4) + consistency audit (both repos) → Tasks 7, 8, 10, 11.
- Onboarding flow end-to-end → captured in Task 7 Step 2 + Task 10 Step 2.

**Open questions from spec — resolved here:**
- Output rename strategy → **add public variants, keep private** (Task 4), non-breaking; `redis_url` repurposed to public since the only consumer needs public.
- Historical `docs/plans/*` → **annotate, do not rewrite** (Task 8 Step 2, Task 11 Step 2).

**Placeholder scan:** none — full script and doc content inline.

**Naming consistency:** `trusted_app_ids` config, `onboard-app.sh`, `app-deployer` DO role, `app-owners` Pulumi team, `*_public` outputs — used consistently across tasks.
