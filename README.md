# cn-dnsdhcpd

[Technitium DNS Server](https://technitium.com/dns/) 15.4 on **pki.lan**
(10.0.0.250) — the client-facing LAN resolver, replacing pfSense Unbound.

**Division of labor**: pfSense keeps DHCP; every lease event pushes the
hostname's A + PTR records straight into Technitium via **RFC 2136 dynamic
updates (TSIG-signed)**, and DHCP hands clients `10.0.0.250` as their DNS
server. The `lan` zone and six per-VLAN reverse zones are Primary zones here;
all pfSense static mappings and the load-bearing infrastructure hosts are
additionally pinned as static records (`dns/records.tsv`), so nothing depends
on a lease renewal to resolve. pfSense Unbound stays enabled only for the
router's own resolution — it is out of the client path entirely.
Phase 2 (optional, runbook b) would move DHCP itself here via pfSense DHCP
Relay.

Tailnet DNS (VPS CoreDNS for `*.lab.gn.al`, MagicDNS for `*.ts.gn.al`) is
**not** touched by this stack. This is a LAN-only service by design: no
headscale ACL permits tailnet clients to reach 10.0.0.250:53. (Moving off
10.0.0.192 in 2026-08 took pki out of the k8s MetalLB /27 shadow, so the
host itself is now tailnet-routable again via infra-exit — the old
`tag:devbox → 10.0.0.192:80,443` ACL rule needs updating to .250 before
devboxes can use step-ca.)

## Services

| Service | Purpose |
|---|---|
| `technitium` | `technitium/dns-server:15.4.0` (pinned), `network_mode: host`. DNS on 53/udp+tcp, web console/API on 5380 (bound to 10.0.0.250 + 127.0.0.1). Excluded from cn-pki's host-wide watchtower (deliberate upgrades only). |
| `backup-dump` | Long-running loop fetching a daily `settings/backup` API zip (settings, zones, apps, auth, DHCP scopes) into `./backups/`, pruned at 14 days. Long-running on purpose — a one-shot would be restart-looped by the amun-docker reconcile cron. |
| `backup` | offen → S3 `cloudnet-lab-storage/dnsdhcpd/` + raidnas WebDAV `/dnsdhcpd/`, Sundays 02:00, 56-day retention, SMTP notify. Tars `./config` (live state) + `./backups` (the authoritative restore artifacts). |

Deliberately absent: watchtower, node-exporter, promtail, consul-register —
cn-pki already runs host-wide watchtower/promtail/node-exporter on this box,
and there is no tailnet surface. Logs land in kaiser Loki via cn-pki's
promtail: query `{project="cn-dnsdhcpd"}` (the `stack` label says `cn-pki`;
known cosmetic wart).

## Web UI

- **`https://dns.pki.lan`** — routed by cn-pki's traefik (file provider →
  `http://10.0.0.250:5380`), step-ca leaf, auto-renewed.
- **`http://pki.lan:5380`** — break-glass direct access (plain HTTP).

## Bring-up

**UFW prerequisite** (one-time, done 2026-08-30): pki runs ufw default-deny.
Docker-proxied ports (cn-pki 80/443/9000) bypass it via the DOCKER iptables
chain, but host-networked services do NOT — Technitium needs:

```sh
sudo ufw allow proto udp from any to any port 53 comment 'cn-dnsdhcpd Technitium DNS'
sudo ufw allow proto tcp from any to any port 53 comment 'cn-dnsdhcpd Technitium DNS'
sudo ufw allow proto tcp from 10.0.0.0/8 to any port 5380 comment 'cn-dnsdhcpd console break-glass (LAN)'
sudo ufw allow proto tcp from 172.16.0.0/12 to any port 5380 comment 'cn-dnsdhcpd console via docker bridges (subnet shifts on reboot)'
sudo ufw allow proto tcp from 10.1.1.140 to any port 7979 comment 'cn-dnsdhcpd json_exporter scraped by kaiser prometheus'
```

(The docker-bridge rule is deliberately the whole 172.16.0.0/12: bridge
subnets are assigned by network-creation order and CHANGE across reboots —
a /16-scoped rule broke the dns.pki.lan route after the first reboot.
Phase 2 DHCP needs 67/udp opened too — see runbook b.)

```sh
git clone git@github.com:GonzaloAlvarez/cn-dnsdhcpd.git ~/cn-dnsdhcpd
cd ~/cn-dnsdhcpd
kauket get pki.cn_dnsdhcpd_env   # installs .env (0600)
./setup.sh
```

The clone authenticates with pki's `~/.ssh/id_ed25519`, registered as a
read-only GitHub deploy key on this repo (pki has no account-level GitHub
credentials).

`setup.sh` renders the admin-password secret file, brings the stack up, mints
the non-expiring API token on first run, and applies `seed-dns.sh`.

