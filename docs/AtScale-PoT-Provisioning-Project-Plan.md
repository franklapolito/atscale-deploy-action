# AtScale Proof-of-Technology (PoT) Environment Provisioning — Project Plan

**Owner:** Frank · **Status:** v1.0 (§3.6 CLOSED — cert vault + DNS provider confirmed; Phase 1 build underway) · **Last updated:** 2026-06-30

> Living document. v1.0 closes §3.6 (the last blocker): the `*.atscalehosted.com` wildcard private key is confirmed in **`se-demo-keyvault`** (secret `atscalehosted-com-cert-private-key`, base64 PEM), and `atscalehosted.com` DNS is hosted in **Cloudflare** — option A is adopted, with a **manual A record per PoT for v1** (Cloudflare-API automation deferred to Phase 2). Architecture fully pinned; recon complete; Phase 1 build (refactored `action.yml` + shared `deploy.sh`) is underway. **Target version floor: C2026.5.1+** (demo runs 2026.5.0).

---

## 1. Objective

Stand up **isolated, hosted AtScale environments a prospect connects to for a few days of hands-on testing** ("Proof of Technology" / PoT) — **repeatable, robust to failure, prospect-grade, disposable**, as **self-contained one-VM-per-build** deployments.

**Delivery model (confirmed):** GitHub Actions (canonical create) + Azure CLI (imperative work) + Claude CLI / Claude Code (operator console for recon, triage/heal, teardown). See §4.

---

## 2. Current-state inventory

### 2.1 `atscale-deploy-action` (GitHub Action — automated path)
Composite Action: `workflow_dispatch` → Azure OIDC → provision RG/VM/IP → SSH → MicroK8s + Helm → ingress → print creds.
- VM: Ubuntu 24.04, `Standard_DC2ds_v3` (2 vCPU/16 GiB — **dev/test only, see D1**), 256 GB disk, Standard public IP + DNS label.
- Auth: OIDC federated identity (keep). Naming: `rg-poc-<id>`, `vm-atscale-<id>`, `atscale-<id>`.
- Ports opened: 22, 80, 443, 16443, 15432, 11111 — no source restriction.
- TLS: self-signed (replace with wildcard — G1). Deploy: `helm … 2025.10.0`, generated `values.yaml` using `global.atscale.tls.existingSecret` (**this part is correct** — see §3.3).
- Ingress: microk8s **nginx** addon + hand-rolled `Ingress` + service auto-detection (**the wrong layer** — see §3.3).
- Keep: declarative UX, OIDC, static-IP lock, tagging intent, the `existingSecret` cert wiring.

### 2.2 `Installing on a VM in the Cloud` (SOLENG 3620241410 — manual runbook)
Superseded for sizing by current docs (§3.5). Historical value: MicroK8s + MetalLB `/32` pattern, self-signed-cert friction note, "don't enable microk8s ingress for 2024.10+" (now explained — §3.3).

---

## 3. Discrepancies & gaps — with decisions

### 3.1 Hard discrepancies

| # | Issue | Decision / Resolution (2026-06-30) |
|---|---|---|
| **D1** | VM undersized | **RESOLVED to field reality.** Both golden envs run **`Standard_E8s_v3` (8 vCPU / 64 GB, memory-optimized)** and are flagged *underutilized* by Azure Advisor — so **8 cores / 64 GB is proven sufficient** for demo/light-PoT load. AtScale's doc "POC" tier is `D16s_v5` (16 vCPU / 64 GB) — more concurrency headroom but 2× the cores. **Recommended PoT default: `Standard_E8s_v3`** (matches proven config, half the vCPU = friendlier to quota); **parameterize** so we can bump to `D16s_v5` for a higher-concurrency PoT. (Modern equiv `E8s_v5/v6` worth a look later.) Old `DC2ds_v3` (2/16) was a dev-quota workaround. Premium SSD (PG needs ~5000+ IOPS); x86_64. |
| **D2** | Chart version drift | **Floor: C2026.5.1+** (current latest). Parameterize via tag/variable; default to latest in the C2026.5.x line. Check for an LTS designation and borrow `qa-perf`'s version-pin method. |
| **D3** | Ingress conflict | **RESOLVED — see §3.3.** Remove the microk8s nginx addon + custom Ingress; expose the chart's own proxy via MetalLB; wildcard cert via `existingSecret`. |

