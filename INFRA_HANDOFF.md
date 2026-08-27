# SWT Booth — Infrastructure Session Handoff

You are the **infrastructure half** of the SWT booth "Ask Anything" wall project,
running in a session dedicated to the AtScale environment so the demo-code work
(repo `~/GitHub/ipaddemo`) can proceed in parallel without collision.

**Read this file, then read the `project_swt_booth_dashboard` memory** (it has the
same facts in durable form and is your source of truth across sessions). Do not
touch `~/GitHub/ipaddemo` code — that's the other session. Your job is to make
the environment real and hand back two things: a **licensed, reachable swtdev**,
and confirmation the tap can observe it.

---

## The one task that matters right now: LICENSE swtdev's engine

`swtdev`'s engine has **no license**. Symptom in the engine log:

```
com.atscale.engine.license.entitlements.KeygenLicenseCache - Error when obtaining License
EntitlementServiceClientError: Client error on entitlement service: Error 404 Not Found
```

An unlicensed engine refuses all data-warehouse / catalog / query operations
(surfaces as `500 "You don't have permission to access this resource"` on
`POST /wapi/p/data-warehouses/snowflake`, even though reads and auth work).

**This blocks everything else.** Until it's licensed, swtdev cannot serve
queries, so the tap/kill-drill/redis work has nowhere to run.

**First move:** figure out how a licensed box (`demo2` = `se-demo-atscale2`,
`172.169.248.80`, key `~/Downloads/SE-Demo-atscale2_key.pem`) gets its
entitlement, and reproduce it on swtdev. Compare:
- engine env / secrets referencing a license or keygen key
  (`microk8s kubectl get deploy atscale-engine -n atscale -o yaml`, the
  entitlement deployment, and any license secret) on demo2 vs swtdev
- the entitlement service config on both
- whether the deploy chart expects a license value that
  `atscale-deploy-action` never set (grep the chart/values — neither the
  action nor the rendered values reference a license/keygen today)

A license key / entitlement config is a **Frank-or-SRE decision** — surface what
you find and what's needed; do not fabricate or forge entitlement material.

---

## swtdev environment — current state (as of 2026-08-26)

| | |
|---|---|
| Resource group / VM | `rg-poc-swtdev` / `vm-atscale-swtdev` (westus3) |
| Public IP | `20.163.121.39` (Azure FQDN `atscale-swtdev.westus3.cloudapp.azure.com`) |
| SSH | `ssh -i ~/GitHub/atscale-deploy-action/runtime/swtdev_key atscale@20.163.121.39` |
| kubectl / helm | **need the `microk8s ` prefix** on this box (`microk8s kubectl …`) |
| Chart | `atscale-2026.7.1` (helm rev 7, deployed) — matches demo2 on purpose |
| Auto-shutdown | 05:00 UTC (DevTest schedule). `az vm start -g rg-poc-swtdev -n vm-atscale-swtdev` to bring back |
| Admin login | `atscale-kc-admin` / password in `runtime/deploy-swtdev.log` |
| TLS | real `*.atscalehosted.com` Sectigo cert served (see DNS note) |
| Snowflake footprint | `POT_SWTDEV_*` (DB/warehouses/role/SVC); key `~/GitHub/atscale-snowflake-provision/runtime/swtdev_snowflake_key.p8`. `POT_SWTDEV_ROLE` granted read on `SE_DEMO_LIBRARY.AS_ADVENTURE` (BYO-data source) |

Pods healthy (`microk8s kubectl get pods -n atscale`); the persistent engine
warning is only the license 404 above.

---

## Landmines (all learned the hard way this session — do not re-trip)

