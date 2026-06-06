> **Update 2026-06-06:** The platform now distinguishes infra-admin vs app-owner
> roles and onboards apps via `scripts/onboard-app.sh`. See
> `docs/superpowers/specs/2026-06-06-platform-app-role-separation-design.md`.

# Phase 1 Implementation Plan: platform-infra

## Context

This repository is the shared infrastructure foundation for a multi-project development platform. Phase 1 provisions all project-agnostic DigitalOcean resources (Postgres, Redis, VPC, DNS stub, DO Project) as code using Pulumi (Python SDK), documents SaaS service setup, and exports well-named stack outputs that future per-app Pulumi stacks will consume via Stack References.

The technical brief is in `docs/plans/2026-04-13_platform-infra-brief.md`. All decisions (region, naming, stack path, etc.) are already resolved there. Nothing needs to be designed — this is a build-from-spec task.

---

## Files to Create

All files below are **new** (the repo currently has only `README.md`, `LICENSE`, `.gitignore`, and the docs directory).

---

## Implementation Steps

### 1. `pyproject.toml`

uv-managed project. Pulumi Python SDK + DigitalOcean provider as dependencies. Pyright strict + ruff configured here.

```toml
[project]
name = "platform-infra"
version = "0.1.0"
requires-python = ">=3.14"
dependencies = [
    "pulumi>=3,<4",
    "pulumi-digitalocean>=4",
]

[tool.pyright]
pythonVersion = "3.14"
typeCheckingMode = "strict"

[tool.ruff]
target-version = "py314"
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM"]
```

### 2. `Pulumi.yaml`

```yaml
name: platform-infra
runtime:
  name: python
  options:
    toolchain: uv
    virtualenv: .venv
description: Shared platform infrastructure for all projects
```

### 3. `Pulumi.prod.yaml`

Non-secret stack config. Secrets (tokens, passwords) are set via `pulumi config set --secret` and never committed.

```yaml
config:
  platform-infra:do_region: nyc3
  platform-infra:postgres_version: "18"
  platform-infra:postgres_size: db-s-1vcpu-1gb
  platform-infra:valkey_size: db-s-1vcpu-1gb
  platform-infra:domain: ""
```

### 4. `infra/__init__.py`

Empty — marks `infra` as a Python package.

### 5. `infra/networking.py`

Creates:
- Custom VPC (`platform-vpc`, `10.10.0.0/16`, `nyc3`)

```python
import pulumi
import pulumi_digitalocean as do

def create_vpc(region: str) -> do.Vpc:
    return do.Vpc(
        "platform-vpc",
        name="platform-vpc",
        region=region,
        ip_range="10.10.0.0/16",
    )
```

### 6. `infra/postgres.py`

Creates:
- Managed PostgreSQL cluster (`platform-postgres`) — engine `pg`, single node, placed in VPC
- Connection pool (`platform-postgres-pool`) — PgBouncer in transaction mode
- Database firewall — VPC-only access

```python
import pulumi_digitalocean as do

def create_postgres(region: str, version: str, size: str, vpc_id: pulumi.Input[str]) -> tuple[do.DatabaseCluster, do.DatabaseConnectionPool]:
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
    
    firewall = do.DatabaseFirewall(
        "platform-postgres-firewall",
        cluster_id=cluster.id,
        rules=[do.DatabaseFirewallRuleArgs(type="vpc", value=vpc_id)],
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

### 7. `infra/valkey.py`

> **Note:** DigitalOcean deprecated Managed Redis on June 30, 2025 and replaced it with Managed Valkey (a Redis-compatible, Linux Foundation fork). The Pulumi resource is `do.DatabaseCluster` with `engine="valkey"`. Apps continue using standard Redis clients — the connection interface is identical.

Creates:
- Managed Valkey cluster (`platform-valkey`) — single node, placed in VPC, engine `valkey` version `8`
- Database firewall — VPC-only access

```python
def create_valkey(region: str, size: str, vpc_id: pulumi.Input[str]) -> do.DatabaseCluster:
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
    
    firewall = do.DatabaseFirewall(
        "platform-valkey-firewall",
        cluster_id=cluster.id,
        rules=[do.DatabaseFirewallRuleArgs(type="vpc", value=vpc_id)],
    )
    
    return cluster
```

### 8. `infra/dns.py`

Stubbed — exports `None`. Comment explains how to enable when a domain is available.

```python
import pulumi

def create_dns_zone(domain: str) -> pulumi.Output[str] | None:
    # DNS zone provisioning is disabled until a domain is configured.
    # To enable: create a do.Domain resource here and return its name output.
    # Set platform-infra:domain in Pulumi.<stack>.yaml to activate.
    if domain:
        raise NotImplementedError("DNS zone provisioning not yet implemented")
    return None
