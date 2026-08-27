#!/usr/bin/env bash
# Set up the VM-resident integration session on swtdev:
#   1. push the ipaddemo checkout to the box (rsync incl .git, so it's a real
#      repo with origin set — no GitHub credential needs to live on the VM)
#   2. install Node LTS + Claude Code for the atscale user (nvm, no sudo)
#   3. print the one command to start a Claude session on the box
#
# Idempotent: re-running re-syncs the code and skips already-installed tooling.
# Run from the laptop:  ~/GitHub/atscale-deploy-action/setup-vm-session.sh
set -euo pipefail

KEY="$HOME/GitHub/atscale-deploy-action/runtime/swtdev_key"
HOST="atscale@20.163.121.39"
LOCAL_REPO="$HOME/GitHub/ipaddemo/"     # trailing slash = copy contents
REMOTE_DIR="ipaddemo"                    # lands at ~/ipaddemo on the box
SSH="ssh -i $KEY -o StrictHostKeyChecking=accept-new"

echo "==> syncing $LOCAL_REPO -> $HOST:~/$REMOTE_DIR"
rsync -az --delete -e "$SSH" \
  --exclude '.venv/' --exclude 'node_modules/' --exclude '__pycache__/' \
  --exclude '.pytest_cache/' --exclude 'test-results/*' \
  "$LOCAL_REPO" "$HOST:$REMOTE_DIR/"

echo "==> installing Node LTS + Claude Code on the box (no sudo, via nvm)"
$SSH "$HOST" 'bash -s' <<'REMOTE'
# NOTE: no `set -u` here — nvm.sh is not nounset-safe (references unset
# PROVIDED_VERSION during `nvm install/use`, which aborts under set -u).
set -eo pipefail
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "-- installing nvm"
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
if ! nvm ls --no-colors 2>/dev/null | grep -q 'lts'; then
  echo "-- installing Node LTS"
  nvm install --lts
fi
nvm use --lts >/dev/null
if ! command -v claude >/dev/null 2>&1; then
  echo "-- installing @anthropic-ai/claude-code"
  # --allow-scripts: newer npm blocks postinstall by default; Claude Code's
  # postinstall (install.cjs) sets up its native bits, so allow it explicitly
  npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code
fi
echo "-- versions:"
echo "   node $(node --version)  npm $(npm --version)  claude $(claude --version 2>/dev/null || echo '?')"
echo "-- repo on box:"
git -C "$HOME/ipaddemo" log --oneline -1 2>/dev/null || echo "   (no git history — rsync copied working tree only)"
REMOTE

cat <<EOF

==> done. Start the on-box session with:

  ssh -t -i $KEY $HOST 'export NVM_DIR=\$HOME/.nvm; . \$NVM_DIR/nvm.sh; cd ~/ipaddemo && claude "You are the VM-resident integration session on swtdev. Read CLAUDE.md (Working from the VM checkout section) and the project_swt_booth_dashboard memory, then run tap/sidecar integration on this box. kubectl needs the microk8s prefix here."'

First run of claude will prompt you to log in (that auth is yours to complete).
To push commits from the box later:  ssh in, then  gh auth login  (device flow).
EOF
