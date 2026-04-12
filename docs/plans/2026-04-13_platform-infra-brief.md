# Platform Infra — Claude Code Technical Brief

**Purpose of this document:** This is a technical brief for a Claude Code plan mode
session. It covers two phases:

- **Phase 1** — Build the `platform-infra` repo (shared infrastructure, runs once)
- **Phase 2** — Build the `platform-app-template` repo (cookiecutter template for new apps)

Phase 1 must be fully built and working before Phase 2 begins. Each phase should be
a separate Claude Code plan mode session. Do not start implementing either phase until
the plan for that phase has been reviewed and approved.

---

---

# Phase 1 — `platform-infra`

---

## What This Repo Is

A standalone infrastructure repository that provisions and manages all **shared,
project-agnostic infrastructure** for a multi-project development platform. It is
the foundation layer that all future application repos build on top of. It is not an
application itself.

The repo will be **public on GitHub** and licensed **MIT**. It should be written as
if other developers might use or learn from it — clean, well-commented, and with a
good README.

---

## Goals

1. Provision all shared DigitalOcean infrastructure as code using Pulumi (Python SDK)
2. Configure all supporting SaaS services that are shared across projects
3. Export well-named stack outputs so that per-app Pulumi stacks can consume them via
   Pulumi Stack References
4. Be runnable once by a human to bootstrap the platform, then rarely touched again
5. Be fully reproducible — no manual steps in the DigitalOcean console or any other
   dashboard

---

## Technology Constraints

These are fixed. Do not suggest alternatives.

- **IaC tool:** Pulumi, Python SDK
- **Pulumi state backend:** Pulumi Cloud (free tier)
- **Cloud provider:** DigitalOcean (primary)
- **Python tooling:** uv (package/env management), pyright (strict), ruff (lint +
  format)
- **CI:** GitHub Actions
- **License:** MIT

---

## What This Repo Provisions

### DigitalOcean Resources

- **Managed PostgreSQL cluster** (basic/starter tier)
  - Latest supported Postgres major version
  - Single node to start (can be scaled later)
  - No databases created here — each app creates its own database on this cluster
  - Connection pooling enabled (PgBouncer)

- **Managed Redis instance** (basic/starter tier)
  - Used as shared background task broker across all apps
  - Key prefix convention enforced via documentation (not infra) — each app namespaces
    its own keys as `{project_name}:`

- **DigitalOcean Project** (logical grouping)
  - All platform resources assigned to this project
  - Per-app resources will be assigned to per-app DO projects (handled in app repos)

- **DNS zone** — stubbed out for now
  - No domain has been configured yet
  - The DNS module should exist as a no-op stub with a comment explaining how to
    enable it when a domain is available
  - The `dns_zone` stack output should export `None`

- **VPC** (included, free on DigitalOcean)
  - Create a custom VPC (not the default) for platform resources
  - Private networking for Postgres and Redis — no extra cost, worth doing for security
  - App Platform services connect via private network

### SaaS Services Configured

These are not provisioned via Pulumi (no Terraform/Pulumi providers exist or are
reliable for all of them) but the repo should document and script their setup:

- **Clerk** — one top-level account; per-app Applications are created in app repos
- **Flagsmith** — one top-level account; per-app Projects created in app repos
- **Honeycomb** — one account; per-app Datasets created in app repos
- **Sentry** — one account; per-app Projects created in app repos
- **Pulumi Cloud** — state backend; stack per environment

For each SaaS service, provide:
- A setup checklist in the README (what to create manually once)
- Where to store the resulting API keys/tokens (GitHub Actions Secrets, referenced
  below)

### Secrets & Configuration

All sensitive outputs (DB connection strings, Redis URL, API keys) must be:
- Stored as **Pulumi secrets** (encrypted in state)
- Exported as stack outputs for consumption by app stacks
- Never written to plaintext files or committed to the repo

A `.env.example` file should document every environment variable needed to run
Pulumi in this repo, without values.

---

## Stack Outputs (Pulumi Exports)

The following must be exported by the Pulumi stack so app repos can consume them via
Stack References. These are the contract between this repo and all app repos.

| Output name | Description |
|---|---|
| `postgres_cluster_id` | DO Postgres cluster ID |
| `postgres_host` | Private hostname of the cluster |
| `postgres_port` | Port (usually 25060 for DO managed PG) |
| `postgres_admin_user` | Admin username (for app stacks to create per-app DB users) |
| `postgres_admin_password` | Admin password (Pulumi secret) |
| `postgres_connection_pool_host` | PgBouncer hostname if enabled |
| `redis_host` | Private hostname of Redis instance |
| `redis_port` | Redis port |
| `redis_password` | Redis auth password (Pulumi secret) |
| `redis_url` | Full Redis connection URL (Pulumi secret) |
| `vpc_id` | VPC ID for app resources to join |
| `do_region` | Region everything is deployed in |
| `dns_zone` | Root domain if DNS is configured (nullable) |

