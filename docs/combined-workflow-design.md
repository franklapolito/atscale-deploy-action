# Combined Workflow Design — "Use-Case Bundle Generator" (G2 / Phase 2 seam)

**Status:** design pass (2026-07-01) · **Owner:** Frank
**Scope:** design only — nothing implemented yet. This is the seam the Project
Plan defers as **G2** ("data backend / sample content — design the seam to chain
later") and **Phase 2 — PoT wiring**.

## 1. Goal

One `workflow_dispatch` that, given a `client_id` (+ a data-shape fingerprint),
stands up a complete AtScale PoT end-to-end:

```
deploy-action (Azure VM + AtScale)  ┐
                                    ├─→  assemble connections.yaml  →  ps-utils:
snowflake-provision (SF footprint)  ┘        create-data-source → generate-sml
                                             → deploy-catalog → generate-data
```

Two provisioners run in parallel; ps-utils runs after both, against the live
AtScale instance, pointed at the freshly-provisioned Snowflake.

## 2. What each piece produces / consumes today

| Piece | Produces | Consumes | CI-ready? |
|---|---|---|---|
| `atscale-deploy-action` | VM at `<client>.atscalehosted.com`, `atscale-mcp` enabled | Azure OIDC, TLS from KV/PEM, ssh keys | ✅ live-validated locally; **no Action outputs**; never run *in* CI |
| `atscale-snowflake-provision` | `connections-<c>.yaml` fragment (`users:` + `connections.<c>.sql:`) + private key | admin `snow` connection | logic ✅ (Stages 0–4); Action path untested (Stage 5) |
| `ps-utils` (`atscale-utils` CLI, Node 18) | data source + SML + deployed catalog + synthetic data | **one** `connections.yaml` with BOTH a `sql:` block AND an `atscale:` block; a `data-shape.yaml` fingerprint; a git repo in AtScale | n/a (consumed) |

## 3. The seam problems (what the design has to solve)

### 3.1 `connections.yaml` assembly — the central data-flow gap
`ps-utils` reads a **single** `connections.yaml` needing two things the current
tools don't jointly produce:
- the **`sql:` + `users:`** half → **emitted by snowflake-provision** ✅
- an **`atscale:`** connection block (design-center `url` + admin creds) →
  **nobody emits this today** ❌

So the combined workflow must **merge** the Snowflake fragment with a generated
`atscale:` block:

```yaml
users:
  pot_<c>_svc:                 # from snowflake-provision fragment
    username: POT_<C>_SVC
    privateKeyPath: ./pot_<c>_key.p8      # NOTE: path rewritten into ps-utils workdir
  atscale_admin:               # NEW — from deploy-action
    username: <atscale admin user>
    password: <atscale admin password>    # ::add-mask::
connections:
  <c>_snowflake:               # from snowflake-provision fragment
    sql: { dialect: snowflake, account: …, warehouse: POT_<C>_WH_M, database: POT_<C>_DB, schema: SOURCE, role: POT_<C>_ROLE, snowflake_user: pot_<c>_svc }
  <c>_atscale:                 # NEW
    atscale:
      url: https://<client>.atscalehosted.com
      user: atscale_admin
      insecure: true
```

ps-utils then runs with `--atscale-connection-name <c>_atscale` and
`--new-connection-name/--connection-name <c>_snowflake`.

### 3.2 DNS is manual for v1 → the runner can't resolve the AtScale host
`atscale.url` is `https://<client>.atscalehosted.com`, but the A record is added
by hand (Cloudflare-API automation is Phase 2). A GitHub runner can't reach that
name. Options:

| Option | How | Verdict |
|---|---|---|
| (a) Manual DNS gate | Pause workflow (environment approval) until operator adds A record | Works, but defeats "one-click" and adds latency |
| (b) Direct IP + `insecure` | `url: https://<public_ip>`, skip TLS verify | Cert SAN is `*.atscalehosted.com` (IP won't match) **and** Keycloak OIDC redirects embed the hostname → auth-code flow for `deploy-catalog` likely breaks |
| **(c) `/etc/hosts` injection** ✅ | Runner adds `<public_ip> <client>.atscalehosted.com` before ps-utils | **Recommended.** Name resolves locally (no public DNS needed), cert SAN matches, Keycloak redirects work. Zero dependency on the manual step. |
| (d) Cloudflare API | Bring Phase 2 forward | Correct long-term for *user* access, but propagation delay; do it anyway for real users, not for the CI reachability problem |

**Recommendation:** (c) for the automated chain now; (d) later so end users can
reach the box. They're not mutually exclusive — hosts-file is how *the runner*
reaches it; Cloudflare is how *humans* do.

### 3.3 AtScale admin credentials handoff
`deploy-catalog`/`create-data-source` must authenticate to the design center.
Today those creds are **generated on-box and printed by `bootstrap-node.sh`**.
Two ways to get them to ps-utils:

- **Scrape stdout** → parse the printed credentials into a masked GITHUB_OUTPUT. Fragile.
- **Inject a deterministic admin credential** at deploy time (new input →
  `values.yaml`/bootstrap), so the workflow already knows it. ✅ **Recommended** —
  no scraping, and the combined workflow can build the `atscale:` block directly.
  (Prefer an **API token** if the chart can seed one; else username/password for
  the Keycloak cookie flow `deploy-catalog` needs.)

### 3.4 Readiness gate
`deploy.sh create` returns after the Helm install kicks off — **before** AtScale
is actually serving. ps-utils would race it. Need a health-check step polling
`https://<host>/` (design-center login) until 200 before ps-utils runs. Put this
in the combined workflow (or as a `deploy-action` post-step that blocks on ready).

### 3.5 Two more inputs the bundle needs (not derivable)
- **`data-shape.yaml` fingerprint** — input to `generate-data` (produced offline by
  `extract-data-shape-from-connection` against some reference source). The bundle
  must carry this as an artifact/input.
- **A git repo in AtScale** for `deploy-catalog` (`--repo-name`/`--repo-id`) — must
  pre-exist in the instance. Decide whether deploy-action seeds one or it's a fixed
  convention.

## 4. Proposed output contract for `atscale-deploy-action`

Add to `action.yml` `outputs:` (values written to `$GITHUB_OUTPUT` by deploy.sh —
it already computes all of these):

```yaml
outputs:
  ingress_domain:  # <client>.atscalehosted.com
  engine_url:      # https://<client>.atscalehosted.com
  public_ip:       # LB public IP (for /etc/hosts injection — §3.2c)
  azure_fqdn:      # Azure public-IP FQDN (fallback)
  resource_group:  # rg-poc-<client> (for teardown)
  atscale_admin_user / atscale_admin_secret  # §3.3 (masked) — if we adopt injected creds
```

`snowflake-provision` already exposes `connections_fragment` + `private_key`. No
change needed there beyond confirming Stage 5.

## 5. Combined workflow DAG

```
job: provision   (parallel)
 ├─ deploy-action     → ingress_domain, engine_url, public_ip, admin creds
 └─ snowflake-provision → connections_fragment, private_key
        │
job: wire   (needs: provision)
 ├─ assemble connections.yaml   (merge SF fragment + atscale block — §3.1)
 ├─ inject /etc/hosts           (public_ip → ingress_domain — §3.2c)
 ├─ health-check                (poll engine_url until ready — §3.4)
 └─ ps-utils (Node 18, npm i -g @atscale/ps-utils):
       1. generate-data-from-data-shape-to-connection   (--drop-if-exists --create-tables)  → populate SOURCE
       2. generate-sml-from-connection                  (--connection-name <c>_snowflake)   → ./sml
       3. atscale-create-data-source                    (--aggregate-schema AGGREGATES)
       4. atscale-deploy-catalog                         (--sml-dir ./sml --repo-name …)
```

> **Ordering note:** the ps-utils README lists create-data-source → generate-sml
> → deploy-catalog → generate-data, but for a *use-case bundle* it's more natural
> to **generate data first** (so SML is inferred from a populated schema), then
> model + register + deploy. Open decision — depends on whether SML generation
> samples live data (it does: `--sample-size` default 250).

## 6. Decisions

**Resolved (operator, 2026-07-01):**
1. **DNS/reachability:** ✅ **`/etc/hosts` injection** (§3.2c) for the CI runner. Cloudflare API added later, separately, for human access.
2. **AtScale creds:** ✅ **inject deterministic admin creds** at deploy time (§3.3); prefer an API token if the chart can seed one, else username/password for the Keycloak cookie flow.
6. **Home:** ✅ **new dedicated repo** (e.g. `atscale-pot-bundle`) — the orchestrator consumes both Actions via `uses:`.

**Resolved during the wire build (2026-07-01):**
3. **ps-utils op ordering:** ✅ **data-first** (generate-data → generate-sml → create-data-source → deploy-catalog) — SML samples live data.
4. **AtScale git repo** for deploy-catalog: ✅ **throwaway private GitHub repo per PoT** (`atscale-pot-sml-<client>`), tokenized pull URL, deleted on teardown.
5. **data-shape fingerprint:** ✅ **committed sample** for now (`data-shapes/`), input-driven later.
6. **Region/quota:** ✅ pinned default → `westus3` (deploy.sh + smoke test); a proper `az vm list-usage` pre-flight is a deferred follow-up. Context: se-demo caps ~10 cores/region; `E8s_v3` needs ≥8 free in BOTH *Total Regional Cores* AND *standardESv3Family* (only westus3/westus/southcentral/northcentral qualified on 2026-07-01).

**Still open — the big one:**
7. **Use-case → model engine (NEW, from the Demo-on-Demand one-pager):** the use-case→data+model path exists **twice** — (a) **ps-utils in-CI** (`generate-data` + `generate-sml`, already wired in `pot-bundle.yml`), and (b) **two Field Engineering Claude skills** — *Use-Case Bundle Generator* (company URL → loadable dataset bundle) + *AtScale SML Model Generator* (bundle → validated SML repo). Options: **A** ps-utils only (self-contained, wired today) · **B** FE skills (richer URL→bundle→SML, but hosted/less headless-friendly) · **C** both (skills produce the bundle/SML, ps-utils loads+deploys — likely the real answer). *Action: locate + read the two FE skills (Confluence / FE skills repo) before committing.*

## 7. Build sequence — status (2026-07-01)

1. ✅ `deploy-action` output contract (§4).
2. ✅ Both Actions CI-proven standalone (snowflake Stage 5; deploy-action OIDC path).
3. ✅ `wire` job built + reviewed (assembly + hosts + health-check + ps-utils tail + teardown).
4. ✅ Blockers + billing-safety review fixes merged.
5. ⬜ **NEXT — seam-test live run (do first):** trimmed dispatch (`seam_test_only=true`)
   through `create-data-source`, no data-shape/GH_PAT needed — proves the never-run
   live integration (OIDC deploy → SF → hosts → health-check → assemble → ps-utils
   authenticates to live AtScale + registers the data source → teardown).
6. ⬜ First FULL run (data-shape sample + `GH_PAT`), then use-case selection (§7 open
   decision), BI + MCP-agent steps, Slack trigger, scale guardrails.
```
