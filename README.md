# mt-centrallog Lite

Self-hosted MikroTik central logging with rule-based threat detection, auto block/unblock, an MNDP network map with switch-port locate, one-click device WebFig console, device backup/restore (binary and reset-first `.rsc`), per-AP wireless client monitoring, and Telegram + email alerting. Docker Compose, SQLite, single-node.

**Current release: `1.5.593`** — `:latest` and `1.5.593` are the same images on GHCR (pushed 2026-10-15): `backend`, `poller` and `frontend` moved (manifest digests `e7716f23…`, `e38718be…`, `f66619f7…`) while `nginx` (`99ed079f…`) and `mndp-relay` (`903e2280…`) are byte-identical to `1.5.583`. The release is about **a device reply that stopped halfway — and making the fleet's own log lines readable by machine**. **(1)** Every poll reuses one connection to a device, and a read that dies part-way used to leave the rest of that reply on the wire: the next command then received the *previous* command's rows. The failure paths inside the harvesters now end that connection, log the failure class, and reconnect on the next cycle — while a device that answers `no such command` has given a COMPLETE reply and keeps its connection, so ordinary devices without a wireless menu are not reconnected every cycle. A follow-up review closed the rest of the path: the reads that follow a discard — a switch's forwarding tables, its spanning-tree port roles, the wireless-controller registration chain, a device's firewall rules — now stop at the discard instead of issuing the next command onto a dead handle, and a failed firewall-rule push ends that device's cycle cleanly instead of aborting the whole resync with an internal error about a missing connection. **(2)** The two readings that prove this fault — a health reply that came from the wrong command, and a wireless-client row with no client behind it — are now written into the durable event record (`sqlite_data/events/poller.tsv`) as well as the container log, because a container rebuild destroys the log and not the record. **(3)** A stored wireless-client row whose MAC is all zeros is not a client, and the harvesters refuse it: measured on the Full reference box, 22 of 1,060 CapsMan registration rows carried a MAC and nothing else — no interface, no signal, no access point resolved — which is the field shape of an interface-list reply, not a registration. Each refused row is logged with the device name and the row's own fields, so the anomaly stays visible instead of being quietly filtered out. **(4)** Structured log calls now take named values everywhere in this edition. The logger does **not** substitute `%s`: a call like `log.warning('… path=%s reason=%s', path, reason)` stores the *template* as the event name and puts the values in a field no log reader looks at, so the line reads fine to a human and is invisible to every filter, alert and event record. Eleven such calls were live in code this edition runs; all are named-field calls now, and a source check fails the test suite whenever one is added. **(5)** The device-console relay's failure log names its fields, and the diagnostics bundle scrubs credentials out of every container log tail — the alert-service request URL carries the Telegram bot token and the HTTP library logs request URLs at INFO, so the token was sitting in the logs the bundle collects. The scrub keeps the credential's identity (`bot8977061393:***`) so a reader knows which one to rotate, and request logging is silenced at the source. **(6)** A command that changes something on a device is no longer re-issued after a dropped connection, and a reconnect now closes the router session it was using instead of abandoning it — previously every read timeout left an open API session on the router streaming a reply nobody read. The connection read ceiling is now a property of the client that needs it, so the fleet default stays 10 seconds and only a long-running command asks for more (the caller that needed the longer ceiling is the network scanner, which is Full-only). A new read-only health sweep (`tools/log_sweep.py` — a check you run from the source repository, not part of this installer) runs the same checks in the same order every time: known fault classes gated at zero with the device named when one returns, still-open classes measured against a band measured on a real fleet, and the *shape* of the logs checked too; `--json` saves the numbers and `--compare` reports what moved since the last run. **Previous release `1.5.583`:** the host watchdog keeps its own durable record (`.watchdog/events.tsv` plus a `heartbeat` touched on every run) and its snapshot job is accounted for — attempts timed by when the last one was made, no file left behind on a failed attempt, a copy accepted only when it is at least `DB_WATCHDOG_SNAPSHOT_MIN_BYTES` and really contains a schema, because a 0-byte file answers `PRAGMA integrity_check` with `ok` and is not a backup; `recover_db.sh` searches `backup_data/` newest-first and refuses candidates that are too small, schema-less or without a `users` row; `DB_WATCHDOG_PROBE_VIA_CONTAINER=true` runs the check and the snapshot **inside the backend container** when the host's read-only open cannot create `-shm` (root-owned data directory, WAL sidecars absent while the database is idle), and a probe that keeps failing is announced once per `DB_WATCHDOG_PROBE_ALERT_REPEAT_SEC`, naming the cause; the watchdog **refuses to run** instead of calling your database corrupt when the `sqlite3` helper is missing (it records `error_no_sqlite3` in its own event record); `DB_WATCHDOG_RAMDISK_MODE=skip|disk|live|both` decides what it checks on a ramdisk install (auto-recovery is always refused there); and the read-only admin `GET /api/v1/system/diagnostics` (+ `/bundle`) reports config, the real docker mount table, disk usage, a size + schema + integrity verdict for every backup and a masked copy of `.env`, with integrity scanning capped by `DIAGNOSTICS_INTEGRITY_MAX_MB` (500 MB) and `?deep=true` to opt back in. **Previous `1.5.575`:** core devices had their whole ARP refresh thrown away on most polls — a router reports one address twice (its virtual VRRP address and the VLAN interface it sits on) and storing both broke the one-row-per-address rule — and routers that have no wireless menu at all stopped flooding the log (~3,200 warning lines a day on the reference site). **Previous `1.5.573`:** the one-click WebFig console opens logged in every time (RouterOS 7 keeps its console session in browser storage scoped to the address and port and resumes with it *before* using the credentials handed to it, so the opening page now discards that stored session first); a device-console request that fails now names its own error instead of answering `Device unreachable: ` with nothing after it; and the page plus every screen link are served with `Cache-Control: no-cache` while version-stamped scripts and styles get a one-year immutable cache, so `Ctrl+Shift+R` is no longer the standing workaround after `./update.sh` — this is also the release whose rebuilt nginx image `install.sh` users carry.
Earlier Lite releases, in short: `1.5.570` (a Network Map page that failed to load its saved layout no longer saves an empty one over it, and the server refuses a save that would erase stored manual links or named views — the guard against losing map work you never deleted), `1.5.569` (the device WebFig console no longer inherits the previous console's cookies — cookie names now carry the console session as well as the port, so a re-used port can no longer hand an old router's session cookie to a new device and land you on that router's login page; and the Database Admin **Vacuum** action now also runs `ANALYZE`, refreshing SQLite's query-planner statistics for the first time — the query that feeds the Network Map's live traffic colours measured **2.78 s → 0.37 s** on a copy of a production database), `1.5.567` (deleting a packet capture removes it from the list immediately and a failed delete is reported instead of swallowed; the `capture_start` audit entry carries the capture's real id; the console no longer copies the router's own `Date`/`Server` headers onto its responses), `1.5.564` (opening a router's web console is written to the Audit Log as `open` → `login` → `close`), `1.5.563` (Network History replay ships only the links it can draw — a 2-hour window 20 MB → 6.7 MB plain / 0.6 MB compressed — and nginx no longer writes map-layout saves to a disk temp file), `1.5.561` (Network Map load-failure diagnostics + `gzip_proxied any`).