---

## Repository Structure (suggested, open to refinement in plan)

```
platform-infra/
├── LICENSE
├── README.md
├── .env.example
├── .gitignore
├── pyproject.toml          # uv-managed, pyright + ruff config
├── Pulumi.yaml             # Pulumi project definition
├── Pulumi.prod.yaml        # Stack config (non-secret values)
├── __main__.py             # Pulumi entrypoint
├── infra/
│   ├── __init__.py
│   ├── postgres.py         # Postgres cluster resource
│   ├── redis.py            # Redis resource
│   ├── networking.py       # VPC, firewall rules
│   ├── dns.py              # DNS zone (conditional)
│   └── outputs.py          # All stack exports in one place
├── scripts/
│   └── setup-saas.md       # Step-by-step SaaS account setup checklist
└── .github/
    └── workflows/
        └── pulumi-preview.yml   # PR: run pulumi preview
        └── pulumi-up.yml        # main: run pulumi up
```

---

## CI/CD Behaviour

### On pull request
- Run `pulumi preview` (plan only, no changes applied)
- Run pyright, ruff lint, ruff format check
- Post preview output as a PR comment

### On merge to main
- Run `pulumi up --yes` (apply changes)
- This is the only way infrastructure changes are applied — no manual `pulumi up`
  from a local machine in production

### Required GitHub Actions Secrets

Document these in README; they must be set before CI works:

- `PULUMI_ACCESS_TOKEN` — Pulumi Cloud token
- `DIGITALOCEAN_TOKEN` — DO API token with write access
- `DIGITALOCEAN_SPACES_ACCESS_KEY` — if Spaces (object storage) is used
- `DIGITALOCEAN_SPACES_SECRET_KEY` — as above

---

## Configuration Approach

Non-secret config (region, cluster sizes, domain name) lives in `Pulumi.prod.yaml`
as Pulumi stack config values. Secret config is set via `pulumi config set --secret`
and stored encrypted in the stack state.

Example non-secret config values:
- `do_region` (e.g. `nyc3`)
- `postgres_version` (e.g. `16`)
- `postgres_size` (e.g. `db-s-1vcpu-1gb`)
- `redis_size` (e.g. `db-s-1vcpu-1gb`)
- `domain` (nullable)

---

## Quality Standards

Enforce these — they are non-negotiable per the base stack spec:

- pyright strict mode — all code must be fully typed
- ruff lint + format — no exceptions
- All Pulumi resource names should be consistent and prefixed with `platform-`
- All resources should have meaningful tags/labels where DigitalOcean supports them
- No hardcoded values — everything comes from stack config or Pulumi secrets
- All `pulumi.export()` calls go through `infra/outputs.py`, nowhere else

---

## README Requirements

The README should cover:

1. What this repo is and how it fits into the broader platform model
2. Prerequisites (accounts needed, tools to install)
3. First-time bootstrap instructions (step by step)
4. SaaS setup checklist (Clerk, Flagsmith, Honeycomb, Sentry)
5. How to add a new environment/stack
6. How app repos consume outputs via Stack References (with a code example)
7. How to run locally (pulumi preview)
8. CI/CD overview
9. Cost estimate (idle)

---

## Out of Scope for This Repo

Be explicit about what does NOT live here:

- Per-app databases (created in app repos)
- Per-app Clerk Applications (created in app repos)
- Per-app Flagsmith Projects (created in app repos)
- Per-app Sentry Projects (created in app repos)
- Per-app Honeycomb Datasets (created in app repos)
- App Platform services / containers (created in app repos)
- Application code of any kind

---

## Resolved Configuration Decisions

All decisions are final — do not re-ask these during planning.

| Decision | Value | Notes |
|---|---|---|
| DO region | `nyc3` | US east coast, most mature DO region |
| Domain / DNS | None for now | DNS module stubbed as no-op; `dns_zone` output exports `None` |
| Pulumi org | `srainier` | Matches GitHub handle; sign up at app.pulumi.com before session |
| GitHub handle | `srainier` | Repo will live at github.com/srainier/platform-infra |
| Stack Reference path | `srainier/platform-infra/prod` | App repos use this exact path |
| VPC | Yes, custom VPC | Free on DO; create named platform VPC rather than using default |
| Firewall rules | Use DO trusted sources | Lock Postgres and Redis to App Platform + VPC only |

---

# Phase 2 — `platform-app-template`

---

## What This Repo Is

