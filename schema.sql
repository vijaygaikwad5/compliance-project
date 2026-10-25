-- =====================================================================
-- Container platform compliance (OC) - database schema
-- Target: PostgreSQL syntax (adapt types if you use Azure SQL)
-- Layers: staging (raw loads) -> core (model) -> audit (traceability) -> rpt (views for Power BI)
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS rpt;

-- ---------------------------------------------------------------------
-- AUDIT: every import is traceable
-- ---------------------------------------------------------------------
CREATE TABLE audit.ingestion_run (
    run_id               BIGSERIAL PRIMARY KEY,
    started_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at          TIMESTAMPTZ,
    status               TEXT NOT NULL DEFAULT 'running'
                         CHECK (status IN ('running','succeeded','partial','failed')),
    rules_config_version TEXT,            -- version of config (isto/istio version, sidecar name, exclusions)
    notes                TEXT
);

-- one row per blob file loaded (or skipped / failed)
CREATE TABLE audit.ingestion_file (
    file_id            BIGSERIAL PRIMARY KEY,
    run_id             BIGINT NOT NULL REFERENCES audit.ingestion_run(run_id),
    cluster_id         TEXT NOT NULL,
    blob_path          TEXT NOT NULL,
    blob_last_modified TIMESTAMPTZ,
    snapshot_ts        TIMESTAMPTZ NOT NULL,   -- time the data-agent collected the data
    checksum           TEXT NOT NULL,
    status             TEXT NOT NULL CHECK (status IN ('loaded','skipped_duplicate','failed')),
    error_message      TEXT,
    loaded_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (blob_path, checksum)               -- idempotent loads: same file is never loaded twice
);
CREATE INDEX ix_ingestion_file_cluster_snapshot ON audit.ingestion_file (cluster_id, snapshot_ts DESC);

