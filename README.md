# platform-infra

Shared infrastructure foundation for all projects. Provisions DigitalOcean managed Postgres and Valkey (Redis-compatible), a custom VPC, and a DigitalOcean Project using Pulumi (Python SDK). All resources are exported as stack outputs for per-app Pulumi stacks to consume via Stack References.

---

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

---

## Prerequisites

**Accounts required:**
- [DigitalOcean](https://cloud.digitalocean.com) — cloud provider
- [Pulumi Cloud](https://app.pulumi.com) (free tier) — state backend; org name: `srainier`
- [GitHub](https://github.com) — CI/CD via Actions

**Tools required (local):**
- [uv](https://docs.astral.sh/uv/) — Python toolchain (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- [Pulumi CLI](https://www.pulumi.com/docs/install/) — IaC runner (`brew install pulumi/tap/pulumi`)

---

## First-Time Bootstrap

```bash
# 1. Clone and install dependencies
git clone https://github.com/srainier/platform-infra
cd platform-infra
uv sync

# 2. Authenticate
pulumi login                         # opens browser → Pulumi Cloud
export DIGITALOCEAN_TOKEN=<your-token>

# 3. Create and configure the prod stack
pulumi stack init srainier/prod
# Non-secret config is already in Pulumi.prod.yaml — no manual steps needed.

# 4. Deploy
pulumi up --stack prod
```

Once complete, all stack outputs are available via `pulumi stack output --stack prod`.

---

## SaaS Setup

See [`scripts/setup-saas.md`](scripts/setup-saas.md) for one-time account setup for Clerk, Flagsmith, Honeycomb, Sentry, and Pulumi Cloud, including where to store API keys.

---

## Adding a New Environment / Stack

```bash
pulumi stack init srainier/<env-name>
# Edit or copy Pulumi.prod.yaml → Pulumi.<env-name>.yaml with desired config values
pulumi up --stack <env-name>
```

---

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

---

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

---

## How App Repos Consume Outputs

App repos reference this stack's outputs via Pulumi Stack References. Example:

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

> `get_secret_output()` is used for values marked secret (passwords, URLs containing credentials).

### Available Stack Outputs

| Output | Description |
|---|---|
| `postgres_cluster_id` | Managed Postgres cluster ID |
| `postgres_host` | Private hostname — **VPC only** (Droplets, not App Platform) |
| `postgres_host_public` | Public hostname — **use this from App Platform apps** |
| `postgres_port` | Port (usually 25060) |
| `postgres_admin_user` | Admin username |
| `postgres_connection_pool_host` | PgBouncer private hostname — **VPC only** |
| `postgres_connection_pool_host_public` | PgBouncer public hostname — **use this from App Platform apps** |
| `redis_host` | Valkey private hostname — **VPC only** |
| `redis_host_public` | Valkey public hostname — **use this from App Platform apps** |
| `redis_port` | Valkey port |
| `redis_password` | Valkey auth password **(secret)** |
| `redis_url` | Full Valkey connection URL, public URI **(secret)** — App Platform apps use this |
| `redis_url_private` | Full Valkey connection URL, private/VPC URI **(secret)** |
| `vpc_id` | VPC ID for app resource placement |
| `do_region` | DigitalOcean region (`nyc3`) |
| `dns_zone` | Root domain (null — not yet configured) |

> **`postgres_admin_password` is intentionally not exported.** App-owners have Read on this stack via StackReference; no admin secret may be exported. The admin onboarding script reads `doadmin` credentials directly from the DO API in `onboard-app.sh`.

> **App Platform apps must use the `*_public` variants** — App Platform services are not VPC members and cannot reach private hosts.

> **Note on `redis_*` outputs:** The underlying engine is DigitalOcean Managed Valkey (Redis 8, Redis-compatible). Output keys use `redis_*` naming so app repos don't need changes.

---

## Running Locally

```bash
# Set env vars (copy .env.example → .env and fill in)
export DIGITALOCEAN_TOKEN=...
export PULUMI_ACCESS_TOKEN=...

# Preview changes without applying
pulumi preview --stack prod

# Apply changes
pulumi up --stack prod
```

---

## CI/CD

| Event | Workflow | Action |
|---|---|---|
| Pull request to `main` | `pulumi-preview.yml` | Lint + type-check + `pulumi preview`, posts output as PR comment |
| Push to `main` | `pulumi-up.yml` | Lint + type-check + `pulumi up --yes` |

Merging to `main` is the only way to apply changes to production.

**Required GitHub Actions Secrets:**

| Secret | Description |
|---|---|
| `PULUMI_ACCESS_TOKEN` | Pulumi Cloud access token |
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token |

Set at: repo Settings → Secrets and variables → Actions.

---

## Cost Estimate (Idle)

| Resource | Monthly cost |
|---|---|
| Managed Postgres (`db-s-1vcpu-1gb`) | ~$15 |
| Managed Valkey (`db-s-1vcpu-1gb`) | ~$15 |
| VPC | Free |
| DigitalOcean Project | Free |
| **Total** | **~$30/mo** |

Costs increase as you scale node count or upgrade instance sizes.
