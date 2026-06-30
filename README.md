# AtScale Deploy Action (PoT)

Provisions one self-contained Azure VM per prospect and deploys AtScale for a
**Proof-of-Technology (PoT)** — a few days of hands-on testing. MicroK8s + Helm
on a single VM, fronted by the chart's own `atscale-ingress-gateway`
LoadBalancer. See `CLAUDE.md` and `docs/AtScale-PoT-Provisioning-Project-Plan.md`
for the authoritative spec.

## What it does
1. Provisions an Azure resource group + VM (`Standard_E8s_v3` default, Premium SSD, x86_64).
2. Opens 22 / 443 / 15432 (+ 11111 if Thrift); leaves 16443 closed. Locks the private IP to Static.
3. Pulls the `*.atscalehosted.com` wildcard cert from Azure Key Vault.
4. Installs MicroK8s + Helm and enables **only** `dns hostpath-storage` + `metallb:<nodeIP>/32` — **never** the `ingress` addon.
5. Deploys the AtScale chart with the §3.7 values baseline (MCP on, `resourcePreset: none`, tuned engine requests, 64Gi embedded PG), TLS injected inline.
6. Prints a generic Cloudflare A-record reservation (manual for v1) and the admin credentials.

## Architecture
- **`deploy.sh`** — the orchestrator. Runs both locally (operator console) and inside the Action. Provisions infra, fetches the cert, renders `runtime/values-<client>.yaml`, copies it to the VM, and runs the on-box bootstrap.
- **`scripts/bootstrap-node.sh`** — runs on the VM: MicroK8s + Helm + the chart.
- **`action.yml`** — thin composite wrapper: Azure OIDC login, then `deploy.sh create`.

The chart's `atscale-ingress-gateway` LoadBalancer is the single front door
(80/443/11111/15432). No nginx addon, no custom `Ingress`, no service detection.

## TLS cert
The wildcard `*.atscalehosted.com` **private key** lives in `se-demo-keyvault`
(`atscalehosted-com-cert-private-key`). The **public cert** is delivered as the
CA bundle `STAR_atscalehosted_com.zip` (leaf `.crt` + `.ca-bundle`). The chart's
inline `tlsCrt` needs the **fullchain**, supplied as a local PEM:

```bash
unzip -o STAR_atscalehosted_com.zip
cat STAR_atscalehosted_com.crt STAR_atscalehosted_com.ca-bundle > runtime/fullchain.pem
export CERT_PEM_FILE=$PWD/runtime/fullchain.pem   # cert from disk
# key still comes from Key Vault by default (needs `az login`);
# or supply it locally too: export KEY_PEM_FILE=$PWD/runtime/atscalehosted.key
```

TLS resolution precedence per item: inline `*_PEM` content → `*_PEM_FILE` →
Key Vault secret. `runtime/`, `*.pem`, `*.crt`, `*.ca-bundle` are gitignored.

## Local usage (operator)
```bash
az login
export CLIENT_ID=acme
export SSH_PRIVATE_KEY_FILE=~/.ssh/id_rsa SSH_PUBLIC_KEY_FILE=~/.ssh/id_rsa.pub
export CERT_PEM_FILE=$PWD/runtime/fullchain.pem   # see "TLS cert" above
./deploy.sh create
```
Other subcommands: `./deploy.sh render-values` (emit values.yaml only — fully
offline if both `CERT_PEM_FILE` and `KEY_PEM_FILE` are set),
`./deploy.sh dns-record` (print the Cloudflare A record for an existing PoT).

Generated per-env `values.yaml` lands in the gitignored `runtime/` dir — it
embeds the wildcard TLS key and **must never be committed**.

## GitHub Action usage
Create `.github/workflows/deploy-atscale.yml`:

```yaml
name: Deploy AtScale PoT
on:
  workflow_dispatch:
    inputs:
      client_id: { description: "Client name (e.g. acme)", required: true }
      region:    { description: "Azure region", default: "eastus" }

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: your-org/atscale-deploy-action@v1
        with:
          client_id:             ${{ inputs.client_id }}
          region:                ${{ inputs.region }}
          azure_client_id:       ${{ secrets.AZURE_CLIENT_ID }}
          azure_tenant_id:       ${{ secrets.AZURE_TENANT_ID }}
          azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          ssh_public_key:        ${{ secrets.SSH_PUBLIC_KEY }}
          ssh_private_key:       ${{ secrets.SSH_PRIVATE_KEY }}
```

The Azure OIDC identity needs `get` on the Key Vault secrets and contributor on
the resource group. After a run, add the Cloudflare A record
(`<client>.atscalehosted.com` → the VM's public IP) — manual for v1.