### 3.2 PoT gaps

| # | Gap | Decision (2026-06-30) |
|---|---|---|
| **G1** | TLS + DNS | **RESOLVED (see §3.6).** Wildcard **`*.atscalehosted.com`** private key confirmed in **`se-demo-keyvault`** (secret `atscalehosted-com-cert-private-key`, base64 PEM). Cert injected **inline** as `global.atscale.tls.tlsCrt`/`tlsKey` (§3.7). DNS is in **Cloudflare** → option A adopted; **manual A record per PoT for v1**, Cloudflare-API automation in Phase 2. *(Remaining nit: confirm the companion public-cert secret name in the same vault.)* |
| **G2** | Data backend / sample content | Handled separately for now. **Out of scope v1**; design the seam to **chain** later. |
| **G3** | Lifecycle automation | **Manual for v1**, but **tag-driven** design (`Lifecycle`/`Schedule`/add `Expiry`) so auto-stop/TTL teardown drops in without rework. |
| **G4** | Network exposure | **Recon:** both golden envs are effectively **wide open** — a catch-all `AllowTagCustomAnyInbound` from `0.0.0.0/0` (atscale2 also has explicit 443/80). This is the proven baseline; matches the "low concern" call. PoT options: **mirror** (open) or **tighten** to named rules — **443 + 15432** (+ **11111** if Thrift), **22** ops, **drop 16443**. Ensure egress to license/billing URIs (§3.5). |
| **G5** | Credential handoff / auth | **Local users only** (no Keycloak public IDP). Creds generated at deploy; we log in to verify/config. **No change.** |
| **G6** | Idempotency / partial-failure cleanup | **Design for it now** (pre-flight checks, cleanup-on-failure). |
| **G7** | Concurrency / naming | **Design for it now** (collision-safe naming, per-env expiry metadata). |
| **G8** | Post-deploy health verification | **Manual for now.** |

### 3.3 D3 — ingress architecture (resolved; naming confirmed at recon)

History: Kong was removed; the internal nginx `engine-gateway` hop was removed in C2026.4.0. **Now confirmed on a live box (demo2 @ chart `atscale-2026.5.0`):**

`kubectl get svc -n atscale` shows the front door is **`atscale-ingress-gateway`** (type **`LoadBalancer`**, MetalLB-assigned IP `10.0.0.4`), exposing **80, 443, 11111, 15432** in one service. Everything else (engine, engine-sql, keycloak, mcp-server, sml-api/web, redis, telemetry) is `ClusterIP` behind it. The values stanza that drives it is **`atscale-proxy.service.type: LoadBalancer`** (the rendered service is named `atscale-ingress-gateway`). TLS is supplied **inline** via `global.atscale.tls.tlsCrt` / `tlsKey` (base64), and the hostname via `global.ingressDomain`.

**Final architecture (no longer theoretical):**
- Do **not** enable the microk8s nginx ingress addon; do **not** create a custom `Ingress`; **delete** the Action's service-detection hack — the chart's `atscale-ingress-gateway` LoadBalancer is the front door and already carries all four ports.
- MetalLB assigns it the node IP (`/32`, per the runbook pattern — `10.0.0.4` here).
- Set `atscale-proxy.service.type: LoadBalancer`, `global.ingressDomain: <customer>.atscalehosted.com`, and inject the cert via `global.atscale.tls.tlsCrt`/`tlsKey` (proven) — or `existingSecret` (docs alternative).
- The Action's old `atscale-ingress-gateway` detection branch was the correct one; the nginx-addon / custom-Ingress / `atscale-proxy`-name / port-443-scan paths are all dead code now.