-- loads from non-blob sources (e.g. the PostgreSQL owner table)
CREATE TABLE audit.source_load (
    source_load_id BIGSERIAL PRIMARY KEY,
    run_id         BIGINT NOT NULL REFERENCES audit.ingestion_run(run_id),
    source_name    TEXT NOT NULL,              -- e.g. 'owner_table'
    rows_loaded    INTEGER NOT NULL,
    checksum       TEXT,
    status         TEXT NOT NULL CHECK (status IN ('loaded','failed')),
    loaded_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- how many namespaces were evaluated vs ignored vs excluded, per cluster per snapshot
CREATE TABLE audit.scope_summary (
    run_id            BIGINT NOT NULL REFERENCES audit.ingestion_run(run_id),
    cluster_id        TEXT NOT NULL,
    snapshot_ts       TIMESTAMPTZ NOT NULL,
    total_namespaces  INTEGER NOT NULL,
    in_scope          INTEGER NOT NULL,
    ignored_no_label  INTEGER NOT NULL,
    excluded_system   INTEGER NOT NULL,
    PRIMARY KEY (run_id, cluster_id),
    CONSTRAINT scope_reconciles CHECK (total_namespaces = in_scope + ignored_no_label + excluded_system)
);

-- ---------------------------------------------------------------------
-- CORE: settings and dimensions
-- ---------------------------------------------------------------------
CREATE TABLE core.setting (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO core.setting (key, value) VALUES
    ('max_snapshot_age_hours', '24'),
    ('required_label_key',     'istio.io/rev'),
    ('sidecar_container_name', 'istio-proxy'),
    ('expected_istio_rev',     '1.29'),
    ('excluded_namespaces',    'kube-system');

CREATE TABLE core.dim_cluster (
    cluster_id   TEXT PRIMARY KEY,
    cluster_name TEXT,
    region       TEXT,
    environment  TEXT,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE
);

-- Owner data copied from the PostgreSQL owner table on each run.
-- app_id_key is the normalised join key (lower + trimmed).
CREATE TABLE core.dim_application (
    app_id_key                   TEXT PRIMARY KEY,
    app_id_raw                   TEXT,
    app_name                     TEXT,
    app_owner_name               TEXT,
    app_owner_email              TEXT,
    app_owner_support_team_name  TEXT,
    app_owner_support_team_email TEXT,
    source_load_id               BIGINT REFERENCES audit.source_load(source_load_id),
    loaded_at                    TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Sentinel row so namespaces without a known owner still join cleanly in Power BI
INSERT INTO core.dim_application (app_id_key, app_id_raw, app_name, app_owner_name)
VALUES ('UNASSIGNED', NULL, 'Unassigned / unknown', 'Unknown');

CREATE TABLE core.dim_compliance (
    compliance_id TEXT PRIMARY KEY,           -- 'OC', future: others
    name          TEXT NOT NULL,
    description   TEXT
);
INSERT INTO core.dim_compliance VALUES
    ('OC', 'OC compliance', 'Namespace is on the service mesh with the expected revision and every pod has the sidecar');

CREATE TABLE core.dim_rule (
    rule_id        TEXT PRIMARY KEY,          -- 'OC-1', 'OC-2'
    compliance_id  TEXT NOT NULL REFERENCES core.dim_compliance(compliance_id),
    rule_name      TEXT NOT NULL,
    description    TEXT,
    expected_value TEXT,
    severity       TEXT,
    rule_version   TEXT
);
INSERT INTO core.dim_rule (rule_id, compliance_id, rule_name, description, expected_value, rule_version) VALUES
    ('OC-1', 'OC', 'istio.io/rev matches expected version',
     'Namespace label istio.io/rev must equal the expected revision', '1.29', '1'),
    ('OC-2', 'OC', 'Every pod has the istio-proxy container',
     'Each evaluated pod has a container named istio-proxy (containers or initContainers)', 'istio-proxy', '1');

CREATE TABLE core.dim_date (
    date_key   DATE PRIMARY KEY,
    year       INTEGER, month INTEGER, day INTEGER,
    week       INTEGER, day_name TEXT
);

-- Current state of each namespace (cluster + name is the unique key)
CREATE TABLE core.dim_namespace (
    namespace_key        TEXT PRIMARY KEY,    -- cluster_id || '/' || namespace_name
    cluster_id           TEXT NOT NULL REFERENCES core.dim_cluster(cluster_id),
    namespace_name       TEXT NOT NULL,
    app_id_label_raw     TEXT,                -- value of the app-id label as found
    app_id_key           TEXT NOT NULL DEFAULT 'UNASSIGNED' REFERENCES core.dim_application(app_id_key),
    owner_match_status   TEXT NOT NULL
                         CHECK (owner_match_status IN ('matched','no_app_id_label','app_id_not_in_db')),
    istio_rev_value      TEXT,
    scope_status         TEXT NOT NULL
                         CHECK (scope_status IN ('in_scope','ignored_no_label','excluded_system')),
    labels               JSONB,
    first_seen_ts        TIMESTAMPTZ NOT NULL,
    last_seen_ts         TIMESTAMPTZ NOT NULL,
    UNIQUE (cluster_id, namespace_name)
);
CREATE INDEX ix_dim_namespace_app ON core.dim_namespace (app_id_key);

-- ---------------------------------------------------------------------
-- CORE: facts (one set of rows per snapshot, so history/trends are kept)
-- ---------------------------------------------------------------------

-- every namespace seen in a snapshot and why it is in or out of scope
CREATE TABLE core.fact_namespace_scope (
    run_id        BIGINT NOT NULL REFERENCES audit.ingestion_run(run_id),
    cluster_id    TEXT   NOT NULL,
    snapshot_ts   TIMESTAMPTZ NOT NULL,
    namespace_key TEXT   NOT NULL REFERENCES core.dim_namespace(namespace_key),
    scope_status  TEXT   NOT NULL,
    scope_reason  TEXT,
    PRIMARY KEY (run_id, namespace_key)
);

CREATE TABLE core.fact_pod (
    run_id           BIGINT NOT NULL REFERENCES audit.ingestion_run(run_id),
    cluster_id       TEXT   NOT NULL,
    snapshot_ts      TIMESTAMPTZ NOT NULL,
    namespace_key    TEXT   NOT NULL REFERENCES core.dim_namespace(namespace_key),
    pod_name         TEXT   NOT NULL,
    phase            TEXT,
    is_evaluated     BOOLEAN NOT NULL,        -- false for Succeeded/Failed pods
    has_sidecar      BOOLEAN NOT NULL,
    sidecar_location TEXT CHECK (sidecar_location IN ('containers','initContainers')),
    PRIMARY KEY (run_id, namespace_key, pod_name)
);

CREATE TABLE core.fact_rule_result (
    result_id       BIGSERIAL PRIMARY KEY,
    run_id          BIGINT NOT NULL REFERENCES audit.ingestion_run(run_id),
    cluster_id      TEXT   NOT NULL,
    snapshot_ts     TIMESTAMPTZ NOT NULL,
    namespace_key   TEXT   NOT NULL REFERENCES core.dim_namespace(namespace_key),
    rule_id         TEXT   NOT NULL REFERENCES core.dim_rule(rule_id),
    status          TEXT   NOT NULL CHECK (status IN ('Pass','Fail','NotApplicable')),
    actual_value    TEXT,
    expected_value  TEXT,
    pods_evaluated  INTEGER,
    pods_failing    INTEGER,
    failing_pods    TEXT[],
    failure_reason  TEXT,
    UNIQUE (run_id, namespace_key, rule_id)
);
CREATE INDEX ix_rule_result_cluster_snapshot ON core.fact_rule_result (cluster_id, snapshot_ts DESC);

-- roll-up: one row per in-scope namespace per compliance per snapshot
CREATE TABLE core.fact_namespace_compliance (
    run_id             BIGINT NOT NULL REFERENCES audit.ingestion_run(run_id),
    cluster_id         TEXT   NOT NULL,
    snapshot_ts        TIMESTAMPTZ NOT NULL,
    namespace_key      TEXT   NOT NULL REFERENCES core.dim_namespace(namespace_key),
    compliance_id      TEXT   NOT NULL REFERENCES core.dim_compliance(compliance_id),
    compliance_status  TEXT   NOT NULL CHECK (compliance_status IN ('Compliant','NonCompliant')),
    failed_rules       TEXT[] NOT NULL DEFAULT '{}',
    -- owner snapshot at evaluation time, so history is not rewritten if ownership changes
    app_id_key         TEXT,
    app_owner_name     TEXT,
    support_team_name  TEXT,
    PRIMARY KEY (run_id, namespace_key, compliance_id)
);
CREATE INDEX ix_ns_compliance_cluster_snapshot ON core.fact_namespace_compliance (cluster_id, snapshot_ts DESC);

-- ---------------------------------------------------------------------
-- RPT: views for Power BI (Power BI reads only these)
-- ---------------------------------------------------------------------

-- latest successfully loaded snapshot per cluster, with freshness
CREATE VIEW rpt.vw_cluster_freshness AS
WITH latest AS (
    SELECT DISTINCT ON (cluster_id)
           cluster_id, file_id, run_id, snapshot_ts, loaded_at, blob_path
    FROM audit.ingestion_file
    WHERE status = 'loaded'
    ORDER BY cluster_id, snapshot_ts DESC
),
cfg AS (
    SELECT value::numeric AS max_age_hours FROM core.setting WHERE key = 'max_snapshot_age_hours'
)
SELECT c.cluster_id,
       c.cluster_name,
       l.snapshot_ts           AS last_snapshot_ts,
       l.loaded_at             AS last_import_ts,
       l.run_id                AS last_run_id,
       ROUND(EXTRACT(EPOCH FROM (now() - l.snapshot_ts)) / 3600, 1) AS age_hours,
       CASE
           WHEN l.cluster_id IS NULL THEN 'Missing'
           WHEN now() - l.snapshot_ts > make_interval(hours => cfg.max_age_hours::int) THEN 'Stale'
           ELSE 'Fresh'
       END                     AS health_status
FROM core.dim_cluster c
CROSS JOIN cfg
LEFT JOIN latest l ON l.cluster_id = c.cluster_id
WHERE c.is_active;

-- latest compliance per in-scope namespace; stale clusters show 'Unknown'
CREATE VIEW rpt.vw_namespace_compliance_latest AS
SELECT f.namespace_key,
       n.cluster_id,
       n.namespace_name,
       f.compliance_id,
       f.snapshot_ts,
       fr.health_status,
       CASE WHEN fr.health_status = 'Fresh' THEN f.compliance_status ELSE 'Unknown' END AS report_status,
       f.failed_rules,
       (f.failed_rules @> ARRAY['OC-1']) AS fails_oc1,
       (f.failed_rules @> ARRAY['OC-2']) AS fails_oc2,
       n.app_id_key,
       a.app_name,
       a.app_owner_name,
       a.app_owner_email,
       a.app_owner_support_team_name,
       a.app_owner_support_team_email,
       n.owner_match_status
FROM core.fact_namespace_compliance f
JOIN rpt.vw_cluster_freshness fr
  ON fr.cluster_id = f.cluster_id AND fr.last_run_id = f.run_id
JOIN core.dim_namespace n   ON n.namespace_key = f.namespace_key
JOIN core.dim_application a ON a.app_id_key = n.app_id_key;

-- namespaces seen in the latest snapshot but not evaluated (ignored / excluded)
CREATE VIEW rpt.vw_namespace_scope_latest AS
SELECT s.namespace_key, n.cluster_id, n.namespace_name, s.scope_status, s.scope_reason,
       n.app_id_key, a.app_name, a.app_owner_name, a.app_owner_support_team_name, s.snapshot_ts
FROM core.fact_namespace_scope s
JOIN rpt.vw_cluster_freshness fr ON fr.cluster_id = s.cluster_id AND fr.last_run_id = s.run_id
JOIN core.dim_namespace n   ON n.namespace_key = s.namespace_key
JOIN core.dim_application a ON a.app_id_key = n.app_id_key;

-- headline: namespace-weighted compliance, fresh clusters only, with transparency numbers
CREATE VIEW rpt.vw_platform_compliance_summary AS
SELECT compliance_id,
       COUNT(*) FILTER (WHERE report_status = 'Compliant')    AS compliant_namespaces,
       COUNT(*) FILTER (WHERE report_status IN ('Compliant','NonCompliant')) AS evaluated_namespaces,
       COUNT(*) FILTER (WHERE report_status = 'Unknown')      AS unknown_namespaces,
       ROUND(100.0 * COUNT(*) FILTER (WHERE report_status = 'Compliant')
             / NULLIF(COUNT(*) FILTER (WHERE report_status IN ('Compliant','NonCompliant')), 0), 2)
                                                              AS compliance_pct
FROM rpt.vw_namespace_compliance_latest
GROUP BY compliance_id;
