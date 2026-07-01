-- tags.sql — one-time account bootstrap (run via `snowctl bootstrap`).
--
-- Creates the shared POT_ADMIN database + TAGS schema that hold the three
-- cost-tracking tag definitions applied to every PoT footprint. This is NOT a
-- per-PoT database: `snowctl teardown` never touches it, so the tag objects
-- (and cross-PoT rollup they enable) survive across PoTs.
--
-- Idempotent: safe to re-run. No per-PoT parameters — no templating needed.

CREATE DATABASE IF NOT EXISTS POT_ADMIN
  COMMENT = 'AtScale PoT shared admin objects (cost-tracking tags). Never dropped by teardown.';

CREATE SCHEMA IF NOT EXISTS POT_ADMIN.TAGS
  COMMENT = 'Cost-tracking tag definitions applied to every PoT footprint.';

CREATE TAG IF NOT EXISTS POT_ADMIN.TAGS.POT_CLIENT
  COMMENT = 'Client / prospect id this PoT footprint belongs to.';

CREATE TAG IF NOT EXISTS POT_ADMIN.TAGS.POT_LIFECYCLE
  COMMENT = 'Lifecycle marker; always "pot" for PoT footprints (distinguishes from prod/demo objects).';

CREATE TAG IF NOT EXISTS POT_ADMIN.TAGS.POT_EXPIRY
  COMMENT = 'Intended teardown date (YYYY-MM-DD) — drives discovery of expired PoTs.';
