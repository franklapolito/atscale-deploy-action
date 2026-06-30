# CLAUDE.md — AtScale PoT Provisioning

## What this is
Automated provisioning for AtScale **Proof-of-Technology (PoT)** environments on Azure — one self-contained VM per prospect (MicroK8s + Helm), for a few days of hands-on testing.

## Source of truth
**`AtScale-PoT-Provisioning-Project-Plan.md`** is the authoritative spec — read it first. It's a **living document**: update it as decisions/build land, and bump the version line at the top.

## Deliverables (Phase 1)
- Refactor **`action.yml`** at the repo root (composite GitHub Action — the canonical "create" path).
- Write a shared **`deploy.sh`** the Action calls and that also runs locally (the operator console).
- GitHub Actions stays the canonical create path; this repo is where we build/test it. Claude Code is the dev + ad-hoc ops environment, **not** a replacement for the Action.

## Hard guardrails — do NOT violate
- **Ingress:** enable MicroK8s addons **`dns hostpath-storage` + `metallb:<nodeIP>/32` ONLY. Never enable the `ingress` addon. No custom `Ingress` resource.** The chart's **`atscale-ingress-gateway`** LoadBalancer is the single front door (ports 80/443/11111/15432). Delete the old nginx-addon + service-detection logic.
- **Version:** chart floor **C2026.5.1+**, parameterized (demo runs 2026.5.0 — confirm values parity at 2026.5.1 before locking).
- **VM:** default **`Standard_E8s_v3`** (8 vCPU/64 GB), Premium SSD, x86_64 — parameterized (region too).
- **Cert:** wildcard **`*.atscalehosted.com`** from Azure Key Vault, injected inline as `global.atscale.tls.tlsCrt`/`tlsKey`. **Never commit certs/keys/credentials to the repo.**
- **Values baseline (plan §3.7):** `atscale-mcp.enabled: true`, `atscale-proxy.service.type: LoadBalancer` (+ `replicaCount: 1`), `global.resourcePreset: none`, `atscale-engine.resources.requests {cpu: 500m, memory: 8Gi}`, `db.persistence.size: 64Gi`, `global.ingressDomain: <customer>.atscalehosted.com`.
- **Network:** open 443 + 15432 (+11111 if Thrift) + 22; **close 16443**. Allow egress to `license-prod-us.atscaleservices.com` + `billing-prod-us.atscaleservices.com`.
- **DNS:** one A record per PoT (`<customer>.atscalehosted.com` → that VM's public IP); single-label under the apex so the wildcard cert matches. Zone may live in another sub or external — write it wherever it's authoritative (plan §3.6).

## Live infra facts
- Subscription `bab068b4-f668-4626-b938-eccf60a10f47` (se-demo), RG `SE-DEMO`, tenant ATSCALE-SE-DEMO.COM.
- Key Vaults: `se-global-keyvault`, `se-demo-keyvault`. Azure DNS zones (RG `atscale-se-demo`): `atscale-se-demo.com`, `poc.atscale-se-demo.com`. (`atscalehosted.com` not in this sub — see §3.6.)
- Atlassian Confluence/Jira cloudId: `bd858cd2-d3d7-466e-bc6b-97c368369965`.

## Safety when operating against live Azure
- **`se-demo-atscale` (East US, 172.203.218.112) and `se-demo-atscale2` (Central US, 172.169.248.80) are REFERENCE / PRODUCTION demo boxes — read-only. Do NOT modify, redeploy, restart, or change their config.**
- **Confirm with the operator before any billable or destructive op** — `az vm create`/`delete`, `helm install`/`uninstall`, DNS writes, NSG changes. No unattended teardown.
- Secrets stay in Key Vault; pull at deploy time. Don't echo private keys.

## Repo & git hygiene
- Layout: `action.yml` + `deploy.sh` + `README.md` + `CLAUDE.md` at root; plan in `docs/`.
- **Never commit secrets or generated values.** `deploy.sh` writes its per-env `values.yaml` (which embeds the wildcard TLS key) into a gitignored `runtime/` dir — not the repo. Cert/key/creds come from Key Vault at runtime.
- Work on a **feature branch** and open a **PR**; don't push straight to `main` (the action may be consumed elsewhere via `uses:`).
- The action is consumed by ref — tag a release (`v1`/`v2`) when a change is ready to roll out.

## Two open items to resolve first
1. Confirm the `*.atscalehosted.com` wildcard secret in `se-global-keyvault` (`az keyvault secret list`).
2. Locate the `atscalehosted.com` DNS zone (other sub vs external) — plan §3.6. Only the DNS-record step is gated on this; stub it generically until resolved.