1. **`./deploy.sh create` used to DOWNGRADE the chart** (it pinned
   `CHART_VERSION=2026.5.1`; re-running bare `create` on this upgraded box
   started a 7.1→5.1 helm downgrade). **FIXED 2026-08-26** (branch
   `chore/chart-default-2026.7.1`): the default in `deploy.sh`/`action.yml`
   is now **2026.7.1**. Still prefer **surgical version-pinned
   `helm upgrade`** for any change to a live box. Recover a bad/interrupted
   upgrade with `microk8s helm rollback atscale <last-good-rev> -n atscale
   --wait` (that's how rev 7 was restored after the accidental downgrade).
2. **`~/.snowflake/` is now `SNOWFLAKE_HOME`.** Creating it for keys hid the
   `snow` CLI config; fixed via symlink `~/.snowflake/config.toml` →
   `~/Library/Application Support/snowflake/config.toml`. Leave it.
3. **`admin_demo` lost Key Vault secrets access** on `se-demo-keyvault`
   ("Assignment: not found"). Don't re-run the deploy's Key Vault TLS path.
   The cert now comes from the AIG values file instead (see below).
4. Observe-only on **demo2** — it's the shared demo cluster and heads into
   change freeze. swtdev is yours to break.

---

## DNS / cert situation (cosmetic until licensed)

- The real `*.atscalehosted.com` cert (from `runtime/values-aig.yaml`'s inline
  `tlsCrt`/`tlsKey`, decoded to `runtime/atscalehosted-fullchain.pem` +
  `runtime/atscalehosted.key`, gitignored) is already served by swtdev's
  ingress gateway. It was applied via a **pinned cert-only helm upgrade**
  (`helm get values` → swap `global.atscale.tls.tlsCrt/tlsKey` → `helm upgrade
  --version 2026.7.1 -f …` → `rollout restart deploy/atscale-ingress-gateway`).
  Verified: `openssl s_client -connect 20.163.121.39:443 -servername
  swtdev.atscalehosted.com` → `CN=*.atscalehosted.com`, Sectigo issuer.
- **`*.atscalehosted.com` is a public wildcard → an ngrok tunnel, WITH IPv6
  (AAAA) records.** So every name under it resolves to ngrok, and an IPv4-only
  `/etc/hosts` entry is shadowed by the preferred public IPv6 — browsers reach
  ngrok, not the box. Escapes: turn IPv6 off on the client
  (`sudo networksetup -setv6off Wi-Fi`), add a `::1 <name>` shadow line, or —
  proper fix — a **specific Cloudflare A record** `swtdev.atscalehosted.com →
  20.163.121.39` (a specific record beats the wildcard for everyone; needs the
  zone owner). The app routes on any hostname, so the name choice is free.

---

## After the license is resolved — the rehearsal chain

1. **Register the Snowflake data source** as connection id `con1` (the name the
   demo SML expects) via ps-utils:
   - ps-utils has **uncommitted fixes on branch `develop`**
     (`~/GitHub/ps-utils/src/services/AtScaleRestClientService.ts`): loads the
     private key from `privateKeyPath`, resolves the `snowflake_user` users-block
     ref, and sends the 2026.7.x required fields (`isImpersonationEnabled`,
     `isCanaryAlwaysEnabled`, `isPartialAggHitEnabled`,
     `isKerberosClientEnabled`, and the `agg_creation_role` query role). These
     got the POST past validation — the only remaining failure was the license.
     Decide whether to commit them (branch `develop`, not asked yet).
   - connections fragment: `~/GitHub/atscale-snowflake-provision/runtime/connections-swtdev.yaml`
     (add an `atscale:` block: `url: https://atscale-swtdev.westus3.cloudapp.azure.com`,
     a `kcadmin` user with the admin password). Default Keycloak client
     `atscale-ai-link` issues ROPC tokens fine.
2. **Deploy the demo catalog** — the SML lives at
   `~/GitHub/sml-demo-sales-insights-develop` (internet_sales model;
   connection override `con1`). Use `atscale-utils atscale-deploy-catalog`.
   Point its physical connection at `POT_SWTDEV_DB.SOURCE` /
   `SE_DEMO_LIBRARY.AS_ADVENTURE` (the granted BYO-data source).
3. **Enable MCP** and confirm a query runs end-to-end (engine logs inbound +
   outbound SQL + audit line, the shape the tap parses).
4. **Snapshot the golden baseline (do this the moment steps 1–3 are green).**
   This is the whole point of swtdev: a known-good state the demo session's
   kill drills / container deploys / redis experiments can always roll back
   to. On this **single-node microk8s box everything lives on the OS disk**
   (hostpath storage, no data disk — see [[reference_atscale_container_upgrade]]),
   so ONE OS-disk snapshot captures the full state: license, deployed catalog,
   PG/model data, the lot.
   ```
   osdisk=$(az vm show -g rg-poc-swtdev -n vm-atscale-swtdev --query storageProfile.osDisk.managedDisk.id -o tsv)
   az snapshot create -g rg-poc-swtdev -n swtdev-golden-licensed-$(date +%Y%m%d) \
       --source "$osdisk" --location westus3      # --location MUST match the disk region (westus3)
   ```
   (Optional cheap insurance: take one BEFORE the licensing experiments too, in
   case editing entitlement config/secrets wedges the box.) Restore = create a
   disk from the snapshot and swap the VM's OS disk, or redeploy from it.
5. **Set up the VM-resident integration session** so tap work runs ON the box
   with local `microk8s` access instead of over SSH: install Claude Code on
   swtdev, `git clone` the ipaddemo repo there, and start a session in it —
   `CLAUDE.md` already has a "Working from the VM checkout" section that
   orients any VM session (note: kubectl needs the `microk8s ` prefix here).
   That session owns the on-box demo integration; keep it distinct from this
   env-setup session.
6. **Hand back to the demo session** for the real rehearsal: redis-source live
   validation, the scope-4 kill drill, and the container deploy — those live in
   `~/GitHub/ipaddemo` (`sidecar/README.md`, `tap/DECISION.md`,
   `BOOTH_RUNBOOK.md`), and now have a snapshot to fall back on when they break
   things.

## Definition of done for this thread
A **licensed** swtdev with the demo catalog deployed and MCP enabled, a real
query observable in the engine logs, the SVC_WALL-style Snowflake join
confirmed against `POT_SWTDEV_*`, **a golden OS-disk snapshot taken of that
clean state, and a VM-resident ipaddemo checkout ready for integration** — i.e.
a faithful, restorable stand-in for the event VM that the demo session can
point its tap at without touching demo2.
