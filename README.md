# platform-infra

Shared infrastructure foundation for all projects. Provisions DigitalOcean managed Postgres and Valkey (Redis-compatible), a custom VPC, and a DigitalOcean Project using Pulumi (Python SDK). All resources are exported as stack outputs for per-app Pulumi stacks to consume via Stack References.

This repo is provisioned once to bootstrap the platform, then rarely touched. Application repos build on top of it — they never create their own databases or VPCs.

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

## How App Repos Consume Outputs

App repos reference this stack's outputs via Pulumi Stack References. Example:

```python
import pulumi

platform = pulumi.StackReference("srainier/platform-infra/prod")

postgres_host = platform.get_output("postgres_host")
postgres_port = platform.get_output("postgres_port")
postgres_admin_user = platform.get_output("postgres_admin_user")
postgres_admin_password = platform.get_secret_output("postgres_admin_password")

redis_host = platform.get_output("redis_host")
redis_url = platform.get_secret_output("redis_url")

vpc_id = platform.get_output("vpc_id")
do_region = platform.get_output("do_region")
```

> `get_secret_output()` is used for values marked secret (passwords, URLs containing credentials).

### Available Stack Outputs

| Output | Description |
|---|---|
| `postgres_cluster_id` | Managed Postgres cluster ID |
| `postgres_host` | Private hostname (VPC) |
| `postgres_port` | Port (usually 25060) |
| `postgres_admin_user` | Admin username |
| `postgres_admin_password` | Admin password **(secret)** |
| `postgres_connection_pool_host` | PgBouncer private hostname |
| `redis_host` | Valkey private hostname (VPC) |
| `redis_port` | Valkey port |
| `redis_password` | Valkey auth password **(secret)** |
| `redis_url` | Full Valkey connection URL **(secret)** |
| `vpc_id` | VPC ID for app resource placement |
| `do_region` | DigitalOcean region (`nyc3`) |
| `dns_zone` | Root domain (null — not yet configured) |

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