### Token round-trip (first run only)

The token is minted on the host and written only to the local `.env`. Kauket
is the source of truth — persist it back or the next `kauket get` clobbers it:

1. On the Mac: fetch the current env content, fill `TECHNITIUM_API_TOKEN=`
   with the value from pki's `.env`.
2. `kauket add pki.cn_dnsdhcpd_env <file> --dest /home/gonzalo/cn-dnsdhcpd/.env --mode 0600 --profile host.pki --force`
3. On pki: `kauket get pki.cn_dnsdhcpd_env` and confirm the token survived.

## Config as code

All DNS configuration is applied by `./seed-dns.sh` (idempotent, re-run any
time) from:

- **`.env` knobs** — `DNS_UPSTREAM_MODE` (`recursion` | `forwarders`),
  `DNS_FORWARDERS`, `DNS_DNSSEC`, `DNS_BLOCKING`, `BLOCKLIST_URLS`.
  Launch values mirror pfSense Unbound exactly: full recursion, DNSSEC off,
  blocking off.
- **`dns/zones.tsv`** — the zone inventory (18 zones):
  `lan` **Primary** (pfSense DDNS target + pinned statics); six per-VLAN
  Primary reverse zones (DDNS PTR targets); `10.in-addr.arpa` → pfSense
  (transitional fallback, delete after cutover); `kaiser.lan` → 10.1.1.140
  (cn-home CoreDNS); `k8s.lan` → k8s_gateway (live-checked .200/.210 at seed
  time); `home.lan`/`hefner.lan` Primary wildcard-redirect zones;
  `lab.gn.al` → `this-server` split-horizon; 5× Apple DEP/MDM sinkhole
  Primary zones.
- **`dns/records.tsv`** — ~90 records: the pfSense host overrides + custom
  options migrated 1:1, all 44 static DHCP mappings (with PTRs), and pins for
  the load-bearing dynamic hosts (router/pki/kaiser/infra/homeiot/rpid0–11).
  Applied with `overwrite=true`, so the TSV replaces the live RRset on every
  run. Zone TYPE changes need `DNS_ALLOW_ZONE_CONVERT=true ./seed-dns.sh`.
- **RFC 2136**: seed-dns.sh installs the `pfsense-ddns` TSIG key
  (`DDNS_TSIG_KEY_*` in .env) and applies update policies (source ACL =
  the six pfSense interface IPs; TSIG-scoped to A/AAAA/PTR/TXT/DHCID) on the
  `lan` + reverse zones.

Changing a **forwarder target** of an existing zone is not automated: delete
the zone in the UI (Zones → zone → Delete), fix `zones.tsv`, re-run
`./seed-dns.sh`.

Manual UI changes to zones/records in the TSVs will be silently reverted by
the next seed run — edit the TSVs instead. Zones/records *not* in the TSVs
are left alone.

## Verification battery

Side-by-side diff against pfSense (run from any LAN host with `dig`):

```sh
PF=10.0.0.1 TD=10.0.0.250
for q in rpid11.lan neptune.lan router.lan \
         auth.neptune.lan outline.neptune.lan photos.neptune.lan sync.neptune.lan \
         accounts.fxa.neptune.lan api.fxa.neptune.lan oauth.fxa.neptune.lan profile.fxa.neptune.lan \
         auth.infra.lan dns.pki.lan \
         auth.lab.gn.al outline.lab.gn.al photos.lab.gn.al sync.lab.gn.al \
         accounts.fxa.lab.gn.al api.fxa.lab.gn.al oauth.fxa.lab.gn.al profile.fxa.lab.gn.al \
         chat.lab.gn.al exercises.lab.gn.al \
         home.lan x.home.lan hefner.lan y.hefner.lan \
         grafana.kaiser.lan hello.k8s.lan \
         acmdm.apple.com albert.apple.com deviceenrollment.apple.com iprofiles.apple.com mdmenrollment.apple.com \
         google.com; do
  a=$(dig @$PF +short +time=3 $q | sort); b=$(dig @$TD +short +time=3 $q | sort)
  [ "$a" = "$b" ] && echo "OK   $q ($b)" || printf 'DIFF %s\n  pfSense:    %s\n  technitium: %s\n' "$q" "$a" "$b"
done
```

Explicit expectations:

