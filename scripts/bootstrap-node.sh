#!/usr/bin/env bash
#
# bootstrap-node.sh — runs ON the PoT VM (invoked by deploy.sh over SSH).
#
# Installs MicroK8s + Helm, enables the MINIMAL addon set, and deploys the
# AtScale chart from a values.yaml that deploy.sh has already rendered and
# copied to this host. Prints the generated admin credentials at the end.
#
# Usage:  bootstrap-node.sh <chart_version> <values_path> [namespace]
#
# HARD GUARDRAIL (plan §3.3 / CLAUDE.md): enable ONLY `dns hostpath-storage`
# + `metallb:<nodeIP>/32`. NEVER enable the `ingress` addon and NEVER create a
# custom Ingress resource — the chart's own `atscale-ingress-gateway`
# LoadBalancer (driven by atscale-proxy.service.type=LoadBalancer) is the
# single front door for 80/443/11111/15432.
#
set -euo pipefail

CHART_VERSION="${1:?chart version required}"
VALUES_PATH="${2:?values.yaml path required}"
NAMESPACE="${3:-atscale}"
CHART_OCI="${CHART_OCI:-oci://registry-1.docker.io/atscaleinc/atscale}"
HELM_TIMEOUT="${HELM_TIMEOUT:-20m}"

export PATH="$PATH:/snap/bin"
log() { echo "[bootstrap $(date -u +%H:%M:%S)] $*"; }

# --- 1. Tools (idempotent) -------------------------------------------------
install_snap() {
  local name="$1"
  if snap list "$name" >/dev/null 2>&1; then
    log "$name already installed — skipping"
  else
    log "installing $name"
    sudo snap install "$name" --classic
  fi
}
install_snap microk8s
# helm3 + kubectl ship inside the microk8s snap (used as `microk8s helm3` /
# `microk8s kubectl` throughout) — no standalone snaps needed.

# Let the invoking user drive microk8s without sudo on re-runs.
sudo usermod -a -G microk8s "$(whoami)" 2>/dev/null || true

# --- 2. Kernel prep --------------------------------------------------------
sudo swapoff -a || true
sudo sed -i '/\bswap\b/d' /etc/fstab || true

# --- 3. MicroK8s addons (MINIMAL — see guardrail above) --------------------
sudo microk8s status --wait-ready

NODE_IP="$(ip route get 1.1.1.1 | grep -oP 'src \K\S+')"
[ -n "$NODE_IP" ] || { echo "FATAL: could not determine node IP"; exit 1; }
log "node IP = $NODE_IP"

# dns + hostpath-storage are no-ops if already enabled.
sudo microk8s enable dns hostpath-storage
# metallb pinned to the node IP /32 (runbook pattern). Guarded against the
# accidental 'ingress' that this whole architecture forbids.
sudo microk8s enable "metallb:${NODE_IP}/32"

if sudo microk8s status --format short 2>/dev/null | grep -qE '^core/ingress: enabled'; then
  echo "FATAL: microk8s 'ingress' addon is enabled — forbidden by architecture (plan §3.3). Disable it: sudo microk8s disable ingress"
  exit 1
fi

# --- 4. kubeconfig ---------------------------------------------------------
mkdir -p "$HOME/.kube"
sudo microk8s config > "$HOME/.kube/config"
sudo chown -R "$(whoami):$(whoami)" "$HOME/.kube"
chmod 600 "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

sudo microk8s kubectl create namespace "$NAMESPACE" \
  --dry-run=client -o yaml | sudo microk8s kubectl apply -f -

# --- 5. Deploy AtScale -----------------------------------------------------
# TLS comes inline from values.yaml (global.atscale.tls.tlsCrt/tlsKey). No
# self-signed cert, no TLS secret creation, no custom Ingress.
log "deploying AtScale chart $CHART_VERSION (timeout ${HELM_TIMEOUT})"
sudo microk8s helm3 upgrade --install atscale "$CHART_OCI" \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_PATH" \
  --wait --timeout "$HELM_TIMEOUT"

# --- 6. Front-door sanity check -------------------------------------------
log "services in $NAMESPACE:"
sudo microk8s kubectl get svc -n "$NAMESPACE"
if ! sudo microk8s kubectl get svc atscale-ingress-gateway -n "$NAMESPACE" >/dev/null 2>&1; then
  log "WARNING: expected LoadBalancer 'atscale-ingress-gateway' not found — verify chart values."
fi

# --- 7. Credentials --------------------------------------------------------
AS_USER="$(sudo microk8s kubectl get secret -n "$NAMESPACE" atscale-kc-users -o jsonpath='{.data.atscaleAdmin}' | base64 -d || true)"
AS_PASS="$(sudo microk8s kubectl get secret -n "$NAMESPACE" atscale-kc-users -o jsonpath='{.data.atscaleAdminPassword}' | base64 -d || true)"
# This stdout streams back through the composite Action into the workflow log.
# GitHub only masks values registered with ::add-mask::, so register the
# password before printing to keep it out of the plaintext CI log.
[ -n "${AS_PASS:-}" ] && [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::${AS_PASS}"
echo "=============================================="
echo "AtScale admin user : ${AS_USER:-<unavailable>}"
echo "AtScale admin pass : ${AS_PASS:-<unavailable>}"
echo "=============================================="