D3 is **closed.** Clincher: `microk8s status` on the working box shows the **`ingress` addon DISABLED** — enabled addons are only `dns`, `hostpath-storage`, `metallb` (+ auto `ha-cluster`/`helm`/`storage`). `cert-manager` is also disabled (consistent with the inline wildcard cert — no Let's Encrypt). The Action must enable **`dns hostpath-storage` + `metallb` only — never `ingress`.**

### 3.4 Decisions on the current-doc findings (from v0.3 §3.4)
- **Keycloak public IDP:** not using it — **local users only**. Standalone per-VM, not the customer-facing platform.
- **Infra requirements:** these are **public** in AtScale's docs — incorporated directly (§3.5), superseding the old runbook numbers.
- **MCP:** **enable the AtScale MCP service** in PoT envs (ships in the chart). Claude.ai web connection requires a publicly-trusted TLS cert (wildcard ✓), `admin`/`application_admin` role, and internet reachability. Bake MCP-enabled into the default values.
- **PgWire:** we'll **open 15432** directly, so the GKE PgWire-NLB pattern is **not relevant** here.
- **qa-perf:** a *reference* env, not an Azure golden env (it's OVH/K3s) — see the answer in the chat thread; useful for SRE resource limits and version-pin method only.

### 3.5 Authoritative reference data (AtScale current container docs)

**Sizing tiers** (single-node is officially supported for POC):

| | Bare Min – POC | Min – Test/Dev | Recommended – Prod |
|---|---|---|---|
| Nodes | 1 | 1–2 | 3 |
| CPU | **16 cores** | 32 cores | 48 cores |
| RAM | **64 GB** | 128 GB | 192 GB |
| Azure SKU | **`Standard_D16s_v5`** | `Standard_D16s_v5` / `D32_v5` / `F16as_v6` | `D32_v5` / `F16as_v6` |

POC supports a small DW workload up to ~100 GB. Must be **x86_64**. Embedded PostgreSQL `replica=1` is fine for PoT (no external DB needed); disks should be Premium SSD (~5000+ IOPS).

> **Field reconciliation (D1):** the table above is AtScale's *doc recommendation*. Our golden envs actually run `E8s_v3` (8/64) and are *underutilized* per Azure Advisor — so our **PoT default is `E8s_v3`** (same 64 GB RAM, half the cores, quota-friendly), parameterized up to `D16s_v5` if a PoT needs more concurrency.

**Required ingress ports:**

| Port | Purpose |
|---|---|
| 443 | Everything via the proxy: Web UI `/`, XMLA `/engine/xmla` (Excel/Power BI), API `/api`, auth `/auth`, monitoring `/monitoring` |
| 15432 | PGWire / SQL interface (BI tools) — **we open this** |
| 11111 | Thrift (optional) — open only if a BI tool needs it |
| 22 | SSH (operator) |
| ~~16443~~ | k8s API — **not an AtScale port; do not expose publicly** |

**Required egress** (engine must reach these): `license-prod-us.atscaleservices.com` (license validation), `billing-prod-us.atscaleservices.com` (usage). Allow these if egress is ever restricted.

Reference: `github.com/AtScaleInc/atscale-k8s-blueprints` (AtScale's own k8s setup blueprints).

### 3.6 CLOSED — hostname / cert / DNS alignment (resolved 2026-06-30)

Recon resolved both halves of the gap. **Option A is adopted.**

| Asset | What recon confirmed (2026-06-30) |
|---|---|
| Wildcard cert — private key | **`*.atscalehosted.com`** key = secret **`atscalehosted-com-cert-private-key`** in **`se-demo-keyvault`** (base64-encoded PEM so Azure won't mangle it; enabled). Chart wants base64, so the KV value feeds `tlsKey` directly. |
| Wildcard cert — public cert | Delivered as the CA bundle **`STAR_atscalehosted_com.zip`** (Google Drive, owner benjamin.jewell@) = leaf `.crt` + `.ca-bundle` intermediates. **Verified:** CN/SAN `*.atscalehosted.com` + `atscalehosted.com`, issuer **Sectigo … CA DV R36**, valid **2026-06-25 → 2027-01-09**. The chart's `tlsCrt` needs the **fullchain** (leaf + intermediates), base64. **DECISION (operator):** *not* uploaded to Key Vault — `deploy.sh` reads the fullchain from a **local PEM** (`CERT_PEM_FILE`/`CERT_PEM`); the private **key still defaults to Key Vault** (`atscalehosted-com-cert-private-key`). Build the fullchain with `cat STAR_atscalehosted_com.crt STAR_atscalehosted_com.ca-bundle > fullchain.pem`. **Verified 2026-06-30:** the KV private key's public key matches the Drive leaf cert (identical pubkey), and the leaf chains to a trusted root via the Sectigo R36 intermediate (`openssl verify` OK). Renewal note: expires **2027-01-09**. |
| DNS provider | **Cloudflare** hosts `atscalehosted.com` (confirmed not in any Azure DNS zone we control). Operator can add an A record manually now; Cloudflare API automatable in Phase 2. |

**Decision — Option A (keep `atscalehosted.com`):** prospect-facing domain; the wildcard cert is name-bound so it works for any `<customer>.atscalehosted.com` on any VM/IP. Per-PoT DNS reservation = **manual Cloudflare A record for v1** (`<customer>.atscalehosted.com` → that VM's public IP); the Phase 1 generator stubs this step generically (prints the required record + is ready for a Cloudflare-API call once a token is wired in Phase 2).

**Constraints (carry forward):** one A record **per PoT** (each VM has its own public IP — can't wildcard the A record); keep hostnames **one label** under the apex (`customer.atscalehosted.com` matches `*.atscalehosted.com`; `customer.poc.atscalehosted.com` would not).

*(Option B — pivot to `*.poc.atscale-se-demo.com` in Azure DNS — is no longer needed; recorded only as a fallback if Cloudflare access becomes a problem.)*

**Cert mechanism is now settled** (from §3.7): the demo env uses a **per-host Sectigo DV cert** for `demo2.poc.atscale-se-demo.com` (SANs `demo2.poc…` + `www.demo2.poc…`), injected **inline** as base64 `global.atscale.tls.tlsCrt`/`tlsKey` — *not* the wildcard and *not* `existingSecret`. For PoT the **`*.atscalehosted.com` wildcard is the better fit** (one cert covers every `<customer>.atscalehosted.com`, no per-host issuance) — injected the same proven inline way. So G1's cert side is fully understood; the only remaining blocker is the **DNS location** for `atscalehosted.com` (#A/#B above) + confirming the wildcard secret exists in `se-global-keyvault`.

### 3.7 Confirmed live config — demo2 @ chart `atscale-2026.5.0`

The real `helm get values` / `kubectl get svc` baseline the Phase 1 generator should target (validate unchanged at 2026.5.1):

| Item | Value |
|---|---|
| Chart / app version | `atscale-2026.5.0` (floor is 2026.5.1 — confirm parity) |
| Front-door service | `atscale-ingress-gateway` (LoadBalancer, MetalLB IP `10.0.0.4`), ports `80,443,11111,15432` |
| LB toggle | `atscale-proxy.service.type: LoadBalancer`, `replicaCount: 1` |
| Hostname | `global.ingressDomain: <host>` |
| TLS | inline `global.atscale.tls.tlsCrt` / `tlsKey` (base64); `caCerts: ""` |
| **MCP** | `atscale-mcp.enabled: true` — already on; service `atscale-mcp-server` (ClusterIP :3003) |
| Engine sizing | `global.resourcePreset: none` + `atscale-engine.resources.requests: {cpu: 500m, memory: 8Gi}` |
| Embedded DB | `db.persistence.size: 64Gi` (PG `replica=1` fine for PoT) |
| Encryption | `global.atscale.encryption.existingSecretEncryptionKeyRef: encryptionKey` |
| MicroK8s addons | **enabled:** `dns`, `hostpath-storage`, `metallb` (+ auto `ha-cluster`/`helm`/`storage`). **disabled (keep so):** `ingress`, `cert-manager`, `rbac`, `metrics-server`, `observability` |

*(Note: `resourcePreset: none` + explicit engine requests is the deliberate footprint tuning — keep it. `microk8s status` hangs on this box; not needed — the svc output already proves MetalLB is assigning the LB IP and no nginx ingress is in the path.)*

---

## 4. Delivery model (confirmed)
GitHub Action = canonical create path. Imperative logic → shared idempotent scripts invoked by both the Action and a local operator. Claude Code + Azure CLI = operator console for recon, triage/heal, teardown, and `values.yaml` repair across version drift.

---

## 5. Phased plan

**Phase 0 — Recon & baseline** *(nearly done)*
- ✅ Azure recon (sizing, NSG, DNS zones, Key Vaults) + on-box recon (demo2 @ 2026.5.0): D3 closed, values baseline captured (§3.7).
- ⏳ Remaining: confirm `*.atscalehosted.com` wildcard secret in `se-global-keyvault`; locate `atscalehosted.com` DNS (§3.6).

**Phase 1 — Harden the core deploy**
- Default VM `Standard_E8s_v3` (proven config) + Premium SSD; parameterize size (D1) and chart version (D2, default 2026.5.1+).
- **Re-architect ingress** (D3): enable **`dns hostpath-storage` + `metallb:<ip>/32` only — drop `ingress`**; delete the custom Ingress + service-detection; rely on the chart's `atscale-ingress-gateway` LoadBalancer (`atscale-proxy.service.type: LoadBalancer`); carry forward the §3.7 values (MCP on, `resourcePreset: none`, engine requests, db 64Gi).
- Cert (G1): pull `*.atscalehosted.com` from Key Vault → inject inline `global.atscale.tls.tlsCrt`/`tlsKey`; set `global.ingressDomain: <customer>.atscalehosted.com`.
- NSG = 443 + 15432 (+11111 optional) + 22; **close 16443**; verify license/billing egress (G4).
- Infra idempotency + cleanup-on-failure (G6); collision-safe naming (G7).

**Phase 2 — PoT wiring**
- Automate DNS A-record reservation `<customer>.atscalehosted.com` → public IP (mechanism per §7 #DNS).
- Define the seam to chain the data-backend/sample-content pipeline later (G2).

**Phase 3 — Lifecycle & ops (lightweight v1)** — manual teardown, but tag-driven (`Lifecycle`/`Schedule`/`Expiry`) so auto-stop/TTL drops in later (G3). Simple "active PoTs" view.

**Phase 4 — Orchestration & robustness** — shared-script refactor; Claude Code operator runbook (recon/heal/teardown); retries/state reconciliation on brittle steps.

**Phase 5 — Documentation & handoff** — operator runbook + this plan; publish to Field Engineering Confluence.

---

## 6. Inputs — captured vs. still-needed

**Captured (incl. portal recon 2026-06-30):**
- Golden envs (RG **`SE-DEMO`**, sub **`bab068b4-f668-4626-b938-eccf60a10f47`**, tenant ATSCALE-SE-DEMO.COM):
  - `se-demo-atscale` → **East US**, IP `172.203.218.112`, Ubuntu 24.04, `E8s_v3`, vnet `se-demo-atscale-vnet/default` (→ demo.poc.atscale-se-demo.com).
  - `se-demo-atscale2` → **Central US**, IP `172.169.248.80`, Ubuntu 20.04, `E8s_v3`, vnet `SE-Demo-atscale2-vnet/default` (→ demo2.poc.atscale-se-demo.com).
- **Region spread is real** (East US / Central US) — consistent with the vCPU-quota strategy.
- Wildcard cert: **`*.atscalehosted.com`**, base64 in **`se-demo-keyvault`** — private key secret **`atscalehosted-com-cert-private-key`** (confirmed enabled, 2026-06-30). Companion public-cert secret name TBD (same vault).
- **DNS:** `atscalehosted.com` is hosted in **Cloudflare** (confirmed 2026-06-30) — not Azure DNS. Manual A record per PoT for v1. Azure DNS zones present (RG `atscale-se-demo`): `atscale-se-demo.com`, `poc.atscale-se-demo.com`, `training.atscale-se-demo.com`.
- **NSG posture (golden envs):** catch-all `AllowTagCustomAnyInbound` 0.0.0.0/0 on both; atscale2 also explicit 443/80. Effectively open.
- **On-box (demo2 @ 2026.5.0):** front door `atscale-ingress-gateway` (LB, 80/443/11111/15432); MCP on; inline TLS; engine footprint tuned (§3.7). **D3 closed.**
- Version floor: **C2026.5.1+** (parameterized; demo runs 2026.5.0).
- Model: **self-contained VM per build**; **local users**; **MCP enabled**; **15432 open**; default size **`E8s_v3`** (parameterized, see D1).

**Still needed (small):**
1. ✅ **Key Vault** — private key confirmed: `atscalehosted-com-cert-private-key` in `se-demo-keyvault`. Public cert handled via **local fullchain PEM** (operator decision — not in KV).
2. ✅ **DNS** — confirmed: `atscalehosted.com` in **Cloudflare**; manual A record for v1 (§3.6 closed).
3. Confirm **2026.5.1** has the same values structure as the 2026.5.0 baseline (very likely; minor patch) + any LTS designation.
4. Cert renewal calendar item: `*.atscalehosted.com` expires **2027-01-09**.

---

## 7. Phase 0 recon — Azure CLI

VM, NSG, DNS-zone, Key-Vault, **and on-box (`helm`/`kubectl`)** recon are **DONE** (results in §3.7 / §6 / §3.6). The two outstanding commands resolved on 2026-06-30:

```bash
az account set --subscription bab068b4-f668-4626-b938-eccf60a10f47

# 1. Wildcard cert (DONE) → private key in se-demo-keyvault: secret 'atscalehosted-com-cert-private-key' (base64 PEM).
#    Optional follow-up to name the companion public-cert secret:
az keyvault secret list --vault-name se-demo-keyvault --query "[].name" -o table

# 2. atscalehosted.com DNS (DONE) → hosted in Cloudflare (not Azure DNS). Manual A record per PoT for v1.
```

*(Done — on-box, demo2: `helm get values` / `kubectl get svc` → front door `atscale-ingress-gateway` LB on 80/443/11111/15432, MCP on, inline TLS, footprint tuned. `microk8s status` hangs on this box but isn't needed.)*

---

## 8. Risks
- **Cost runaway** — `E8s_v3` is ~8× the dev box; un-torn-down envs bill fast. Tag-driven lifecycle (Phase 3); manual tracking until then.
- ~~Cert/DNS domain mismatch~~ **RESOLVED (§3.6):** cert private key confirmed in `se-demo-keyvault`; `atscalehosted.com` DNS in Cloudflare. Per-env DNS reservation is **manual for v1** (no longer a blocker); residual risk is the manual A-record step until Cloudflare-API automation lands in Phase 2.
- **vCPU quota** — `E8s_v3` = 8 cores each (half of `D16s_v5`), so the proven default is quota-friendly; still, concurrent PoTs add up → multi-region spread (already in use: East US / Central US) + a quota pre-flight check before provisioning.
- **License egress** — if networking is ever locked down, the engine must still reach the license/billing URIs (§3.5) or it won't validate.
- **Version parity** — baseline (§3.7) was read at 2026.5.0; target floor is 2026.5.1. Re-confirm the values structure is unchanged on 2026.5.1 before locking the generator (minor patch — low risk).

---

## 9. Immediate next steps
1. ✅ **Recon done** — §3.6 closed (cert in `se-demo-keyvault`; DNS in Cloudflare). Optional: name the companion public-cert secret via one read-only `az keyvault secret list`.
2. **In progress:** **Phase 1** = refactored `action.yml` + shared `deploy.sh`, built on the §3.7 baseline (`E8s_v3`, `atscale-ingress-gateway` LB, MetalLB, inline wildcard cert, MCP on, footprint tuning, NSG/egress). DNS-reservation is a **generic Cloudflare-ready stub** (manual A record for v1).
3. Validate values parity at chart **2026.5.1**; confirm public-cert secret name; wire Cloudflare API token (Phase 2).