```

### 9. `infra/outputs.py`

Single place for all `pulumi.export()` calls. Takes the provisioned resources as arguments.

Exports (13 outputs per spec, `redis_*` keys preserved for app-repo compatibility even though the underlying engine is now Valkey):
- `postgres_cluster_id`, `postgres_host`, `postgres_port`, `postgres_admin_user`, `postgres_admin_password` (secret), `postgres_connection_pool_host`
- `redis_host`, `redis_port`, `redis_password` (secret), `redis_url` (secret) — sourced from the Valkey cluster; key names kept as `redis_*` so app repos need no changes
- `vpc_id`, `do_region`, `dns_zone`

### 10. `__main__.py`

Pulumi entrypoint. Reads config, calls each `infra/` module, passes outputs to `infra/outputs.py`.

```python
import pulumi
from infra import networking, postgres, valkey, dns, outputs

config = pulumi.Config()
region: str = config.require("do_region")
pg_version: str = config.require("postgres_version")
pg_size: str = config.require("postgres_size")
valkey_size: str = config.require("valkey_size")
domain: str = config.get("domain") or ""

vpc = networking.create_vpc(region)
pg_cluster, pg_pool = postgres.create_postgres(region, pg_version, pg_size, vpc.id)
valkey_cluster = valkey.create_valkey(region, valkey_size, vpc.id)
dns_zone = dns.create_dns_zone(domain)

outputs.export_all(
    region=region,
    vpc=vpc,
    postgres_cluster=pg_cluster,
    postgres_pool=pg_pool,
    valkey_cluster=valkey_cluster,
    dns_zone=dns_zone,
)
```

### 11. `.env.example`

Documents required environment variables for local development (tokens, etc.).

```
# Copy to .env and fill in values — never commit .env
DIGITALOCEAN_TOKEN=
PULUMI_ACCESS_TOKEN=
```

### 12. `scripts/setup-saas.md`

SaaS setup checklist covering: Clerk, Flagsmith, Honeycomb, Sentry, Pulumi Cloud. For each: one-time account setup steps, where to store API keys (GitHub Actions Secrets), what per-app repos do themselves.

### 13. `.github/workflows/pulumi-preview.yml`

Trigger: `pull_request` to `main`. Runner: `ubuntu-24.04`.

Steps:
1. Checkout
2. Install uv
3. Set up Python (3.14)
4. `uv sync` (installs deps into `.venv`)
5. `uv run ruff check .`
6. `uv run ruff format --check .`
7. `uv run pyright`
8. `pulumi preview --stack prod` (with `PULUMI_ACCESS_TOKEN` + `DIGITALOCEAN_TOKEN` secrets)
9. Post preview output as PR comment

### 14. `.github/workflows/pulumi-up.yml`

Trigger: `push` to `main`. Runner: `ubuntu-24.04`.

Steps:
1-4. Same setup as preview
5. `pulumi up --yes --stack prod`

Required secrets: `PULUMI_ACCESS_TOKEN`, `DIGITALOCEAN_TOKEN`

### 15. `README.md` (rewrite)

Sections per spec:
1. What this repo is and the platform model
2. Prerequisites (accounts: DO, Pulumi Cloud, GitHub; tools: uv, pulumi CLI)
3. First-time bootstrap instructions (clone, uv sync, pulumi stack init, set secrets, pulumi up)
4. SaaS setup checklist (pointer to `scripts/setup-saas.md`)
5. How to add a new environment/stack
6. How app repos consume outputs via Stack References (Python code example using `srainier/platform-infra/prod`)
7. How to run locally (pulumi preview with local env vars)
8. CI/CD overview
9. Cost estimate (idle): ~$30-40/mo (Postgres $15, Valkey $15, VPC free)

---

## Critical Files

| File | Status |
|---|---|
| `pyproject.toml` | Create |
| `Pulumi.yaml` | Create |
| `Pulumi.prod.yaml` | Create |
| `__main__.py` | Create |
| `infra/__init__.py` | Create |
| `infra/networking.py` | Create |
| `infra/postgres.py` | Create |
| `infra/valkey.py` | Create |
| `infra/dns.py` | Create |
| `infra/outputs.py` | Create |
| `.env.example` | Create |
| `scripts/setup-saas.md` | Create |
| `.github/workflows/pulumi-preview.yml` | Create |
| `.github/workflows/pulumi-up.yml` | Create |
| `README.md` | Rewrite |

---

## Quality Checklist

- [ ] All resource names prefixed with `platform-`
- [ ] No hardcoded values — everything from `pulumi.Config()` or secrets
- [ ] All `pulumi.export()` calls go through `infra/outputs.py` only
- [ ] Passwords/tokens marked as secrets (not plaintext in outputs)
- [ ] pyright strict — all functions fully typed, no `Any`
- [ ] ruff lint + format passing
- [ ] `.env` in `.gitignore` (already present)

---

## Verification

1. **Static analysis**: `uv run ruff check . && uv run ruff format --check . && uv run pyright` — all pass with zero errors
2. **Pulumi preview dry-run**: `pulumi preview --stack prod` shows all expected resources with no errors (requires real DO token + Pulumi access token)
3. **Stack outputs**: After `pulumi up`, all 13 outputs are present in `pulumi stack output`
4. **Stack Reference test**: A separate Pulumi stack can read outputs via `pulumi.StackReference("srainier/platform-infra/prod")`
5. **CI check**: Opening a PR triggers preview workflow; merging to main triggers apply workflow
