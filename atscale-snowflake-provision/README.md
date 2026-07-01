# AtScale PoT — Snowflake Provisioning

Provisions, per **Proof-of-Technology (PoT)**, a tightly-scoped Snowflake
footprint that an AtScale PoT queries, and emits a
[`ps-utils`](https://github.com/atscale/ps-utils)-ready `connections.yaml`
fragment + private key. Sibling to `atscale-deploy-action` (which provisions the
VM); this is the **data substrate** half of the PoT. See `CLAUDE.md` for the
hard guardrails — **se-demo is a real Snowflake account**.

## What it provisions (client `<c>` → prefix `POT_<C>_`)
1. **Database + schemas:** `POT_<C>_DB` with `SOURCE` (data-generation target + AtScale read) and `AGGREGATES` (AtScale read/write).
2. **Warehouses:** `POT_<C>_WH_S|M|L` (SMALL/MEDIUM/LARGE), `AUTO_SUSPEND=60 AUTO_RESUME=TRUE INITIALLY_SUSPENDED=TRUE` for cost control.
3. **Role `POT_<C>_ROLE`** — scoped to **only** this PoT: USAGE on the DB/schemas/warehouses, and SELECT/INSERT/UPDATE/DELETE/TRUNCATE + CREATE TABLE/VIEW on existing **and future** objects in both schemas. No account-wide grants.
4. **Service principal `POT_<C>_SVC`** — `TYPE=SERVICE` (password-less, key-pair only), with `RSA_PUBLIC_KEY`, `DEFAULT_ROLE`, `DEFAULT_WAREHOUSE`.
5. **Cost tags:** `pot_client` / `pot_lifecycle` / `pot_expiry` (from `POT_ADMIN.TAGS`) applied to the DB, warehouses, role, and user.

## Architecture
- **`snowctl`** — the orchestrator. Runs both locally (operator console) and inside the Action. Generates the key-pair, renders SQL, runs it via `snow`, and emits the ps-utils fragment.
- **`sql/tags.sql`** — one-time bootstrap of the shared `POT_ADMIN.TAGS` tag definitions.
- **`sql/provision.sql.tmpl` / `sql/teardown.sql.tmpl`** — idempotent create / surgical prefix-scoped drop, rendered with `envsubst`.
- **`action.yml`** — composite wrapper: install `snow`, write the admin connection, then `snowctl bootstrap` + `snowctl provision`. Chain-ready (exposes the fragment + key as step outputs).

Everything is namespaced `POT_<C>_`; teardown drops only `POT_<C>_*` and never
touches `POT_ADMIN` or any pre-existing se-demo object.

## Prerequisites
- **Snowflake CLI** (`snow`): `brew install snowflake-cli` (or `pip install snowflake-cli`), plus `openssl` and `sed`. `envsubst` is used for rendering when present (`brew install gettext`); otherwise `snowctl` falls back to `sed`.
- A **named admin connection** (e.g. `-c se-demo-admin`, key-pair preferred) whose role can `CREATE ROLE`/`USER` (USERADMIN/SECURITYADMIN), `WAREHOUSE` + `DATABASE` (SYSADMIN), and `CREATE`/apply `TAG` (ACCOUNTADMIN or delegated).
- The se-demo **account identifier** (for the emitted fragment) — pass as `SNOW_ACCOUNT`.

## Local usage (operator)
```bash
export SNOW_CONNECTION=se-demo-admin       # your named `snow` connection
export SNOW_ACCOUNT=<se-demo-account>      # goes into the ps-utils fragment

./snowctl bootstrap                        # one-time per account (creates POT_ADMIN.TAGS)
./snowctl render aig                        # dry-run: rendered SQL + fragment to runtime/, nothing executed
./snowctl provision aig                     # confirm-first, billable — creates the POT_AIG_ footprint
./snowctl list                              # active PoT warehouses + tag references
./snowctl teardown aig                      # confirm-first, destructive — DROPs only POT_AIG_ objects
```
`--yes` (or `SNOWCTL_ASSUME_YES=1`) skips the confirm prompts (the Action sets
this). Knobs: `WH_S_SIZE`/`WH_M_SIZE`/`WH_L_SIZE`, `AUTO_SUSPEND`,
`POT_TTL_DAYS`, `KEY_PASSPHRASE` (encrypt the generated private key).

Generated artifacts land in the gitignored `runtime/` dir — the private key
(`runtime/<c>_snowflake_key.p8`), rendered SQL, and the connections fragment
(`runtime/connections-<c>.yaml`). **Never commit them.**

## Emitted fragment → ps-utils
`runtime/connections-<c>.yaml` plugs straight into ps-utils (key-pair / JWT):
```yaml
users:
  pot_<c>_svc:
    username: POT_<C>_SVC
    privateKeyPath: runtime/<c>_snowflake_key.p8
connections:
  <c>_snowflake:
    sql:
      dialect: snowflake
      account: <se-demo-account>
      warehouse: POT_<C>_WH_M
      database: POT_<C>_DB
      schema: SOURCE
      role: POT_<C>_ROLE
      snowflake_user: pot_<c>_svc
```
Consumed by `atscale-create-data-source` (`--aggregate-schema POT_<C>_DB.AGGREGATES`),
`generate-sml-from-connection`, and `generate-data-from-data-shape-to-connection`.

## GitHub Action usage
```yaml
name: Provision PoT Snowflake
on:
  workflow_dispatch:
    inputs:
      client_id: { description: "Client id (e.g. aig)", required: true }

jobs:
  snowflake:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: your-org/atscale-snowflake-provision@v1
        id: sf
        with:
          client_id:              ${{ inputs.client_id }}
          snow_account:           ${{ secrets.SNOW_ACCOUNT }}
          snow_admin_user:        ${{ secrets.SNOW_ADMIN_USER }}
          snow_admin_private_key: ${{ secrets.SNOW_ADMIN_PRIVATE_KEY }}
      # A later step in this same job consumes ${{ steps.sf.outputs.connections_fragment }}
      # and ${{ steps.sf.outputs.private_key }} to drive ps-utils. Do NOT upload
      # the private key as a cross-job artifact.
```

## Chaining seam (next phase)
The emitted fragment + key are the contract. A combined workflow later:
`atscale-deploy-action` (VM) → **this** (Snowflake) → `ps-utils`
(create-data-source → generate-sml → deploy-catalog → generate-data) — the
end-to-end "Use-Case Bundle Generator".
