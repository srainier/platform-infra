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