> **Older releases stay available.** This repository is tagged from `v1.5.558` up (`v1.5.558` · `v1.5.561` · `v1.5.563` · `v1.5.564` · `v1.5.567` · `v1.5.569` · `v1.5.570` · `v1.5.573` · `v1.5.575` · `v1.5.583` · `v1.5.593`), and the image registry is deeper than the git tags: `1.5.286` through `1.5.593` plus `latest` — **41 versions of each of the five images** (the list is not contiguous: releases were published on the versions that shipped), read from GHCR on 2026-10-15. So `./update.sh 1.5.570` (or any version back to `1.5.286`) pins an older release if you need to go back.

> **Repo status:** this repository ships the **installer + pre-built Docker images only**. The source lives in the private full repo. Everything here is what `install.sh` needs and what `docker compose pull` fetches.

## Videos

https://www.youtube.com/watch?v=5XYOWSiuobE

## Screenshots

![Dashboard](screenshot/Dashboard.png)
![Network Map](screenshot/NetworkMap.png)
![Network Map — device card, live load and link legend](screenshot/NetworkMap2.png)
![Network Map — timeline, link-count history with A/B compare](screenshot/NetworkMap_Timeline.png)
![Network Map — RTT deep probe](screenshot/RttProbe.png)
![Network Map — toolbar menu](screenshot/NetworkMap_Menu.png)
![Network History — traffic replay & video export](screenshot/NetworkHistory_v2.png)
![PtMP / mesh wireless topology](screenshot/PtMP_Mesh.png)
![Devices — MNDP broadcast / subnet scan discovery](screenshot/Add_devices.png)
![Devices — every managed device and its per-row actions, including the one-click WebFig console](screenshot/Devices.png)
![Audit Logs — device-console (WebFig) sessions, each attributed to an operator and audited](screenshot/AuditLogs.png)
![Per-device stats — health, CPU, memory, temperature](screenshot/Statistic.png)
![DB Admin](screenshot/DbAdmin.png)
![DB Admin — data-hygiene suite](screenshot/DbAdmin_Hygiene.png)
![Reports — notification categories](screenshot/NotificationCategories.png)
![Users — 2FA, roles, recovery](screenshot/Users.png)
![Login](screenshot/Login.png)

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/cluangar/mt-centrallog-lite/main/install.sh | bash
```

That single command:
1. Checks Docker + Compose v2 are available.
2. Auto-detects your LAN interface / subnet / gateway.
3. Downloads the compose file + `.env.example` into `~/mt-centrallog-lite/`.
4. Generates a strong `SECRET_KEY` and internal `BACKEND_API_KEY`.
5. Runs `docker compose pull && docker compose up -d`.
6. Schedules the host **DB watchdog** in your crontab (every 10 min) — see [Database protection](#database-protection).

When it finishes: browse to `http://<your-server-ip>/` — default login **admin / admin1234** (change it on first login).