| Probe | Expect |
|---|---|
| `dig @10.0.0.250 rpid11.lan` | 10.0.0.188 (pinned; dynamic clients appear via DDNS after a renewal) |
| `dig @10.0.0.250 -x 10.0.0.1` | `router.lan.` (PTR via `10.in-addr.arpa` forward) |
| `anything.kaiser.lan` | `10.1.1.140` (CoreDNS wildcard) |
| `hello.k8s.lan` | matches pfSense (k8s_gateway) |
| 10× `*.lab.gn.al` overrides | `10.1.1.92` (`chat`/`exercises` → `10.1.1.140`) |
| `grafana.lab.gn.al` | **NXDOMAIN** — negative control; tailnet-only names must NOT resolve on the LAN |
| `home.lan` / `x.home.lan` | `10.120.10.55` (apex + wildcard) |
| `hefner.lan` / `y.hefner.lan` | `10.1.1.140` |
| 5× `*.apple.com` sinkholes | `0.0.0.0` |
| `neptune.lan` | 10.1.1.92 (static-mapping pin in the Primary `lan` zone) |
| `google.com` (`+tcp` too) | public answer (recursion, UDP + TCP) |
| `www.dnssec-failed.org` | resolves while `DNS_DNSSEC=false`; SERVFAIL once flipped to true |

Plus: dashboard counters increment at `https://dns.pki.lan`; Query Logs app
shows entries; kaiser Loki `{project="cn-dnsdhcpd"}` has lines.

---

## Runbook a — pfSense cutover (one session per scope, all in the GUI)

pfSense 2.8.1, ISC DHCP backend. Two changes per DHCP scope: hand clients
Technitium as their DNS server, and send lease registrations to Technitium
via RFC 2136. The Technitium side (TSIG key, Primary zones, update policies)
is already configured by `seed-dns.sh` — nothing to do there.

**Step 0 — static reservations (do this FIRST).** Three load-bearing IPs are
dynamic in-pool leases with no reservation — and one of them is the DNS
server itself. Services → DHCP Server → *(interface)* → DHCP Static
Mappings → Add (grab MACs from Status → DHCP Leases; pki's is
`2c:cf:67:1c:8d:7f`):

| Host | Interface | IP |
|---|---|---|
| pki | LAN | 10.0.0.250 |
| kaiser | WIRED | 10.1.1.140 |
| infra | WIRED | 10.1.1.158 |

Also note: the MetalLB VIP 10.0.0.200 (k8s_gateway) sits inside the LAN pool
10.0.0.110–220 — consider shrinking the pool to .110–.190 while you're there.

**Step 1 — per scope (×6: LAN, WIRED, WIFI, MGMT, IOT, LAB).**
Services → DHCP Server → *(interface)*:

- **Servers → DNS Servers**: `10.0.0.250`
  (this is what points clients at Technitium — they pick it up on lease
  renewal, ≤1 h with the default 2 h lease; force one with
  `dhclient -r && dhclient` or a Wi-Fi toggle to verify)
- **Dynamic DNS** (click *Display Advanced*):
  - ☑ Enable registration of DHCP client names in DNS
  - DDNS Domain: `lan`
  - Primary DDNS address: `10.0.0.250`
  - DNS Domain key: `pfsense-ddns`
  - Key algorithm: `hmac-sha256`
  - DNS Domain key secret: from kauket —
    `kauket get pki.cn_dnsdhcpd_env --stdout | grep DDNS_TSIG_KEY_SECRET`
  - DDNS Client Updates: `Deny` (the server, not clients, owns the records)
- Save (applies immediately; dhcpd restarts).

Suggested order if you want to be careful: LAB → IOT → MGMT → WIFI → WIRED →
LAN. Doing all six in one sitting is also fine — rollback is trivial.

**Step 2 — verify.** Renew a client on the flipped scope, then:

```sh
dig @10.0.0.250 <that-client-hostname>.lan +short     # DDNS-registered A
dig @10.0.0.250 -x <that-client-ip> +short            # DDNS-registered PTR
```

Also check pfSense's DHCP log (Status → System Logs → DHCP) for
`Unable to add forward map` errors — those indicate a TSIG/zone mismatch.
(One expected class of log noise: hosts pinned in `dns/records.tsv` produce
"Has an A record but no DHCID" — deliberate; the pin wins.)

**Step 3 — rollback (per scope):** blank the DNS Servers field and untick
the Dynamic DNS checkbox → Save. Clients revert to the pfSense interface IP
on renewal. Unbound keeps running regardless, so rollback is instant.

**Step 4 — cleanup, once everything is cut over:**
- Services → DNS Resolver: untick *DHCP Registration* and *Static DHCP*
  (Unbound's registry is now dead weight).
- Delete the transitional `10.in-addr.arpa` Forwarder zone from
  `dns/zones.tsv` and in the Technitium UI (its pfSense fallback stops being
  useful once regdhcp is off).
- Unbound itself stays enabled for pfSense's own lookups (localhost
  resolver) — leave it; it's no longer client-facing so its instability
  can't hurt the LAN.

**Never** list both resolvers in DNS Servers — clients round-robin between
them and behavior becomes inconsistent.

