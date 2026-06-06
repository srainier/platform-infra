# Platform / App-owner role separation, onboarding, and docs consistency

**Date:** 2026-06-06
**Status:** Approved (design); implementation plan pending
**Repos affected:** `platform-infra`, `platform-app-template`

## Problem & context

Deploying a test app (`hello-platform`) scaffolded from `platform-app-template`
onto the shared `platform-infra` surfaced a chain of bugs and one architectural
gap. The mechanical template bugs are already fixed (platform-app-template PR #4:
public DB host + pool name, packaging, `setup-saas.sh`, integration wiring). What
remains are the **platform-level** issues, which only make sense to resolve
together with a clear model of **who owns what**:

- **#10 — Firewall clobber.** `platform-infra` manages each managed cluster's
  trusted sources with a declarative, *exclusive* `do.DatabaseFirewall`
  containing only the VPC CIDR. App Platform apps are **not** VPC members, so
  each app must be added as a trusted source. Today those are added out-of-band
  (by hand / API), which is **drift**: the next `platform-infra` `pulumi up`
  resets the firewall and locks every app out. (Two apps — `fa236109…` and
  `hello-platform` — are currently trusted only as drift.)
- **#13 — Schema grant.** On a fresh DO managed Postgres (PG15+), a per-app DB
  user has no `CREATE` on schema `public`, so the app's `create_tables()` fails
  until a `GRANT` is run as `doadmin`.
- **#11 / #12 — Private-host outputs.** `redis_url` is exported as the *private*
  URI and `postgres_host` (private) is what the README tells apps to consume —
  the same unreachable-from-App-Platform trap that cost a deploy cycle.
- **#4 — Docs.** No single place explains the credentials inventory or the
  "make the app reachable" steps; and docs assume a single all-powerful operator.

### Why role separation drives the design

The platform should support **trusted but non-admin app-owners** (the operator
and friends) who can self-serve deploy an app **without** being able to
accidentally disturb shared infra or other apps. The privileged steps an
app-owner *cannot* (and should not) perform — firewall trusted-source
registration and the `doadmin` schema grant — therefore become a **one-time
admin onboarding** per app. This is not a workaround; it is the boundary.

## Personas

| | Infra-admin | App-owner |
|---|---|---|
| Owns | `platform-infra` | their own app repo + Pulumi stack |
| Pulumi Cloud | org admin | **Admin** on own stack (auto on create) + **Read** on `platform-infra/prod` (for `StackReference`) via an `app-owners` team; no write to platform-infra |
| DigitalOcean | team Owner | custom role **`app-deployer`**: `app:*` + `database:create` + `database:read`; **no** `database:update`/`database:delete`, **no** networking/VPC write |
| Per-app duties | run `onboard-app.sh` once | scaffold, set Pulumi config, `pulumi up`, build |

**Threat model:** accidents + secret isolation among *trusted* users — not
multi-tenant isolation. App-owners must not be able to clobber the shared
firewall/clusters/VPC, and must not be able to read platform secrets (e.g. the
Postgres `doadmin` password). They are trusted not to maliciously interfere with
each other's apps (DO scopes are per-resource-*type*, not per-instance).

## Design

### 1. platform-infra: declarative trusted-app list (fixes #10)

- Add a Pulumi config list `trusted_app_ids` (App Platform app UUIDs).
- Render it into the Postgres **and** Valkey `do.DatabaseFirewall` rules
  alongside the existing `ip_addr 10.10.0.0/16` (VPC CIDR).
- Seed the list with the currently-trusted apps (`fa236109…`, `hello-platform`)
  so reconciliation does not lock them out.
- Result: trusted sources are declarative, auditable in config, and never
  clobbered.

### 2. platform-infra: outputs hygiene (fixes #11, #12, secret isolation)

- **Remove** `postgres_admin_password` from stack outputs. The onboarding script
  reads `doadmin` creds directly from the DO API. (App-owners have Read on the
  stack, so no secret may be exported.)
- Export a **public** Redis connection string (e.g. keep `redis_url` but set it
  to the cluster's public URI; or add `redis_url_public` and deprecate the
  private one). App Platform cannot reach the private Valkey host.
- Audit all other outputs: anything an app consumes for App Platform
  connectivity must be the **public** host. Update the README "How App Repos
  Consume Outputs" example accordingly (it currently shows private `postgres_host`).

> Open implementation detail: confirm whether any current consumer relies on the
> private `postgres_host`/`postgres_connection_pool_host` outputs before changing
> them; prefer adding public variants over breaking names if unsure.