## Requirements

- Linux host (amd64). Tested on Debian 12, Ubuntu 22.04 / 24.04.
- Docker Engine 24+ with Compose plugin (`docker compose version` must work).
- Free TCP ports 80 + 443 (override via `WEB_HTTP_PORT` / `WEB_HTTPS_PORT` in `.env`), plus 8071–8080 for the one-click device WebFig console (fixed, up to 10 concurrent windows) and 5679 for the MNDP relay's own read-only API (`GET /devices`, `GET /query`). The backend's own port 8000 is **not** published to the host — every API call goes through nginx on port 80.
- A LAN interface reachable by your MikroTik devices (needed for MNDP broadcast discovery). The ipvlan parent is `MNDP_PARENT_IFACE` (default `eth0`; set it to `wlan0`/`wlo1` on a Wi-Fi host).

## Update

```bash
cd ~/mt-centrallog-lite
./update.sh              # pull :latest and recreate
./update.sh 1.5.593      # pin to a specific version (writes IMAGE_TAG to .env)
./update.sh --refresh    # also re-download the compose file, update-mndp.sh, and the three watchdog scripts
```

Your `sqlite_data/`, `backup_data/`, `capture_data/`, and `.env` are never touched by an update — only images swap.

Any database schema change a release needs is applied automatically the first time the new backend image starts — there's no separate migration step to run.

