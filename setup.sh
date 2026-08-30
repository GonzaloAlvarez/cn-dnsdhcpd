#!/usr/bin/env bash
# cn-dnsdhcpd — idempotent bring-up.
#
# The .env is Kauket-managed (secret id pki.cn_dnsdhcpd_env). This script
# renders the admin-password secret file, brings the stack up, mints the
# non-expiring API token on first run (tokenName "automation"), and applies
# the config-as-code inventory via ./seed-dns.sh.
#
#   kauket get pki.cn_dnsdhcpd_env   # installs .env (0600)
#   ./setup.sh
set -euo pipefail

cd "$(dirname "$0")"

case "${1:-}" in
  -h|--help)
    sed -n '/^#!/d; /^[^#]/q; s/^# \{0,1\}//p' "$0"
    exit 0
    ;;
  "") ;;
  *)
    echo "unknown argument: $1 (try --help)" >&2
    exit 2
    ;;
esac

# ── helpers ────────────────────────────────────────────────────────────────

log() { printf '\n\033[1;36m[setup]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

env_get()  { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }
env_set()  {
  local k="$1" v="$2"
  local esc
  esc=$(printf '%s\n' "$v" | sed -e 's/[\/&]/\\&/g')
  if grep -qE "^${k}=" .env; then
    sed -i.bak "s/^${k}=.*/${k}=${esc}/" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
}

[[ -f .env ]] || die ".env not found. Run: kauket get pki.cn_dnsdhcpd_env"

BASE="http://127.0.0.1:5380"

# ── dirs + admin password secret file ───────────────────────────────────────

mkdir -p config backups secrets
# placeholder so the metrics-exporter bind mount never materializes as a dir
[[ -f secrets/api_token.txt ]] || ( umask 077; printf '' > secrets/api_token.txt )

ADMIN_PW="$(env_get DNS_ADMIN_PASSWORD)"
[[ -n "$ADMIN_PW" ]] || die "DNS_ADMIN_PASSWORD is empty in the Kauket-managed .env"

if [[ ! -f secrets/admin_password.txt ]] || [[ "$(cat secrets/admin_password.txt)" != "$ADMIN_PW" ]]; then
  ( umask 077; printf '%s' "$ADMIN_PW" > secrets/admin_password.txt )
  log "rendered secrets/admin_password.txt (first-boot seed; post-boot source of truth is Technitium's own config)"
fi

# ── port preflight ───────────────────────────────────────────────────────────
# :53 must be free or already ours. Known-clean on pki (no systemd-resolved/
# dnsmasq) — this guards future drift.

if ss -H -lun 'sport = :53' 2>/dev/null | grep -q . ; then
  if [[ -z "$(docker compose ps -q technitium 2>/dev/null)" ]]; then
    die "something already listens on 53/udp and it isn't this stack: $(ss -H -lun 'sport = :53')"
  fi
fi

# ── bring the stack up ───────────────────────────────────────────────────────

log "docker compose up -d --remove-orphans"
docker compose up -d --remove-orphans

log "waiting for the Technitium API on ${BASE} (up to 2m)"
for i in $(seq 1 24); do
  if curl -sf -m 5 "${BASE}/api/status" >/dev/null 2>&1; then
    log "API reachable after ${i}x5s"
    break
  fi
  sleep 5
  [[ $i -eq 24 ]] && die "API never came up — check 'docker compose logs technitium'"
done

# ── API token bootstrap (idempotent) ────────────────────────────────────────

TOKEN="$(env_get TECHNITIUM_API_TOKEN)"
TOKEN_MINTED=""

token_valid() {
  curl -sf -m 5 --get --data-urlencode "token=$1" "${BASE}/api/settings/get" 2>/dev/null \
    | grep -q '"status": *"ok"'
}

if [[ -n "$TOKEN" ]] && token_valid "$TOKEN"; then
  log "TECHNITIUM_API_TOKEN already valid — skipping token mint"
else
  log "minting non-expiring API token (tokenName=automation)"
  RESP=$(curl -sf --get \
    --data-urlencode "user=admin" \
    --data-urlencode "pass=${ADMIN_PW}" \
    --data-urlencode "tokenName=automation" \
    "${BASE}/api/user/createToken") \
    || die "createToken call failed — is DNS_ADMIN_PASSWORD correct? (post-first-boot, Technitium's stored password is authoritative)"
  TOKEN=$(printf '%s' "$RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("token","")) if d.get("status")=="ok" else sys.exit(1)') \
    || die "createToken returned an error: $RESP"
  env_set TECHNITIUM_API_TOKEN "$TOKEN"
  TOKEN_MINTED=1
  log "token minted and written to .env"
  log "recreating backup-dump so it picks up the token"
  docker compose up -d backup-dump
fi

# ── API token file for metrics-exporter (json_exporter Bearer creds) ────────

if [[ "$(cat secrets/api_token.txt 2>/dev/null)" != "$TOKEN" ]]; then
  ( umask 077; printf '%s' "$TOKEN" > secrets/api_token.txt )
  log "rendered secrets/api_token.txt; recreating metrics-exporter"
  docker compose up -d --force-recreate metrics-exporter
fi

# ── seed the DNS configuration ───────────────────────────────────────────────

./seed-dns.sh

# ── summary ──────────────────────────────────────────────────────────────────

cat <<EOF


===============================================================
cn-dnsdhcpd stack is up.

  Web UI  :  https://dns.pki.lan          (cn-pki traefik, step-ca cert)
  Break-glass:  http://pki.lan:5380       (direct, plain HTTP)
  Resolver:  10.0.0.250:53 (udp+tcp)

  Smoke test:
    dig @10.0.0.250 google.com +short
    dig @10.0.0.250 auth.lab.gn.al +short   # expect 10.1.1.92

  Full verification battery: see README.md.
EOF

if [[ -n "$TOKEN_MINTED" ]]; then
  cat <<'EOF'

  ⚠  A NEW API token was minted and written ONLY to the local .env.
     Kauket is the source of truth — round-trip it NOW (on the Mac):
       1. kauket get pki.cn_dnsdhcpd_env into a temp file
       2. set TECHNITIUM_API_TOKEN=<value from this host's .env>
       3. kauket add pki.cn_dnsdhcpd_env <file> --dest /home/gonzalo/cn-dnsdhcpd/.env --mode 0600 --profile host.pki --force
       4. back here: kauket get pki.cn_dnsdhcpd_env  (must not clobber the token)
EOF
fi

cat <<'EOF'
  The .env (admin password, API token, backup + SMTP creds) is
  Kauket-managed (pki.cn_dnsdhcpd_env).
===============================================================
EOF
