# CLAUDE.md — AtScale PoT Snowflake Provisioning

## What this is
Per-PoT Snowflake footprint provisioning for AtScale **Proof-of-Technology
(PoT)** environments. Sibling to `atscale-deploy-action` (the VM half); this
provisions the **data substrate** a PoT queries and emits a `ps-utils`-ready
`connections.yaml` fragment + private key. It's the Phase-2 **G2 seam** (data
backend) from the main PoT project plan.

## Deliverables
- **`snowctl`** — bash entrypoint (`bootstrap | provision | teardown | list | render`), operator console + Action body. Mirrors the sibling `deploy.sh` conventions.
- **`sql/*`** — `tags.sql` (bootstrap), `provision.sql.tmpl`, `teardown.sql.tmpl` (rendered via `envsubst`).
- **`action.yml`** — composite action (canonical create path); chain-ready via step outputs.

## Hard guardrails — do NOT violate
- **se-demo is a REAL Snowflake account.** Everything is namespaced `POT_<C>_`. The service principal gets **zero account-wide grants** — only USAGE/DML on its own DB, schemas, and warehouses.
- **Teardown drops by prefix ONLY** (`POT_<C>_*`). Never touch `POT_ADMIN`, other PoTs, or any pre-existing object.
- **Confirm-first** on `bootstrap` / `provision` (billable) / `teardown` (destructive). Bypass only via `SNOWCTL_ASSUME_YES=1` / `--yes` (the Action sets it). `render` and `list` are read-only.
- **Service principal = `TYPE=SERVICE`** (password-less, key-pair only). Key-pair generated locally; private key → gitignored `runtime/`, chmod 600. **Never commit keys/credentials.** Never echo private keys.
- **Idempotent create** (`CREATE ... IF NOT EXISTS`, `GRANT` repeatable, `ALTER` converges). Re-provision reuses the existing `runtime/<c>_snowflake_key.p8` (no key rotation).
- **Cost tags** (`pot_client`/`pot_lifecycle`/`pot_expiry`) from `POT_ADMIN.TAGS` on the DB, warehouses, role, and user.

## Conventions (mirror the sibling repo)
- `set -euo pipefail`; `log()`/`die()`/`have()`/`require_cmds()` helpers; env-var config with defaults at top; `case "$cmd"` dispatch; `trap on_error ERR` that prints manual next-steps (no auto-destroy).
- `runtime/` is gitignored and holds all generated secrets/SQL. `chmod 600` on secret files.

## Repo & git hygiene
- Work on a **feature branch** and open a **PR**; don't push straight to `main` (the action is consumed by `uses:`). Tag `v1`/`v2` when ready to roll out.
- Built as a subdirectory of the deploy repo for review; intended to split into its own repo (`git subtree split`) later.
