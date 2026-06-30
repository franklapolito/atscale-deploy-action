#!/usr/bin/env bash
#
# deploy.sh — AtScale PoT provisioning (operator console + GitHub Action body).
#
# One self-contained Azure VM per prospect: MicroK8s + Helm + the AtScale chart,
# fronted by the chart's own `atscale-ingress-gateway` LoadBalancer. Runs both
# locally (operator) and inside the composite GitHub Action (which only logs
# into Azure via OIDC and then calls this script).
#
# Built on the plan §3.7 baseline. See CLAUDE.md for the hard guardrails.
#
# Subcommands:
#   create        (default) provision infra + deploy + DNS stub
#   render-values render runtime/values-<client>.yaml only (no Azure calls)
#   dns-record    print/emit the Cloudflare A record for an existing PoT
#
# All config is via environment variables (see CONFIG below). Required: CLIENT_ID.
#
set -euo pipefail

# ----------------------------------------------------------------------------
# CONFIG (env-overridable; defaults encode the plan §3.7 baseline)
# ----------------------------------------------------------------------------
CLIENT_ID="${CLIENT_ID:?CLIENT_ID is required (e.g. acme)}"

REGION="${REGION:-eastus}"
VM_SIZE="${VM_SIZE:-Standard_E8s_v3}"          # D1: proven default; bump to Standard_D16s_v5 for more concurrency
CHART_VERSION="${CHART_VERSION:-2026.5.1}"     # D2: floor C2026.5.1+
IMAGE="${IMAGE:-Ubuntu2404}"
OS_DISK_SIZE_GB="${OS_DISK_SIZE_GB:-256}"      # holds images + 64Gi embedded PG
DISK_SKU="${DISK_SKU:-Premium_LRS}"            # PG needs ~5000+ IOPS
ADMIN_USERNAME="${ADMIN_USERNAME:-atscale}"

BASE_DOMAIN="${BASE_DOMAIN:-atscalehosted.com}"
INGRESS_DOMAIN="${INGRESS_DOMAIN:-${CLIENT_ID}.${BASE_DOMAIN}}"

# Azure / Key Vault (live infra facts — CLAUDE.md)
SUBSCRIPTION="${SUBSCRIPTION:-bab068b4-f668-4626-b938-eccf60a10f47}"
KEYVAULT="${KEYVAULT:-se-demo-keyvault}"
CERT_SECRET="${CERT_SECRET:-atscalehosted-com-cert}"             # public cert in KV (fallback if no local PEM)
KEY_SECRET="${KEY_SECRET:-atscalehosted-com-cert-private-key}"   # private key — confirmed in se-demo-keyvault

# TLS material may also be supplied locally (operator's choice — plan §3.6):
#   *_PEM = inline PEM content   *_PEM_FILE = path to a PEM file
# Precedence per item: inline content > file > Key Vault secret above.
# CERT must be the FULLCHAIN (leaf + intermediates). KEY defaults to Key Vault.
CERT_PEM="${CERT_PEM:-}"
CERT_PEM_FILE="${CERT_PEM_FILE:-}"
KEY_PEM="${KEY_PEM:-}"
KEY_PEM_FILE="${KEY_PEM_FILE:-}"

# Networking
OPEN_THRIFT="${OPEN_THRIFT:-false}"            # open 11111 only if a BI tool needs Thrift
# Ports: 22 (ops), 443 (everything via proxy), 15432 (PGWire). 16443 (k8s API) is
# deliberately NEVER opened (default-deny inbound keeps it closed).

# Chart values knobs (§3.7)
ENCRYPTION_SECRET_REF="${ENCRYPTION_SECRET_REF:-}"  # empty => let the chart generate the encryption key (fresh PoT)
ENGINE_CPU="${ENGINE_CPU:-500m}"
ENGINE_MEM="${ENGINE_MEM:-8Gi}"
DB_SIZE="${DB_SIZE:-64Gi}"

# DNS (Cloudflare — §3.6). If a token+zone are present we could call the API;
# for v1 the stub just prints the record the operator adds manually.
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ZONE_ID="${CLOUDFLARE_ZONE_ID:-}"

