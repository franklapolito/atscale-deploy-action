#!/usr/bin/env bash
# One-command kickoff for the SWT booth INFRASTRUCTURE session.
# Opens a fresh Claude Code session in the deploy-action repo, primed with the
# handoff so it self-orients onto the swtdev environment work (license first).
#
#   ~/GitHub/atscale-deploy-action/infra-session.sh
#
# Keep the DEMO-CODE work in a separate session in ~/GitHub/ipaddemo.
set -euo pipefail
cd "$(dirname "$0")"
exec claude "You are the infrastructure session for the SWT booth project. \
Read ./INFRA_HANDOFF.md in full and the project_swt_booth_dashboard memory, \
then pick up the swtdev environment thread — the licensing blocker is the first \
task. Do NOT edit the ~/GitHub/ipaddemo demo code; that runs in a separate \
session. Confirm you've read the handoff and state your plan before making changes."
