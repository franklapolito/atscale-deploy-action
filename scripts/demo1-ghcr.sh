#!/usr/bin/env bash
# demo1 -> 2026.11.0 release chart prep (Canary UI, DG's request 2026-11-23). Frank runs it on the laptop; it uses
# his gh token, which the agent may not touch. It changes one thing on demo1: the image-pull secret "ghcr-pull".
#   1. refresh the k8s image-pull secret "ghcr-pull" in ns atscale (the one from 2026-10-13 may hold an old token)
#   2. helm registry login to ghcr.io on the box, then pull the chart to ~/charts/ on the box
#   3. print, with no secrets: the chart's default image per component, every value that mentions canary or
#      comodel, and every template line that routes /canary or /ui
# The token goes over ssh on stdin only: never on argv, never written to disk here.
#   bash ~/GitHub/atscale-deploy-action/scripts/demo1-ghcr.sh
set -euo pipefail
IP="${IP:-172.203.218.112}"; KEY="${KEY:-$HOME/.ssh/id_rsa}"
CHART="oci://ghcr.io/atscaleinc/atscale-helm-stack/atscale"; VER="${VER:-2026.11.0-release}"
GHUSER="$(gh api user --jq .login)"
TOKEN="$(gh auth token)"; [ -n "$TOKEN" ] || { echo "gh is not logged in"; exit 1; }
printf '%s' "$TOKEN" | ssh -o LogLevel=ERROR -i "$KEY" "atscale@$IP" "set -euo pipefail
  T=\$(cat)
  sudo microk8s kubectl -n atscale delete secret ghcr-pull --ignore-not-found >/dev/null
  sudo microk8s kubectl -n atscale create secret docker-registry ghcr-pull --docker-server=ghcr.io \
    --docker-username='$GHUSER' --docker-password=\"\$T\" >/dev/null && echo 'secret ghcr-pull refreshed in ns atscale'
  printf '%s' \"\$T\" | sudo microk8s helm3 registry login ghcr.io -u '$GHUSER' --password-stdin >/dev/null && echo 'helm logged in to ghcr.io'
  mkdir -p ~/charts && cd ~/charts && rm -rf atscale-$VER.tgz x-$VER
  sudo microk8s helm3 pull $CHART --version $VER && sudo chown atscale: atscale-$VER.tgz && ls -la atscale-$VER.tgz
  echo '=== Chart.yaml'
  sudo microk8s helm3 show chart atscale-$VER.tgz | grep -E '^(name|version|appVersion):'
  echo '=== default images (registry / repository / tag)'
  sudo microk8s helm3 show values atscale-$VER.tgz | grep -E '^[a-zA-Z]|registry:|repository:|tag:' | grep -B3 -E 'tag:' | head -120
  echo '=== values that mention canary or comodel'
  sudo microk8s helm3 show values atscale-$VER.tgz | grep -n -i -E 'canary|comodel|toolGroups|enabledToolGroups' | head -40 || true
  echo '=== templates that route /canary or /ui'
  mkdir x-$VER && tar -xzf atscale-$VER.tgz -C x-$VER
  grep -rn -i -E 'canary|location[^{]*/ui' x-$VER --include='*.yaml' --include='*.tpl' --include='*.conf' | grep -v -i 'values.yaml' | cut -c1-200 | head -40 || true
  echo '=== sub-chart values that mention canary'
  grep -rn -i -E 'canary|comodel' x-$VER --include='values.yaml' | cut -c1-200 | head -40 || true
  rm -rf x-$VER"