# SSH: provide content (Action) OR a file path (local).
SSH_PRIVATE_KEY="${SSH_PRIVATE_KEY:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-$HOME/.ssh/id_rsa}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"

# Derived names (collision-safe per client — G7)
RG="${RG:-rg-poc-${CLIENT_ID}}"
VM="${VM:-vm-atscale-${CLIENT_ID}}"
DNS_LABEL="${DNS_LABEL:-atscale-${CLIENT_ID}}"   # Azure public-IP label (fallback FQDN)
NAMESPACE="${NAMESPACE:-atscale}"
CHART_OCI="${CHART_OCI:-oci://registry-1.docker.io/atscaleinc/atscale}"

# Runtime (gitignored — embeds the wildcard TLS key)
RUNTIME_DIR="${RUNTIME_DIR:-runtime}"
VALUES_FILE="${RUNTIME_DIR}/values-${CLIENT_ID}.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { echo "[deploy $(date -u +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  local missing=()
  for c in "$@"; do have "$c" || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required commands: ${missing[*]}"
}

# Resolve SSH key material to on-disk paths (chmod 600) under RUNTIME_DIR.
ensure_ssh_keys() {
  mkdir -p "$RUNTIME_DIR"
  if [ -n "$SSH_PRIVATE_KEY" ]; then
    SSH_PRIVATE_KEY_FILE="${RUNTIME_DIR}/ssh_key"
    printf '%s\n' "$SSH_PRIVATE_KEY" > "$SSH_PRIVATE_KEY_FILE"
    chmod 600 "$SSH_PRIVATE_KEY_FILE"
  fi
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    SSH_PUBLIC_KEY_FILE="${RUNTIME_DIR}/ssh_key.pub"
    printf '%s\n' "$SSH_PUBLIC_KEY" > "$SSH_PUBLIC_KEY_FILE"
    chmod 644 "$SSH_PUBLIC_KEY_FILE"
  fi
  [ -f "$SSH_PRIVATE_KEY_FILE" ] || die "no SSH private key (set SSH_PRIVATE_KEY or SSH_PRIVATE_KEY_FILE)"
  [ -f "$SSH_PUBLIC_KEY_FILE" ]  || die "no SSH public key (set SSH_PUBLIC_KEY or SSH_PUBLIC_KEY_FILE)"
}

ssh_vm() {
  ssh -i "$SSH_PRIVATE_KEY_FILE" -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
      "${ADMIN_USERNAME}@${PUBLIC_IP}" "$@"
}
scp_vm() {
  scp -i "$SSH_PRIVATE_KEY_FILE" -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile=/dev/null "$@"
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------
preflight() {
  require_cmds az ssh scp
  az account show >/dev/null 2>&1 || die "not logged into Azure (run 'az login' or use OIDC in the Action)"
  az account set --subscription "$SUBSCRIPTION"
  log "subscription set to $SUBSCRIPTION"
}

provision_infra() {
  ensure_ssh_keys

  # Resource group (idempotent)
  if [ "$(az group exists --name "$RG")" = "true" ]; then
    log "resource group $RG exists — reusing"
  else
    log "creating resource group $RG in $REGION"
    az group create --name "$RG" --location "$REGION" \
      --tags Lifecycle=PoT Schedule=BusinessHours Client="$CLIENT_ID" >/dev/null
  fi

  # VM (idempotent: skip create if present — G6)
  if az vm show -g "$RG" -n "$VM" >/dev/null 2>&1; then
    log "VM $VM exists — reusing (no re-create)"
  else
    log "creating VM $VM ($VM_SIZE, $DISK_SKU ${OS_DISK_SIZE_GB}GB)"
    az vm create \
      --resource-group "$RG" \
      --name "$VM" \
      --image "$IMAGE" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USERNAME" \
      --ssh-key-values "$(cat "$SSH_PUBLIC_KEY_FILE")" \
      --public-ip-sku Standard \
      --public-ip-address-dns-name "$DNS_LABEL" \
      --os-disk-size-gb "$OS_DISK_SIZE_GB" \
      --storage-sku "$DISK_SKU" \
      --tags Lifecycle=PoT Schedule=BusinessHours Client="$CLIENT_ID" >/dev/null
  fi

  # NSG ports — 22/443/15432 (+11111 if Thrift). 16443 is NOT opened.
  local ports="22,443,15432"
  [ "$OPEN_THRIFT" = "true" ] && ports="${ports},11111"
  log "opening inbound ports: $ports  (16443 intentionally left closed)"
  az vm open-port -g "$RG" -n "$VM" --port "$ports" --priority 1010 >/dev/null

  # Lock the private IP to Static (keep — original behavior)
  local private_ip nic_id nic_name ipcfg
  private_ip="$(az vm show -d -g "$RG" -n "$VM" --query privateIps -o tsv)"
  nic_id="$(az vm show -g "$RG" -n "$VM" --query 'networkProfile.networkInterfaces[0].id' -o tsv)"
  if [ -n "$private_ip" ] && [ -n "$nic_id" ]; then
    nic_name="$(basename "$nic_id")"
    ipcfg="$(az network nic show --ids "$nic_id" --query 'ipConfigurations[0].name' -o tsv)"
    az network nic ip-config update -g "$RG" --nic-name "$nic_name" --name "$ipcfg" \
      --set privateIPAllocationMethod=Static --private-ip-address "$private_ip" >/dev/null
    log "locked private IP $private_ip to Static"
  else
    log "WARNING: could not resolve private IP / NIC — skipping static lock"
  fi

  PUBLIC_IP="$(az vm show -d -g "$RG" -n "$VM" --query publicIps -o tsv)"
  FQDN="$(az network public-ip list -g "$RG" --query '[0].dnsSettings.fqdn' -o tsv)"
  [ -n "$PUBLIC_IP" ] || die "could not resolve public IP"
  log "public IP = $PUBLIC_IP   (Azure FQDN = ${FQDN:-none})"
}

# Resolve one TLS item to single-line base64(PEM) on stdout. Precedence:
# inline content > local file > Key Vault. KV already stores base64(PEM) so it
# passes through; local PEM/content is base64-encoded here. Returns nonzero on
# failure (caller reports — never die() inside $() ).
resolve_tls() {
  local content="$1" file="$2" kv_secret="$3"
  if [ -n "$content" ]; then
    printf '%s' "$content" | base64 | tr -d '\n'
  elif [ -n "$file" ]; then
    [ -f "$file" ] || return 1
    base64 < "$file" | tr -d '\n'
  else
    az keyvault secret show --vault-name "$KEYVAULT" --name "$kv_secret" --query value -o tsv
  fi
}

fetch_cert() {
  local cert_src="KeyVault:$CERT_SECRET"
  [ -n "$CERT_PEM_FILE" ] && cert_src="$CERT_PEM_FILE"
  [ -n "$CERT_PEM" ] && cert_src="<inline>"
  log "resolving TLS material (cert source: $cert_src)"
  TLS_CRT_B64="$(resolve_tls "$CERT_PEM" "$CERT_PEM_FILE" "$CERT_SECRET")" || true
  TLS_KEY_B64="$(resolve_tls "$KEY_PEM"  "$KEY_PEM_FILE"  "$KEY_SECRET")"  || true
  [ -n "$TLS_CRT_B64" ] || die "could not resolve TLS cert — set CERT_PEM_FILE (fullchain) / CERT_PEM, or ensure '$CERT_SECRET' in $KEYVAULT"
  [ -n "$TLS_KEY_B64" ] || die "could not resolve TLS key — set KEY_PEM_FILE / KEY_PEM, or ensure '$KEY_SECRET' in $KEYVAULT"
}

# Catch the common fullchain mistakes BEFORE deploy (wrong order, missing
# intermediates, mismatched key). The chart's inline tlsCrt must be the
# FULLCHAIN, leaf-first: `cat leaf.crt ca-bundle > fullchain.pem`.
validate_tls() {
  have openssl || { log "WARNING: openssl not found — skipping TLS validation"; return 0; }
  local d; d="$(mktemp -d)"
  trap 'rm -rf "$d"' RETURN
  printf '%s' "$TLS_CRT_B64" | base64 -d > "$d/crt.pem" 2>/dev/null || die "TLS cert is not valid base64"
  printf '%s' "$TLS_KEY_B64" | base64 -d > "$d/key.pem" 2>/dev/null || die "TLS key is not valid base64"

  openssl x509 -in "$d/crt.pem" -noout 2>/dev/null || die "TLS cert: first PEM block is not a valid certificate"

  local n; n="$(grep -c 'BEGIN CERTIFICATE' "$d/crt.pem" || true)"
  if [ "${n:-0}" -lt 2 ]; then
    log "WARNING: cert has ${n:-0} certificate(s) — no intermediates. The chart needs the FULLCHAIN; leaf-only often fails. Build: cat leaf.crt ca-bundle > fullchain.pem"
  else
    log "cert chain: $n certificates (leaf + intermediates) OK"
  fi

  # The FIRST cert must be the leaf, not a CA (classic wrong-order failure).
  if openssl x509 -in "$d/crt.pem" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE'; then
    die "TLS cert order is wrong: the first certificate is a CA. Fullchain must be leaf-first: cat leaf.crt ca-bundle > fullchain.pem"
  fi

  # Private key must match the leaf cert.
  local cpub kpub
  cpub="$(openssl x509 -in "$d/crt.pem" -noout -pubkey 2>/dev/null | openssl md5)"
  kpub="$(openssl pkey -in "$d/key.pem" -pubout 2>/dev/null | openssl md5)"
  [ -n "$cpub" ] && [ "$cpub" = "$kpub" ] || die "TLS key does not match the leaf certificate (public keys differ)"
  log "TLS key matches leaf cert OK"
}

render_values() {
  mkdir -p "$RUNTIME_DIR"
  : "${TLS_CRT_B64:=__CERT_NOT_FETCHED__}"
  : "${TLS_KEY_B64:=__KEY_NOT_FETCHED__}"

  log "rendering $VALUES_FILE (ingressDomain=$INGRESS_DOMAIN)"
  {
    echo "# Generated by deploy.sh for PoT '${CLIENT_ID}'. DO NOT COMMIT — embeds the TLS private key."
    echo "# Baseline: plan §3.7 (chart ${CHART_VERSION})."
    echo "global:"
    echo "  ingressDomain: \"${INGRESS_DOMAIN}\""
    echo "  resourcePreset: none"
    echo "  atscale:"
    echo "    tls:"
    echo "      tlsCrt: \"${TLS_CRT_B64}\""
    echo "      tlsKey: \"${TLS_KEY_B64}\""
    echo "      caCerts: \"\""
    if [ -n "$ENCRYPTION_SECRET_REF" ]; then
      echo "    encryption:"
      echo "      existingSecretEncryptionKeyRef: \"${ENCRYPTION_SECRET_REF}\""
    fi
    echo "atscale-proxy:"
    echo "  service:"
    echo "    type: LoadBalancer"
    echo "  replicaCount: 1"
    echo "atscale-mcp:"
    echo "  enabled: true"
    echo "atscale-engine:"
    echo "  resources:"
    echo "    requests:"
    echo "      cpu: \"${ENGINE_CPU}\""
    echo "      memory: \"${ENGINE_MEM}\""
    echo "db:"
    echo "  persistence:"
    echo "    size: \"${DB_SIZE}\""
  } > "$VALUES_FILE"
  chmod 600 "$VALUES_FILE"
}

wait_for_ssh() {
  log "waiting for SSH on $PUBLIC_IP"
  for i in $(seq 1 30); do
    if ssh_vm true 2>/dev/null; then log "SSH is up"; return 0; fi
    sleep 10
  done
  die "SSH did not come up on $PUBLIC_IP"
}

bootstrap_node() {
  log "copying bootstrap script + values to VM"
  scp_vm "${SCRIPT_DIR}/scripts/bootstrap-node.sh" "${ADMIN_USERNAME}@${PUBLIC_IP}:/home/${ADMIN_USERNAME}/bootstrap-node.sh"
  scp_vm "$VALUES_FILE" "${ADMIN_USERNAME}@${PUBLIC_IP}:/home/${ADMIN_USERNAME}/values.yaml"
  log "running on-box bootstrap (MicroK8s + Helm + chart)"
  ssh_vm "chmod +x /home/${ADMIN_USERNAME}/bootstrap-node.sh && \
          CHART_OCI='${CHART_OCI}' /home/${ADMIN_USERNAME}/bootstrap-node.sh \
          '${CHART_VERSION}' '/home/${ADMIN_USERNAME}/values.yaml' '${NAMESPACE}'"
}

reserve_dns() {
  # §3.6: DNS is in Cloudflare. v1 = manual A record. Stub is API-ready.
  echo "----------------------------------------------------------------"
  echo "DNS RESERVATION (Cloudflare — manual for v1):"
  echo "  Add an A record:  ${INGRESS_DOMAIN}  ->  ${PUBLIC_IP}  (proxied: OFF / DNS-only)"
  if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_ZONE_ID" ]; then
    echo "  CLOUDFLARE_API_TOKEN + ZONE_ID present — Phase 2 will POST this record automatically."
    # Phase 2 stub (intentionally not executed in v1):
    # curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
    #   -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" -H "Content-Type: application/json" \
    #   --data "{\"type\":\"A\",\"name\":\"${INGRESS_DOMAIN}\",\"content\":\"${PUBLIC_IP}\",\"ttl\":300,\"proxied\":false}"
  else
    echo "  (Set CLOUDFLARE_API_TOKEN + CLOUDFLARE_ZONE_ID to enable auto-creation in Phase 2.)"
  fi
  echo "----------------------------------------------------------------"
}

print_summary() {
  echo "=============================================="
  echo "PoT '${CLIENT_ID}' provisioned"
  echo "  URL (after DNS): https://${INGRESS_DOMAIN}"
  echo "  Public IP      : ${PUBLIC_IP}"
  echo "  Azure FQDN     : ${FQDN:-none}"
  echo "  Credentials    : printed above by bootstrap-node.sh"
  echo "=============================================="
}

on_error() {
  echo "----------------------------------------------------------------" >&2
  echo "DEPLOY FAILED for PoT '${CLIENT_ID}'." >&2
  echo "No automatic teardown (guardrail: no unattended destructive ops)." >&2
  echo "To inspect:  az resource list -g ${RG} -o table" >&2
  echo "To remove:   az group delete -n ${RG} --yes   (run manually after review)" >&2
  echo "----------------------------------------------------------------" >&2
}

# ----------------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------------
cmd="${1:-create}"
case "$cmd" in
  render-values)
    # Local: render values.yaml. Fully offline if CERT_PEM_FILE + KEY_PEM_FILE
    # are set; otherwise needs `az login` for the Key Vault fallback.
    az account show >/dev/null 2>&1 && az account set --subscription "$SUBSCRIPTION" || true
    fetch_cert
    validate_tls
    render_values
    log "wrote $VALUES_FILE"
    ;;
  dns-record)
    PUBLIC_IP="${PUBLIC_IP:-$(az vm show -d -g "$RG" -n "$VM" --query publicIps -o tsv 2>/dev/null || true)}"
    [ -n "${PUBLIC_IP:-}" ] || die "PUBLIC_IP unknown — set PUBLIC_IP or ensure VM $VM exists"
    reserve_dns
    ;;
  create)
    trap on_error ERR
    preflight
    provision_infra
    fetch_cert
    validate_tls
    render_values
    wait_for_ssh
    bootstrap_node
    reserve_dns
    print_summary
    ;;
  *)
    die "unknown subcommand '$cmd' (use: create | render-values | dns-record)"
    ;;
esac