pki's own `/etc/resolv.conf` keeps pointing at `10.0.0.1` (NetworkManager,
untouched): the DNS host must never depend on its own container for image
pulls or step-ca ACME lookups.

## Runbook b — DHCP delegation to Technitium (phase 2, big-bang)

⚠ **pfSense's DHCP Relay is globally mutually exclusive with its DHCP
server** — you cannot relay one VLAN while serving another. This cutover is
all-or-nothing across all 6 VLANs. Plan a maintenance window.

1. **Pre-stage scopes** (create disabled, enable at the flip). One scope per
   VLAN via `dhcp/scopes/set`; the scope's network must contain the pfSense
   interface IP, because **Technitium selects scopes by relay agent IP
   (giaddr)** — pfSense sets giaddr to its interface address on the client's
   segment:

   | Scope | Range | Subnet mask | Router (opt 3) | giaddr it must match |
   |---|---|---|---|---|
   | LAN | 10.0.0.110–10.0.0.220 | 255.255.255.0 | 10.0.0.1 | 10.0.0.1 |
   | WIRED | 10.1.1.100–10.1.1.200 | 255.255.0.0 | 10.1.0.1 | 10.1.0.1 |
   | WIFI | 10.2.0.40–10.2.0.100 | 255.255.0.0 | 10.2.0.1 | 10.2.0.1 |
   | MGMT | 10.111.0.100–10.111.0.220 | 255.255.0.0 | 10.111.0.1 | 10.111.0.1 |
   | IOT | 10.166.0.110–10.166.0.220 | 255.255.0.0 | 10.166.0.1 | 10.166.0.1 |
   | LAB | 10.120.10.10–10.120.10.220 | 255.255.0.0 | 10.120.0.1 | 10.120.0.1 |

   Each scope: `domainName=lan` (triggers automatic A/PTR registration —
   this replaces regdhcp), `dnsServers=10.0.0.250`, lease time 2h to match
   pfSense defaults. Migrate all 44 static mappings with
   `dhcp/scopes/addReservedLease` (script them from a pfSense config.xml
   export; reserved leases with a hostname get persistent DNS records even
   before first allocation).
2. **Flip**: enable all 6 scopes → pfSense: Services → DHCP Server → disable
   on every interface → Services → DHCP Relay → enable, Downstream
   Interfaces = all 6 internal, Upstream Server = `10.0.0.250`. Leave
   **"Append circuit ID and agent ID" OFF** — Technitium ignores Option 82.
3. **Verify** one renewing client per VLAN (address in range, gateway =
   interface IP, DNS = 10.0.0.250, hostname registered in the `lan` zone).
4. **After the flip**: convert the `lan` zone from Forwarder to Primary
   (Technitium's own scope registration becomes authoritative) and delete
   the `10.in-addr.arpa` forwarder (Technitium auto-creates reverse zones).
   Update `dns/zones.tsv` accordingly.
5. **Rollback**: disable relay → re-enable pfSense DHCP per interface
   (config is retained) → disable Technitium scopes.

**Alternative** (lower risk, no relay): switch the pfSense backend ISC → Kea
(System → Advanced → Networking → Server Backend) and keep DHCP on pfSense.
This clears the ISC-EOL problem without moving DHCP at all; verify Kea's
"DNS registration" behaves like regdhcp before relying on it.

**Roadmap risk**: pfSense's relay is ISC `dhcrelay`, and Kea has no relay
capability. If a future pfSense release removes the ISC components, the
relay path may vanish — re-verify relay exists before upgrading pfSense past
2.8.x, and do this cutover (or commit to Kea-on-pfSense) beforehand.

---

## Operations

- **Upgrading Technitium**: read the
  [CHANGELOG](https://github.com/TechnitiumSoftware/DnsServer/blob/master/CHANGELOG.md)
  (14.x/15.0 carried breaking API + clustering changes), take a manual
  `backup-dump` zip, bump the pinned tag in `docker-compose.yml`, then
  `docker compose up -d technitium`. Never let watchtower do it.
- **Restore drill**: `POST /api/settings/restore` with a `./backups` zip
  (multipart `filefield`), or into a scratch container first.
- **Admin password rotation**: change in the UI (or `user/changePassword`
  with a session token) **and** in kauket (`DNS_ADMIN_PASSWORD`), in that
  order. The compose env var only matters on a virgin `./config`.
- **Memory**: .NET resolver, a few hundred MB RSS is normal; `mem_limit
  1536m` caps it. Watch `container_memory_usage` the first weeks.
- **Automation user permissions** (only if you ever split a non-admin
  automation user): Technitium 15.3 removed `Settings: Delete` and
  `Apps: Delete` from the DNS Administrators group defaults — grant both
  explicitly or backup/restore + app installs fail.
