#!/usr/bin/env bash
# cn-dnsdhcpd — idempotent Technitium config applier ("config as code").
#
# Reads knobs from .env and the inventory from dns/zones.tsv + dns/records.tsv
# and applies them via the HTTP API. Safe to re-run any time:
#   - settings are set to exactly what the knobs say (owned params only)
#   - existing zones are skipped ("already exists"); a TYPE mismatch between
#     the TSV and the live zone warns — or converts in place when the run is
#     invoked as DNS_ALLOW_ZONE_CONVERT=true ./seed-dns.sh (records survive)
#   - records are applied with overwrite=true (the TSV replaces the RRset)
#   - the pfSense DDNS TSIG key + per-zone RFC 2136 update policies are
#     (re)applied when DDNS_TSIG_KEY_NAME/SECRET are set in .env
#
# Re-run after changing DNS_UPSTREAM_MODE / DNS_DNSSEC / DNS_BLOCKING or the
# TSVs. Forwarder-TARGET changes on an existing Forwarder zone are NOT
# automated: delete the zone in the UI and re-run (see README).
set -euo pipefail

cd "$(dirname "$0")"

log() { printf '\033[1;36m[seed]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

env_get() { grep -E "^${1}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }

[[ -f .env ]] || die ".env not found. Run: kauket get pki.cn_dnsdhcpd_env"

BASE="${TECHNITIUM_URL:-http://127.0.0.1:5380}"
TOKEN="$(env_get TECHNITIUM_API_TOKEN)"
[[ -n "$TOKEN" ]] || die "TECHNITIUM_API_TOKEN empty — run ./setup.sh first"

# api_raw <path> [curl args…] → prints response JSON, never dies on API error
api_raw() {
  local path="$1"; shift
  curl -sf -m 30 --get --data-urlencode "token=${TOKEN}" "$@" "${BASE}/api/${path}" \
    || die "HTTP call failed: ${path}"
}

# api <path> [curl args…] → prints response, dies unless status ok
api() {
  local resp
  resp=$(api_raw "$@")
  grep -q '"status": *"ok"' <<<"$resp" || die "API error on $1: $resp"
  printf '%s' "$resp"
}

# ── 1. settings ──────────────────────────────────────────────────────────────

MODE="$(env_get DNS_UPSTREAM_MODE)";  MODE="${MODE:-recursion}"
DNSSEC="$(env_get DNS_DNSSEC)";       DNSSEC="${DNSSEC:-false}"
BLOCKING="$(env_get DNS_BLOCKING)";   BLOCKING="${BLOCKING:-false}"

args=(
  --data-urlencode "recursion=UseSpecifiedNetworkACL"
  --data-urlencode "recursionNetworkACL=127.0.0.0/8,10.0.0.0/8"
  --data-urlencode "dnssecValidation=${DNSSEC}"
  --data-urlencode "loggingType=FileAndConsole"
  --data-urlencode "logQueries=false"
  --data-urlencode "maxLogFileDays=7"
  --data-urlencode "enableBlocking=${BLOCKING}"
)
if [[ "$MODE" == "forwarders" ]]; then
  FWDS="$(env_get DNS_FORWARDERS)"
  [[ -n "$FWDS" ]] || die "DNS_UPSTREAM_MODE=forwarders but DNS_FORWARDERS is empty"
  args+=(
    --data-urlencode "forwarders=${FWDS}"
    --data-urlencode "forwarderProtocol=Https"
    --data-urlencode "concurrentForwarding=true"
  )
else
  args+=( --data-urlencode "forwarders=false" )
fi
if [[ "$BLOCKING" == "true" ]]; then
  BLU="$(env_get BLOCKLIST_URLS)"
  [[ -n "$BLU" ]] || die "DNS_BLOCKING=true but BLOCKLIST_URLS is empty"
  args+=(
    --data-urlencode "blockListUrls=${BLU}"
    --data-urlencode "blockingType=NxDomain"
  )
else
  args+=( --data-urlencode "blockListUrls=false" )
fi

# pfSense DDNS TSIG key (RFC 2136). tsigKeys is a full-list overwrite — this
# repo owns the list.
TSIG_NAME="$(env_get DDNS_TSIG_KEY_NAME)"
TSIG_SECRET="$(env_get DDNS_TSIG_KEY_SECRET)"
if [[ -n "$TSIG_NAME" && -n "$TSIG_SECRET" ]]; then
  args+=( --data-urlencode "tsigKeys=${TSIG_NAME}|${TSIG_SECRET}|hmac-sha256" )
fi

log "applying settings (mode=${MODE} dnssec=${DNSSEC} blocking=${BLOCKING} tsig=${TSIG_NAME:-none})"
api settings/set "${args[@]}" >/dev/null

# ── 1b. Authentik SSO (OIDC) for the web console ─────────────────────────────

SSO_ID="$(env_get SSO_CLIENT_ID)"
SSO_SECRET="$(env_get SSO_CLIENT_SECRET)"
if [[ -n "$SSO_ID" && -n "$SSO_SECRET" ]]; then
  SSO_AUTH="$(env_get SSO_AUTHORITY)"
  api admin/sso/set \
    --data-urlencode "ssoEnabled=true" \
    --data-urlencode "ssoAuthority=${SSO_AUTH}" \
    --data-urlencode "ssoClientId=${SSO_ID}" \
    --data-urlencode "ssoClientSecret=${SSO_SECRET}" \
    --data-urlencode "ssoScopes=openid,profile,email,groups" \
    --data-urlencode "ssoAllowSignup=true" \
    --data-urlencode "ssoAllowSignupOnlyForMappedUsers=true" \
    --data-urlencode "ssoGroupMap=$(env_get SSO_GROUP_MAP)" >/dev/null
  log "SSO enabled (authority=${SSO_AUTH})"
else
  log "SSO_CLIENT_ID/SECRET not set — SSO left untouched"
fi

# ── 2. Query Logs (Sqlite) app ───────────────────────────────────────────────

APP_NAME="Query Logs (Sqlite)"

if ! api apps/list | python3 -c '
import json,sys
d=json.load(sys.stdin)
apps=[a["name"] for a in d["response"].get("apps",[])]
sys.exit(0 if "'"$APP_NAME"'" in apps else 1)
'; then
  log "installing app: ${APP_NAME}"
  APP_URL=$(api apps/listStoreApps | python3 -c '
import json,sys
d=json.load(sys.stdin)
for a in d["response"].get("storeApps",[]):
    if a["name"] == "'"$APP_NAME"'":
        print(a["url"]); break
')
  [[ -n "$APP_URL" ]] || die "could not find '${APP_NAME}' in the app store listing"
  api apps/downloadAndInstall \
    --data-urlencode "name=${APP_NAME}" \
    --data-urlencode "url=${APP_URL}" >/dev/null
else
  log "app already installed: ${APP_NAME}"
fi

# keep default 7d/10k retention, but make cleanup actually reclaim disk
NEWCFG=$(api apps/config/get --data-urlencode "name=${APP_NAME}" | python3 -c '
import json,sys
d=json.load(sys.stdin)
cfg=json.loads(d["response"].get("config") or "{}")
cfg["enableVacuum"]=True
print(json.dumps(cfg))
')
api apps/config/set \
  --data-urlencode "name=${APP_NAME}" \
  --data-urlencode "config=${NEWCFG}" >/dev/null
log "app config applied (enableVacuum=true)"

# ── 3. k8s_gateway live check (.200 per pfSense export, .210 per amun-k8s) ──

k8s_alive() {
  api_raw dnsClient/resolve \
    --data-urlencode "server=${1}" \
    --data-urlencode "domain=k8s.lan" \
    --data-urlencode "type=SOA" 2>/dev/null \
    | grep -q '"RCODE": *"NoError"'
}

K8S_GW="10.0.0.200"
if k8s_alive "$K8S_GW"; then
  log "k8s_gateway answering at ${K8S_GW}"
elif k8s_alive "10.0.0.210"; then
  K8S_GW="10.0.0.210"
  warn "k8s_gateway NOT at 10.0.0.200 but answering at 10.0.0.210 — using it; update dns/zones.tsv"
else
  warn "k8s_gateway answered at neither 10.0.0.200 nor 10.0.0.210 — keeping the TSV value; k8s.lan will not resolve until this is fixed"
fi

# ── 4. zones (create; convert type mismatches when allowed) ─────────────────

LIVE_TYPES=$(api zones/list --data-urlencode "zonesPerPage=500" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for z in d["response"].get("zones",[]):
    print(z["name"] + "\t" + z["type"])
')

live_type() { awk -F'\t' -v z="$1" '$1==z {print $2}' <<<"$LIVE_TYPES"; }

ALLOW_CONVERT="${DNS_ALLOW_ZONE_CONVERT:-false}"
created=0 skipped=0 converted=0
while IFS=$'\t' read -r zone ztype fwd _comment; do
  [[ -z "$zone" || "$zone" == \#* ]] && continue
  lt="$(live_type "$zone")"
  if [[ -n "$lt" ]]; then
    if [[ "$lt" != "$ztype" ]]; then
      if [[ "$ALLOW_CONVERT" == "true" ]]; then
        api zones/convert \
          --data-urlencode "zone=${zone}" \
          --data-urlencode "type=${ztype}" >/dev/null
        log "zone CONVERTED: ${zone} (${lt} -> ${ztype}; records kept)"
        converted=$((converted+1))
      else
        warn "zone TYPE MISMATCH: ${zone} is ${lt}, TSV says ${ztype} — re-run with DNS_ALLOW_ZONE_CONVERT=true to convert"
      fi
    else
      skipped=$((skipped+1))
    fi
    continue
  fi
  zargs=( --data-urlencode "zone=${zone}" --data-urlencode "type=${ztype}" )
  if [[ "$ztype" == "Forwarder" ]]; then
    [[ "$zone" == "k8s.lan" ]] && fwd="$K8S_GW"
    zargs+=(
      --data-urlencode "forwarder=${fwd}"
      --data-urlencode "protocol=Udp"
      --data-urlencode "dnssecValidation=false"
      --data-urlencode "proxyType=NoProxy"
    )
  fi
  api zones/create "${zargs[@]}" >/dev/null
  log "zone created: ${zone} (${ztype}${fwd:+ -> $fwd})"
  created=$((created+1))
done < dns/zones.tsv

# ── 5. RFC 2136 update policies for the pfSense-DDNS zones ──────────────────
# update ACL restricts sources to pfSense; the TSIG security policy restricts
# what a signed update may touch. Both re-applied on every run.

DDNS_ZONES=(lan 0.0.10.in-addr.arpa 1.10.in-addr.arpa 2.10.in-addr.arpa 111.10.in-addr.arpa 166.10.in-addr.arpa 120.10.in-addr.arpa)
DDNS_TYPES="A,AAAA,PTR,TXT,DHCID"

if [[ -n "$TSIG_NAME" && -n "$TSIG_SECRET" ]]; then
  for z in "${DDNS_ZONES[@]}"; do
    api zones/options/set \
      --data-urlencode "zone=${z}" \
      --data-urlencode "update=UseSpecifiedNetworkACL" \
      --data-urlencode "updateNetworkACL=10.0.0.1,10.1.0.1,10.2.0.1,10.111.0.1,10.166.0.1,10.120.0.1" \
      --data-urlencode "updateSecurityPolicies=${TSIG_NAME}|${z}|${DDNS_TYPES}|${TSIG_NAME}|*.${z}|${DDNS_TYPES}" >/dev/null
  done
  log "RFC 2136 update policies applied to ${#DDNS_ZONES[@]} zones (key=${TSIG_NAME})"
else
  warn "DDNS_TSIG_KEY_NAME/SECRET not set — skipping RFC 2136 update policies (pfSense DDNS will be rejected)"
fi

# ── 6. records ───────────────────────────────────────────────────────────────

records=0
while IFS=$'\t' read -r zone domain rtype value ttl ptr; do
  [[ -z "$zone" || "$zone" == \#* ]] && continue
  [[ "$rtype" == "A" ]] || die "records.tsv: unsupported type '${rtype}' for ${domain} (extend seed-dns.sh first)"
  rargs=(
    --data-urlencode "domain=${domain}"
    --data-urlencode "zone=${zone}"
    --data-urlencode "type=A"
    --data-urlencode "ipAddress=${value}"
    --data-urlencode "ttl=${ttl}"
    --data-urlencode "overwrite=true"
  )
  if [[ "${ptr:-false}" == "true" ]]; then
    rargs+=( --data-urlencode "ptr=true" --data-urlencode "createPtrZone=false" )
  fi
  api zones/records/add "${rargs[@]}" >/dev/null
  records=$((records+1))
done < dns/records.tsv

log "done: ${created} zones created, ${converted} converted, ${skipped} already present, ${records} records applied"