A **cookiecutter template** that scaffolds a new application repo pre-wired to the
`platform-infra` stack. When a developer runs the scaffold tool against this template,
they answer a handful of questions and receive a fully configured repo they can
immediately start writing application code in.

This repo is also public, MIT licensed, and lives at
`github.com/srainier/platform-app-template`.

The goal: starting a new side project should take 5 minutes of setup, not a day.

---

## Template Tool

Use **copier** (not cookiecutter) — it supports re-applying templates to existing
repos when the template is updated, which cookiecutter does not. This means if the
base template improves (e.g. a CI workflow is updated), existing app repos can pull
the update in rather than being permanently forked from the template.

- Template engine: **copier**
- Template config file: `copier.yaml` in repo root
- Python-based; installable via `uv tool install copier`

---

## Scaffold Questions (copier.yaml prompts)

These are the only questions asked when scaffolding a new app:

| Prompt | Variable | Example |
|---|---|---|
| App name (slug, lowercase, hyphens) | `app_name` | `my-cool-app` |
| Human-readable app name | `app_display_name` | `My Cool App` |
| Include web frontend? (Next.js) | `include_frontend` | `yes` / `no` |
| Include iOS app? | `include_ios` | `yes` / `no` |
| Your GitHub handle | `github_handle` | `srainier` |
| Pulumi org | `pulumi_org` | `srainier` |

Everything else is derived from these values or pulled from the platform stack
at infra deploy time.

---

## What Gets Scaffolded

### Always included

```
{app_name}/
├── LICENSE                         # MIT
├── README.md                       # Pre-filled with app name, setup instructions
├── .gitignore
├── .env.example                    # All required env vars documented, no values
├── .github/
│   └── workflows/
│       ├── checks.yml              # PR: typecheck, lint, format, test
│       └── deploy.yml              # main: pulumi up + app deploy
├── infra/                          # Per-app Pulumi stack
│   ├── __main__.py
│   ├── Pulumi.yaml
│   ├── Pulumi.prod.yaml
│   ├── pyproject.toml
│   └── resources/
│       ├── __init__.py
│       ├── database.py             # Creates DB on shared cluster
│       ├── app_platform.py         # DO App Platform service
│       ├── clerk.py                # Clerk application (via API)
│       ├── flagsmith.py            # Flagsmith project (via API)
│       ├── sentry.py               # Sentry project (via API)
│       ├── honeycomb.py            # Honeycomb dataset (via API)
│       └── outputs.py              # Stack exports
└── backend/                        # FastAPI application
    ├── pyproject.toml              # uv-managed
    ├── app/
    │   ├── __init__.py
    │   ├── main.py                 # FastAPI app entrypoint
    │   ├── config.py               # Settings via pydantic-settings
    │   ├── db.py                   # SQLAlchemy async engine setup
    │   └── api/
    │       └── health.py           # GET /health endpoint (always present)
    └── tests/
        ├── __init__.py
        └── test_health.py
```

### If `include_frontend = yes` — also includes

```
frontend/                           # Next.js application
├── package.json
├── tsconfig.json                   # Strict mode
├── biome.json                      # Formatter + linter config
├── next.config.ts
├── app/
│   ├── layout.tsx
│   └── page.tsx                    # Minimal placeholder home page
└── components/                     # Empty, ready for shadcn/ui
```

### If `include_ios = yes` — also includes

```
ios/                                # Swift/SwiftUI app
└── {AppDisplayName}/
    ├── {AppDisplayName}App.swift
    └── ContentView.swift           # Placeholder view
```

---

## The Per-App Infra Stack (most important part)

This is what makes a new app "know about" the platform. The `infra/` folder contains
a Pulumi stack that:

**1. Reads platform outputs via Stack Reference**

```python
# infra/resources/platform.py (generated)
import pulumi

platform = pulumi.StackReference("srainier/platform-infra/prod")

postgres_host = platform.get_output("postgres_host")
postgres_port = platform.get_output("postgres_port")
postgres_admin_user = platform.get_output("postgres_admin_user")
postgres_admin_password = platform.get_output("postgres_admin_password")
redis_url = platform.get_output("redis_url")
vpc_id = platform.get_output("vpc_id")
do_region = platform.get_output("do_region")
```

**2. Creates a database on the shared cluster**

```python
# infra/resources/database.py (generated, simplified)
import pulumi_digitalocean as do

db = do.DatabaseDb(
    "app-name-db",
    cluster_id=postgres_cluster_id,
    name="app_name",  # derived from app_name prompt, underscores
)

db_user = do.DatabaseUser(
    "app-name-db-user",
    cluster_id=postgres_cluster_id,
    name="app_name_user",
)
```