## Change LAN settings

If auto-detect picked the wrong interface, or your LAN moved:

```bash
cd ~/mt-centrallog-lite
./update-mndp.sh         # interactive prompts for MNDP_* + BACKEND_FETCH_URL
docker compose down && docker compose up -d    # recreate the macvlan_lan network
```

## Uninstall

```bash
cd ~/mt-centrallog-lite
./uninstall.sh              # stops stack, prompts before deleting data
./uninstall.sh --keep-data  # keeps sqlite_data/ backup_data/ capture_data/
```

## What's inside

Five containers pulled from GHCR:

| Image | Purpose |
|---|---|
| `ghcr.io/cluangar/mt-centrallog-lite-backend` | FastAPI + SQLAlchemy async, REST API, threat engine, auto block/unblock |
| `ghcr.io/cluangar/mt-centrallog-lite-poller` | librouteros polling loop, MNDP scanner, DHCP/DNS/lease scraper |
| `ghcr.io/cluangar/mt-centrallog-lite-frontend` | React SPA (Vite build) |
| `ghcr.io/cluangar/mt-centrallog-lite-nginx` | Reverse proxy, self-signed cert on first boot |
| `ghcr.io/cluangar/mt-centrallog-lite-mndp-relay` | UDP host-relay so containers see MNDP broadcasts |

Plus one sidecar not built by us: `tecnativa/docker-socket-proxy:0.3` (narrows the backend's Docker access to `/containers/*` + `/images/*` — needed for the Service Status page and post-restore auto-restart).

## Features

**Included in Lite:**

*Logging & threats*
- Multi-device MikroTik log collection over the RouterOS API
- Rule-based threat detection (detection-rule CRUD) + automatic block/unblock into a `centrallog-blocked` address list
- IP whitelist management, including dynamic-DNS tracking of a whitelisted hostname
- Risk scoring (0–100, severity + recidivism + subnet concentration) with automatic escalation, GeoIP threat map
- Per-threat trace (what the device actually did) and a full audit log of every operator action
- Logs / Threats / Rules / Whitelist / Trace / Audit pages, system-log viewer, service-status page, API keys for machine access

*Network map & discovery*
- MNDP network map: saved device positions, named views, undo/redo for moves, links, resets and views, Ctrl+K command palette — and a page that failed to load its saved layout never saves an empty one over it
- UDT **locate** — resolve an IP / MAC / hostname to the **switch and port** it is on, ranked best-first; hostname resolution runs through DHCP leases, static/cached DNS, and a live router probe
- Live per-link traffic load colouring, stale-link badging, per-port chips on the device card
- Link-count timeline with A/B compare, and **Network History**: traffic replay over a time window with video export (WebM / MP4 / AVI)
- Per-device map tools: **Force update** (re-poll one device on demand and report the uplink it found) and **RTT deep probe** (ICMP path-quality classification to the neighbours heard on its ports)
- What-if view: `?mute=9,12` redraws the map as if those devices were gone, without touching them
- Device discovery by MNDP broadcast or by TCP subnet scan, with SNMP enrichment

*Wireless*
- PtMP / mesh / WDS links drawn from each AP's own registration table (no controller required)
- Per-band (2.4 / 5 / 6 GHz) + per-SSID client counts on the map and in the device's Wireless tab, with per-client signal (dBm) and tx/rx rate
- Weak / poor-signal surfacing per AP, overloaded-AP chip on the map, and per-AP client-count history charted over time
- Client manufacturer badges from the IEEE OUI registry (offline lookup)

*Devices*
- Binary `.backup` save + restore (exact, reboots the device)
- `.rsc` save + restore in **both** modes: fast `/import`, and **reset-first** restore with a rescue bootstrap so the device always comes back reachable on its current management IP — plus assisted recovery hints (locate-by-MAC via neighbours) when it does not
- Multi-IP / multi-VLAN device records, self-IP and managed-device protection so the app never blocks itself, firewall-rule resync between DB and device
- Full hardware-health panel (temperature / voltage / current / fans across CCR / CRS / RB), interface + uptime + CPU/memory history
- One-click **WebFig console** from a device row (the **Web** button, plus the open icon in the Console modal) — a ticket-gated auto-logged-in session, up to 10 concurrent windows on ports 8071–8080, with every open / login / close written to the audit log. Since `1.5.573` the opening page discards the router's stored console session in the browser before handing over the credentials, so the console opens logged in every time (it previously could land on the router's own login page when that stored session had gone stale)