### 3. platform-infra: `scripts/onboard-app.sh <app-name>` (fixes #13, operationalizes #10)

Admin-run, **idempotent**, runs *after* the app-owner's first `pulumi up`
(so the App resource and `<app>_user` exist):

1. Resolve the app's UUID from its name via the DO API.
2. Add it to the trusted list (skip if present): Pulumi has no append-path
   syntax, so compute the next index from the current list and set that element
   explicitly — `pulumi config set --path 'trusted_app_ids[<n>]' <uuid> --stack
   prod` (path and value as separate args) — then `pulumi up --stack prod`.
3. Schema grant: fetch `doadmin` creds from the DO API; temporarily add the
   admin's public IP as a trusted source (direct API, between Pulumi runs);
   `psql` → `GRANT USAGE, CREATE ON SCHEMA public TO <app>_user`; remove the
   admin IP.

Requirements: `DIGITALOCEAN_TOKEN` (admin, write), `psql`, Pulumi login. The
script prints what it did and is safe to re-run.

### 4. Documentation (fixes #4) + full consistency audit

**New / updated docs:**

- **`platform-infra/README.md`**
  - "Onboarding a new app (admin)" — prereqs, `onboard-app.sh` usage, when to run.
  - "Granting a new app-owner" — durable, click-by-click steps to (a) add the
    user to the Pulumi `app-owners` team with Read on `platform-infra/prod`, and
    (b) create the DO `app-deployer` custom role and issue the user a scoped
    token. Written to be followable long after this session.
  - "Platform-wide credentials" — what the admin holds vs. what is per-app.
  - Fix the "consume outputs" example to use public hosts.
- **Generated app README (`platform-app-template/template/README.md.jinja`)**
  - App-owner self-serve runbook: scaffold → set Pulumi config secrets +
    `clerk_publishable_key` → `pulumi up` → **"ask your platform admin to onboard
    this app (one-time)"** → redeploy → verify.
  - Per-app credentials inventory (table: secret → where it lives → scope).
  - Manual steps: create the Flagsmith flag; use Clerk **Development** keys.
- Cross-link the two READMEs.

**Consistency audit (required):** re-read and reconcile every existing doc in
both repos against the two-persona model — remove/repair any text that assumes a
single all-powerful operator or that apps freely modify shared infra:

- `platform-infra/README.md`
- `platform-infra/scripts/setup-saas.md`
- `platform-infra/docs/plans/2026-04-13_platform-infra-brief.md`
- `platform-infra/docs/plans/2026-04-13_platform-infra-phase-1-plan.md`
- `platform-app-template/README.md`
- `platform-app-template/template/README.md.jinja`
- `platform-app-template/docs/plans/2026-04-13_*.md`

(`docs/plans/*` are historical; if they shouldn't be rewritten, add a dated note
pointing to this spec rather than editing history. Decide per-file during impl.)

## Onboarding flow (end to end)

1. Admin grants the app-owner once (Pulumi team + DO token) — see admin docs.
2. App-owner scaffolds from the template, creates GitHub repo, sets Pulumi
   config secrets + `clerk_publishable_key`.
3. App-owner `pulumi up` — creates the app + per-app db/user/pool. First deploy
   may fail to connect (not yet a trusted source / no schema grant).
4. Admin runs `onboard-app.sh <app-name>` once.
5. App redeploys (deploy-on-push or manual) → live.
6. App-owner creates the Flagsmith flag and verifies.

## Non-goals / out of scope

- Multi-tenant (untrusted) isolation; per-owner DO teams or sub-accounts.
- Automating app-owner grant creation (done by hand via dashboards, documented).
- Per-instance DO resource scoping (DO scopes are per-type).
- Changes to the already-merged template app/infra fixes (PR #4).

## Verification

- `platform-infra` renders/`pulumi preview` cleanly with `trusted_app_ids`
  populated; firewall shows VPC CIDR + each app; no `postgres_admin_password`
  in `pulumi stack output`.
- `onboard-app.sh` run against `hello-platform` is a no-op (already trusted +
  granted) and exits 0 — proving idempotency.
- A docs read-through: an app-owner can follow the generated README end-to-end;
  an admin can follow the onboarding + grant docs cold.

## Open questions for plan stage

- Exact output rename strategy for redis/postgres (new public outputs vs.
  in-place change) pending a check for existing consumers.
- Whether to rewrite or annotate the historical `docs/plans/*` files.