**3. Constructs a DATABASE_URL and injects it into App Platform as a secret env var**

The app itself reads only `DATABASE_URL` from its environment — it never knows or
cares that it lives on a shared cluster.

**4. Creates App Platform service**

```python
app = do.App(
    "app-name",
    spec=do.AppSpecArgs(
        name="app-name",
        region="nyc3",
        services=[do.AppSpecServiceArgs(
            name="api",
            environment_slug="python",
            # ... git source, build config
            envs=[
                do.AppSpecServiceEnvArgs(
                    key="DATABASE_URL",
                    value=database_url,  # Pulumi secret
                    type="SECRET",
                ),
                do.AppSpecServiceEnvArgs(
                    key="REDIS_URL",
                    value=redis_url,
                    type="SECRET",
                ),
            ],
        )],
    ),
)
```

**5. Exports its own stack outputs** for any downstream reference needs

```python
# infra/resources/outputs.py (generated)
pulumi.export("app_url", app.live_url)
pulumi.export("database_name", db.name)
```

---

## Per-App SaaS Resources

Some SaaS services (Clerk, Flagsmith, Sentry, Honeycomb) don't have reliable Pulumi
providers. The template should handle them as follows:

| Service | Approach |
|---|---|
| **Clerk** | Pulumi resource via `@clerk/agent-toolkit` HTTP calls wrapped in a Pulumi dynamic provider, or documented as a manual step with API key stored in GitHub secret |
| **Flagsmith** | REST API call in a Pulumi dynamic provider to create project + return API key |
| **Sentry** | REST API call in a Pulumi dynamic provider to create project + return DSN |
| **Honeycomb** | REST API call in a Pulumi dynamic provider to create dataset + return API key |

For any service where a dynamic provider is too fragile, provide a `scripts/setup-saas.sh`
that calls the relevant APIs and prints the keys to stdout for the developer to save
as GitHub secrets. Document clearly in the README which services are auto-provisioned
vs manual.

---

## GitHub Actions Workflows (generated per app)

### `checks.yml` — runs on every PR

- pyright (backend)
- ruff lint + format (backend)
- tsc + Biome (frontend, if included)
- pytest unit + integration tests
- Playwright E2E (on merge to main only, or manually triggered on PR)

### `deploy.yml` — runs on merge to main

1. Run `pulumi up` in `infra/` (provisions/updates all app resources)
2. Deploy backend to App Platform (triggered automatically by DO on git push, or
   via `doctl` if more control is needed)
3. Deploy frontend to Vercel or App Platform (project decision)

---

## README Requirements (generated per app)

The scaffolded README should be pre-filled and cover:

1. What this app is (placeholder text for developer to replace)
2. Architecture overview — references `platform-infra` for shared infra
3. Local development setup (step by step: clone, uv sync, docker compose up,
   uvicorn, next dev)
4. Environment variables — what each one is, where it comes from
5. How to run tests
6. How to deploy (just: merge to main)
7. How to add a feature flag
8. Links to Clerk, Flagsmith, Sentry, Honeycomb dashboards (with placeholder URLs)

---

## Quality Standards (same as Phase 1)

- pyright strict, ruff, Biome — all enforced in CI
- No hardcoded values anywhere in the template
- All template variables must be used consistently (no `app_name` vs `appName`
  inconsistency across files)
- The scaffolded repo must pass all CI checks immediately after scaffolding,
  before any application code is written

---

## Out of Scope for the Template Repo

- The actual application business logic (obviously)
- Opinionated database schema or data models
- Any UI components beyond a bare placeholder page
- Mobile-specific CI (Xcode Cloud or similar) — stub only

---

## How a Developer Uses This (the full flow)

This should be documented clearly in the `platform-app-template` README:

```bash
# 1. Install copier
uv tool install copier

# 2. Scaffold a new app
copier copy gh:srainier/platform-app-template ../my-new-app

# 3. Answer the prompts
# app_name: my-new-app
# app_display_name: My New App
# include_frontend: yes
# include_ios: no
# github_handle: srainier
# pulumi_org: srainier

# 4. cd into the new repo and initialise git
cd ../my-new-app
git init && git add . && git commit -m "chore: scaffold from platform-app-template"

# 5. Create the GitHub repo and push
gh repo create srainier/my-new-app --private --source=. --push

# 6. Add GitHub Actions secrets (PULUMI_ACCESS_TOKEN, DIGITALOCEAN_TOKEN, etc.)
# (README lists exactly which secrets are needed)

# 7. Deploy infra
cd infra && pulumi up

# 8. Start building
cd ../backend && uvicorn app.main:app --reload
```

From scaffold to a running, deployed app: under 15 minutes.