*Alerting*
- Telegram: threat alerts, device offline/back-online, job completion, database health, and a periodic digest; quiet hours and alert-storm coalescing; optional inline Block / Whitelist / View buttons (off by default, acted on only from the chats alerts are sent to)
- Email: report delivery, forgot-password reset, 2FA recovery codes
- A per-category checklist on the Reports page (Security / Firewall / DB-Health / Device) to mute a category without editing `.env`

*Accounts & security*
- Roles `viewer < analyst < operator < admin`, per-endpoint enforcement, admin "view as" preview, TOTP 2FA with one-time recovery codes, self-service password change and email password reset, login rate limiting + lockout with security alerts
- `SECRET_KEY` startup gate, security headers, upload caps, SSH host-key learn-and-verify, docker-socket-proxy sidecar instead of a raw `docker.sock` mount
- English + Thai UI

*Database protection*
- Scheduled rolling backups every `DB_BACKUP_INTERVAL_HOURS` (default 4) plus the timestamped ones you take from DB Admin — written **without disturbing the running database** (SQLite online-backup API, read-only sources) and integrity-verified, so a corrupt page is never copied into a backup
- **Opt-in** startup auto-heal — `DB_AUTOHEAL_ENABLED=true` (the shipped template sets `false`; turn it on especially on SD / eMMC / USB storage) — which promotes the newest clean, non-empty backup when the database is unusable
- DB Admin page: backup/restore (restore is staged, applied safely at next start), purge, vacuum (which also runs `ANALYZE` to refresh SQLite's query-planner statistics), disk-usage breakdown, and a data-hygiene suite that reconciles DB rows with the files actually on disk (import orphan device backups, drop rows whose file is gone, delete files with no row)
- Host **DB watchdog** (`db_watchdog.sh`, cron every 10 min) — see below
- Both the watchdog and the poller keep a **durable record** that survives a container recreate: `.watchdog/events.tsv` (one row per flagged watchdog run) plus `.watchdog/heartbeat`, and `sqlite_data/events/poller.tsv` (one row per flagged poller failure) plus its own `heartbeat`. Read them with `./db_watchdog.sh events <run-dir> [N]`. ⚠ **No rows is not evidence the process stopped** — at the default `critical` level a healthy run writes nothing, so the heartbeat file's mtime is the liveness signal.
- Read-only **diagnostics** for an admin: `GET /api/v1/system/diagnostics` returns the app config, the real container mount table, disk usage, a size-and-tables verdict for every backup, live-database facts and a masked copy of `.env`; `GET /api/v1/system/diagnostics/bundle` returns the same as a `tar.gz` with the log tails added. Nothing in that path runs a backup, a `VACUUM` or a topology build, and every database read is read-only.

**Not in Lite (available in the Full edition):**
- AI pattern detection, adaptive rule proposals, predictive pre-blocking — the Lite UI hides those sections. A couple of background status polls still probe the Full-only endpoints and get a 404 in return; it is server log noise only, with no effect on any Lite feature and no data impact.
- SNMP network-topology mapping (FDB / LLDP / Q-Bridge / CapsMan), SNMP device discovery and the SNMP settings page
- Continuous subnet host scanning (`scanned_hosts`) — Lite's locate resolves from DHCP/DNS and live router probes
- RouterOS firmware upgrade/downgrade jobs (including optional-package staging)
- Bulk CLI runner
- Wireless analysis page (fleet-wide load + weak-signal table)
- MariaDB backend option, MCP server, AR Port-Map API
- AbuseIPDB / Tor / proxy reputation **lookups** — Lite's risk scorer reads the reputation table (`risk_scorer.py:91`) and scores it if rows exist, but Lite ships no reputation service to fill it
- Ramdisk database mode

Lite and Full share the same DB schema and the same `.env` format — Lite → Full upgrade is a Docker image swap.

## Database protection (host watchdog)

`install.sh` and `update.sh` place three scripts next to your stack and add one crontab entry (`*/10`):

⚠ A plain `./update.sh` re-downloads those scripts **only when they are missing**. An install that already has them picks up a watchdog change by running `./update.sh --refresh` — the crontab entry is re-installed in the same step.

| Script | Role |
|---|---|
| `db_watchdog.sh` | the single command: `install` · `remove` · `status` · (no argument) run one check |
| `watchdog-cron.sh` | manages the crontab entry only |
| `recover_db.sh` | deep repair — auto-elevates with sudo when it needs it |

It checks the database two ways (a read-only `integrity_check` **and** the backend's own error log), keeps verified snapshots and per-incident forensics in `.watchdog/`, and — when `DB_WATCHDOG_AUTORECOVER=true` — stops both writers, heals the backend, then restarts the poller. Repeated failures trip a circuit breaker that stops auto-retrying until a human looks; clear it with `./db_watchdog.sh rearm`.

- It runs **as you**, not root, and never resurrects a stack you deliberately stopped.
- It is opt-in for unreliable storage (SD / eMMC / USB): `DB_WATCHDOG_ENABLED=false` by default, set it `true` on those disks.
- Telegram pings for watchdog events follow the **DB-Health** category on the Reports page plus `TELEGRAM_DB_ALERTS`.
- **It works in every storage mode now.** `DB_WATCHDOG_RAMDISK_MODE=skip|disk|live|both` (default `skip`): `disk` checks the copy in `sqlite_data`, `live` runs `PRAGMA quick_check` on the live in-RAM database **inside the backend container**, `both` does the two. Auto-recovery is always refused on a ramdisk install — a lagging disk copy is never promoted over a live RAM database.
- If the check itself fails with `attempt to write a readonly database`, set `DB_WATCHDOG_PROBE_VIA_CONTAINER=true`: the check and the snapshot then run inside the backend container, as the user that owns the database, and the result is copied out. ⚠ **Never fix that failure with `chown` or `chmod` on the data directory** — a sidecar your user creates is one the containers then cannot open.
- A snapshot is only accepted when it is at least `DB_WATCHDOG_SNAPSHOT_MIN_BYTES` **and** actually contains tables — an empty file passes `PRAGMA integrity_check` with `ok`, so integrity alone is not a test. Keep-count is `DB_WATCHDOG_SNAP_KEEP`, and each kept snapshot is the size of your database: on a multi-GB database 24 is not a safe default.
- A probe that keeps failing stops being a whisper: after `DB_WATCHDOG_PROBE_FAIL_ALERT` runs in a row it says so out loud and names the cause, at most once per `DB_WATCHDOG_PROBE_ALERT_REPEAT_SEC`.

Manual checks: `./db_watchdog.sh status` · `crontab -l | grep watchdog`. Remove it with `./watchdog-cron.sh remove` (or `./uninstall.sh`).

## Tunables worth knowing

Everything lives in `.env` and `docker compose up -d` re-reads it. A few are worth naming:

| Key | Value in `.env.example` | What it does |
|---|---|---|
| `LOG_RETENTION_DAYS` / `INTERFACE_STATS_RETENTION_DAYS` / `THREAT_RETENTION_DAYS` | see `.env` | how far back logs, per-interface traffic samples and threats are kept |
| `WIRELESS_WEAK_SIGNAL_DBM` / `WIRELESS_POOR_SIGNAL_DBM` | `-75` / `-85` | the weak / poor client thresholds |
| `WIRELESS_OVERLOAD_CLIENT_COUNT` | `30` | how many associated clients turn an AP's map chip amber |
| `WIRELESS_FRESHNESS_MINUTES` | `60` | how old a client sample may be before it is dropped from the counts — must outlive one full poll pass of your fleet |
| `WIRELESS_STATS_SAMPLE_INTERVAL_MINUTES` | `15` | cadence of the per-AP client-count history behind the device chart |
| `TOPOLOGY_POLL_INTERVAL_SECONDS` | `900` | how often the poller re-reads neighbours / FDB / spanning-tree — the evidence the map is built from |
| `WIRELESS_REG_EDGES` / `WIRELESS_FLOOD_DEMOTE` | `true` / `true` | turn the controller-less wireless links (and their flood demotion) off when a map link looks wrong |
| `TOPOLOGY_SNAPSHOT_INTERVAL_S` / `TOPOLOGY_SNAPSHOT_RETENTION_DAYS` | `900` / `3` (code defaults `15` / `90`) | link-count timeline capture tick + retention |
| `TELEGRAM_*` | see `.env` | which alert types are sent, digest interval, quiet hours, inline buttons |
| `DB_WATCHDOG_ENABLED` / `DB_WATCHDOG_AUTORECOVER` / `DB_WATCHDOG_RAMDISK_MODE` | `false` / `true` / `skip` | the host watchdog: opt-in on unreliable disk, and what it does on a ramdisk install (see above) |
| `DB_WATCHDOG_PROBE_VIA_CONTAINER` / `DB_WATCHDOG_PROBE_FAIL_ALERT` / `DB_WATCHDOG_PROBE_ALERT_REPEAT_SEC` | `false` / `3` / `86400` | run the check and the snapshot inside the backend container when a root-owned data directory makes the host's read-only open fail, and how often a repeated failure is announced |
| `DB_WATCHDOG_SNAP_KEEP` / `DB_WATCHDOG_SNAPSHOT_MIN_BYTES` | `24` / `10000000` | how many snapshots are kept — each is as large as the database — and the floor below which one is thrown away and recorded as rejected |
| `DB_WATCHDOG_ERR_THRESHOLD` / `DB_WATCHDOG_ERR_WINDOW_MIN` | `3` / `12` | the second detection signal: backend `malformed` log lines counted over a plain wall-clock window |
| `EVENTS_ENABLED` / `EVENTS_DIR` / `EVENTS_LEVEL` / `EVENTS_LINES` | `true` / `/data/events` / `critical` / `2000` | the poller's critical-event record (`poller.tsv` + `heartbeat`) |
| `DIAGNOSTICS_INTEGRITY_MAX_MB` / `DIAGNOSTICS_BUNDLE_MAX_MB` / `DIAGNOSTICS_LOG_TAIL` | `500` / `25` / `500` | caps on the read-only diagnostics endpoints: integrity scanning, bundle size, per-container log tail |
| `DB_AUTOHEAL_ENABLED` | `false` in the template (the code default is `true`) | startup auto-heal |

⚠ Changing an app value needs `docker compose up -d` (a **recreate**), not `docker compose restart` — a restart does not re-read `.env`. The one exception is the `DB_WATCHDOG_*` keys: `db_watchdog.sh` reads them from `<run-dir>/.env` on every cron run, so a saved value takes effect on the next run with no recreate — and `export DB_WATCHDOG_…` before a manual run does nothing, because the file wins.

## License

TBD. Do not redistribute without permission until this section is filled in.

## Support

Issues + questions: [github.com/cluangar/mt-centrallog-lite/issues](https://github.com/cluangar/mt-centrallog-lite/issues)
