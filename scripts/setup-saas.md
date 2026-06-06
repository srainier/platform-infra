# SaaS Service Setup Checklist

This checklist covers one-time account-level setup for each SaaS service used across the platform. Per-app configuration (Clerk Applications, Flagsmith Projects, Sentry Projects, Honeycomb Datasets) is handled inside each app repo.

---

## Pulumi Cloud

**Purpose:** State backend for all Pulumi stacks (platform-infra and per-app stacks).

**One-time setup:**
- [ ] Create account at https://app.pulumi.com (free tier)
- [ ] Note your org name — used in Stack Reference paths (`srainier/platform-infra/prod`)
- [ ] Generate a personal access token: Account → Access Tokens

**Credential ownership — two roles, two tokens:**

| Token | Owner | Used in |
|---|---|---|
| `PULUMI_ACCESS_TOKEN` (admin, org-admin scope) | **Infra-admin** | this repo (`platform-infra`) CI/CD |
| `PULUMI_ACCESS_TOKEN` (app-owner's own token) | **App-owner** | their app repo CI/CD |

App-owners generate their own Pulumi access token and store it as a GitHub Actions
secret in their app repo. They do **not** use the admin token. See README →
"Granting a new app-owner" for how to give an app-owner Read access to the
`platform-infra/prod` stack outputs.

**Where to store (infra-admin):**
| Secret | Location |
|---|---|
| `PULUMI_ACCESS_TOKEN` | GitHub Actions Secret (this repo only) |

---

## DigitalOcean

**Purpose:** Cloud provider for all managed infrastructure (Postgres, Valkey, VPC, etc.).

**One-time setup (infra-admin):**
- [ ] Create account at https://cloud.digitalocean.com
- [ ] Generate a personal access token with read + write scope: API → Tokens
- [ ] Ensure your account has enough quota for managed databases

**Credential ownership — two roles, two tokens:**

The `DIGITALOCEAN_TOKEN` for **this repo** (`platform-infra`) is the
**infra-admin's** token (full write scope — manages clusters, firewalls, VPC).
App repos use a **separate, scoped token** issued to each app-owner via the
`app-deployer` custom role (App Platform + database create/read only; no
firewall or cluster write access). App-owners must **not** use the admin token.
See README → "Granting a new app-owner" for click-by-click setup.

**Where to store (infra-admin):**
| Secret | Location |
|---|---|
| `DIGITALOCEAN_TOKEN` (admin, write scope) | GitHub Actions Secret (this repo only) |

---

## Clerk

**Purpose:** Authentication and user management.

**One-time setup:**
- [ ] Create account at https://clerk.com
- [ ] No top-level Pulumi resources needed here — Clerk is configured per-app

**Per-app (done in each app repo):**
- Create a Clerk Application for each app (dev + prod environments)
- Store `CLERK_SECRET_KEY` and `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` in app repo secrets

---

## Flagsmith

**Purpose:** Feature flags.

**One-time setup:**
- [ ] Create account at https://flagsmith.com (free tier available)
- [ ] No top-level Pulumi resources needed — Flagsmith is configured per-app

**Per-app (done in each app repo):**
- Create a Flagsmith Project for each app
- Store `FLAGSMITH_ENVIRONMENT_KEY` in app repo secrets

---

## Honeycomb

**Purpose:** Observability and distributed tracing.

**One-time setup:**
- [ ] Create account at https://honeycomb.io (free tier available)
- [ ] Generate an API key for your team: Team Settings → API Keys

**Where to store:**
| Secret | Location |
|---|---|
| `HONEYCOMB_API_KEY` | GitHub Actions Secret (each app repo) |

**Per-app (done in each app repo):**
- Create a Honeycomb Dataset per app (or use auto-creation)

---

## Sentry

**Purpose:** Error tracking and performance monitoring.

**One-time setup:**
- [ ] Create account at https://sentry.io (free tier available)
- [ ] Create a Sentry Organization

**Per-app (done in each app repo):**
- Create a Sentry Project for each app
- Store `SENTRY_DSN` and `SENTRY_AUTH_TOKEN` in app repo secrets

---

## GitHub Actions Secrets Summary

Secrets required in **this repo** (`platform-infra`) — held by the **infra-admin**:

| Secret | Description |
|---|---|
| `PULUMI_ACCESS_TOKEN` | Pulumi Cloud access token (admin) |
| `DIGITALOCEAN_TOKEN` | DigitalOcean API token (admin, write scope) |

App repos use the **app-owner's** own tokens (scoped `app-deployer` DO token +
their personal Pulumi access token). They do **not** use the admin tokens above.

> Secrets are set at: GitHub repo → Settings → Secrets and variables → Actions
