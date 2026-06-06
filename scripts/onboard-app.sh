#!/usr/bin/env bash
# Onboard a per-app deployment to the shared platform clusters.
#
# Admin-run and idempotent. Run AFTER the app-owner's first `pulumi up`
# (the App Platform app and the <app>_user DB user must already exist).
#
# Usage:
#   DIGITALOCEAN_TOKEN=<admin write token> ./scripts/onboard-app.sh <app-name> [app-uuid]
#
# If <app-uuid> is given (or APP_ID is set in the environment) it is used
# directly instead of resolving by name — useful when names are ambiguous.
#
# What it does:
#   1. Resolve the App Platform app UUID from its name (unless one is given).
#   2. Add the UUID to platform-infra's trusted_app_ids and `pulumi up`
#      (declarative trusted source on the Postgres + Valkey firewalls).
#   3. Grant the app's DB user CREATE on schema public (PG15+ requirement),
#      connecting as doadmin over the public host with a temporary IP allowlist.
#
# IMPORTANT: this applies a production change directly (the trusted_app_ids
# config edit + `pulumi up`). The script requires a clean Pulumi.prod.yaml to
# start and, on success, tells you exactly what to commit and push so `main`
# stays in sync (see "Onboarding a new app" in README.md).
set -euo pipefail

APP_NAME="${1:?usage: onboard-app.sh <app-name> [app-uuid]}"
APP_ID="${2:-${APP_ID:-}}"
: "${DIGITALOCEAN_TOKEN:?set DIGITALOCEAN_TOKEN (admin, write scope)}"

# App names map 1:1 onto SQL identifiers below (hyphens -> underscores), and the
# derived DB user name is interpolated into a GRANT statement. Fail closed on
# anything outside the template's documented naming convention so we never build
# an unexpected identifier. Keep this regex in sync with platform-app-template.
if [[ ! "${APP_NAME}" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
  echo "ERROR: app name '${APP_NAME}' is not a valid app/db identifier." >&2
  echo "       Expected lowercase letters, digits and hyphens (e.g. hello-platform)." >&2
  exit 1
fi

DB_NAME="${APP_NAME//-/_}"
DB_USER="${DB_NAME}_user"
API="https://api.digitalocean.com/v2"
AUTH=(-H "Authorization: Bearer ${DIGITALOCEAN_TOKEN}")
cd "$(dirname "$0")/.."   # platform-infra repo root

# We will edit Pulumi.prod.yaml; require it clean so the resulting diff is
# exactly our trusted_app_ids change and easy to review/commit/push afterwards.
if ! git diff --quiet -- Pulumi.prod.yaml || ! git diff --cached --quiet -- Pulumi.prod.yaml; then
  echo "ERROR: Pulumi.prod.yaml has uncommitted changes." >&2
  echo "       Commit or stash them first so this run's config edit is isolated." >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

if [[ -z "${APP_ID}" ]]; then
  echo "==> Resolving app UUID for '${APP_NAME}'…"
  # Fail closed if zero or more than one app matches the name.
  APP_ID=$(curl -sf "${API}/apps?per_page=200" "${AUTH[@]}" | python3 -c "
import json, sys
apps = json.load(sys.stdin).get('apps', []) or []
m = [a for a in apps if a.get('spec', {}).get('name') == '${APP_NAME}']
if len(m) > 1:
    sys.stderr.write('MULTIPLE')
    sys.exit(3)
print(m[0]['id'] if m else '')") || {
    echo "ERROR: more than one App Platform app is named '${APP_NAME}'." >&2
    echo "       Re-run with the explicit UUID: onboard-app.sh '${APP_NAME}' <app-uuid>" >&2
    exit 1
  }
  if [[ -z "${APP_ID}" ]]; then
    echo "ERROR: no App Platform app named '${APP_NAME}'. Has the app-owner run 'pulumi up' yet?" >&2
    exit 1
  fi
fi
echo "    app id: ${APP_ID}"

echo "==> Resolving platform-postgres cluster id…"
PG_ID=$(curl -sf "${API}/databases?per_page=200" "${AUTH[@]}" | python3 -c "
import json, sys
dbs = json.load(sys.stdin).get('databases', []) or []
m = [d for d in dbs if d.get('name') == 'platform-postgres']
print(m[0]['id'] if m else '')")
[[ -n "${PG_ID}" ]] || { echo "ERROR: platform-postgres cluster not found" >&2; exit 1; }

echo "==> Ensuring ${APP_ID} is in trusted_app_ids (idempotent)…"
# Pulumi has no append-path syntax, so compute the next index from the current
# list and set that element explicitly (path + value as separate arguments).
read -r PRESENT NEXT_INDEX < <(pulumi config --json --stack prod 2>/dev/null | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
ids = cfg.get('platform-infra:trusted_app_ids', {}).get('objectValue') or []
print(int('${APP_ID}' in ids), len(ids))")
CONFIG_CHANGED=0
if [[ "${PRESENT}" == "1" ]]; then
  echo "    already present; skipping config change"
else
  pulumi config set --path "trusted_app_ids[${NEXT_INDEX}]" "${APP_ID}" --stack prod
  CONFIG_CHANGED=1
fi
echo "==> pulumi up (reconciling firewalls)…"
pulumi up --yes --stack prod

echo "==> Granting schema privileges to ${DB_USER}…"
read -r H P U PW < <(curl -sf "${API}/databases/${PG_ID}" "${AUTH[@]}" | python3 -c "
import json, sys
c = json.load(sys.stdin)['database']['connection']
print(c['host'], c['port'], c['user'], c['password'])")

# DO database firewalls (and the psql connection below) require an IPv4 source.
# On dual-stack networks a plain `curl ifconfig.me` may return an IPv6 address,
# which the firewall API silently rejects — force IPv4.
MYIP=$(curl -4 -sf https://ifconfig.me) || {
  echo "ERROR: could not determine an IPv4 address (curl -4 failed)." >&2
  echo "       DO database firewalls require IPv4; this host appears IPv6-only." >&2
  exit 1
}
echo "    temporarily trusting admin IP ${MYIP}…"
curl -sf "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" -o "${WORKDIR}/fw.json"
python3 -c "
import json
fw = json.load(open('${WORKDIR}/fw.json'))
rules = [{'type': r['type'], 'value': r['value']} for r in fw.get('rules', [])]
ip = '${MYIP}'
if not any(r['type'] == 'ip_addr' and r['value'] == ip for r in rules):
    rules.append({'type': 'ip_addr', 'value': ip})
json.dump({'rules': rules}, open('${WORKDIR}/fw_put.json', 'w'))
"
curl -sf -X PUT "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" \
  -H "Content-Type: application/json" --data @"${WORKDIR}/fw_put.json"

# From here the admin IP is trusted. Ensure it is removed on ANY exit (success,
# error, or Ctrl-C) so a failure mid-grant never leaves the firewall open.
remove_admin_ip() {
  echo "    removing admin IP ${MYIP} (preserving pulumi-managed rules)…"
  # Re-fetch so we keep the app rules pulumi just reconciled, and drop only our IP.
  curl -sf "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" -o "${WORKDIR}/fw2.json" || return 0
  python3 -c "
import json
fw = json.load(open('${WORKDIR}/fw2.json'))
rules = [
    {'type': r['type'], 'value': r['value']}
    for r in fw.get('rules', [])
    if not (r['type'] == 'ip_addr' and r['value'] == '${MYIP}')
]
json.dump({'rules': rules}, open('${WORKDIR}/fw_clean.json', 'w'))
" || return 0
  curl -sf -X PUT "${API}/databases/${PG_ID}/firewall" "${AUTH[@]}" \
    -H "Content-Type: application/json" --data @"${WORKDIR}/fw_clean.json" || true
}
trap 'remove_admin_ip; rm -rf "${WORKDIR}"' EXIT

# DO trusted-source changes are not instant — a fixed sleep races propagation.
# Poll the cluster (as doadmin) until it accepts our newly-trusted IP, up to ~2m.
echo "    waiting for the firewall change to take effect (up to ~5m)…"
reachable=0
for i in $(seq 1 30); do
  if PGPASSWORD="${PW}" psql \
       "host=${H} port=${P} dbname=${DB_NAME} user=${U} sslmode=require connect_timeout=5" \
       -tAc 'select 1' >/dev/null 2>&1; then
    reachable=1
    break
  fi
  echo "      still waiting (~$((i * 10))s)…"
  sleep 5
done
if [[ "${reachable}" != "1" ]]; then
  echo "ERROR: ${H}:${P} unreachable after ~5m even with ${MYIP} trusted." >&2
  echo "       Outbound ${P} is open, so this usually means the egress IP changed" >&2
  echo "       mid-run (don't switch networks/VPN during onboarding) or DO propagation" >&2
  echo "       stalled. Re-run on a single stable network; if it persists, run from a" >&2
  echo "       DO droplet/cloud shell where the egress IP is unambiguous." >&2
  exit 1
fi

PGPASSWORD="${PW}" psql \
  "host=${H} port=${P} dbname=${DB_NAME} user=${U} sslmode=require connect_timeout=20" \
  -v ON_ERROR_STOP=1 \
  -c "GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};"

echo "==> Done. '${APP_NAME}' is a trusted source and ${DB_USER} can create tables."
if [[ "${CONFIG_CHANGED}" == "1" ]]; then
  echo
  echo "    IMPORTANT: this run edited Pulumi.prod.yaml and applied it directly."
  echo "    Commit and push that change NOW so 'main' matches production and the"
  echo "    next CI 'pulumi up' does not drop '${APP_NAME}' from the firewalls:"
  echo
  echo "        git add Pulumi.prod.yaml"
  echo "        git commit -m 'chore: trust ${APP_NAME} (${APP_ID}) on shared clusters'"
  echo "        git push"
fi
echo "    Trigger a redeploy if the first deploy failed before onboarding."
