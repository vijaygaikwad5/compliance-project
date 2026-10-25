Architecture review · Draft v0.1 · 25 Oct 2026

# OC compliance reporting for the AKS container platform

How compliance evidence travels from the clusters to a Power BI dashboard, and the database that keeps every percentage traceable to the file it came from.

Platform

10 AKS clusters, 100 namespaces

First compliance

OC, two rules today

Only data source

JSON snapshots in Azure Blob

Report

Power BI on the compliance database

## How the data moves

Figure 1. The database sits between Blob Storage and Power BI. Each import is logged, the owner table is copied in on every run, and Power BI reads only the reporting views.

### Traceable

Each blob file is recorded with its snapshot time and checksum. A file that was already loaded is skipped, and every result row carries the run that produced it.

### Fresh or unknown

Age is measured from the snapshot time written by the data-agent, not from the import time. Namespaces on a stale cluster show Unknown and stay out of the percentage.

### Ready for more rules

A new compliance adds rows to `dim_compliance` and `dim_rule` plus one rule function. It needs no new tables, no new pipeline and no new data source.

## How a namespace is scored

Figure 2. Only namespaces that carry the `istio.io/rev` label are scored. The others are counted and kept, so the dashboard can show how many were left out and why.

Compliance % = compliant / (compliant + non-compliant) namespaces × 100, fresh clusters only

## Data model

Figure 3. Dimensions describe clusters, applications, namespaces and rules. Facts hold one set of rows per import run. Audit tables record which file, run and source each number came from.

Owner details join on the `app-id` label. A namespace with no match points at the `UNASSIGNED` application row, so it stays in the percentage and shows up under an unassigned owner. Owner name and support team are copied onto each compliance row when it is evaluated, so a later ownership change does not rewrite past results.

### Reporting views read by Power BI

- `rpt.vw_cluster_freshness`Latest snapshot per cluster with its age in hours and a Fresh, Stale or Missing status.
- `rpt.vw_namespace_compliance_latest`One row per scored namespace with its verdict, failed rules and owner. Stale clusters show Unknown.
- `rpt.vw_namespace_scope_latest`Namespaces that were seen but not scored, with the reason: no label, or an excluded system namespace.
- `rpt.vw_platform_compliance_summary`The headline percentage with the compliant, evaluated and unknown counts behind it.

## Decisions for approval

| Decision | Proposed | Alternative considered |
| --- | --- | --- |
| Where reports read from | Compliance database. Power BI reads the `rpt` views only. | Power BI reading Blob directly. No import history, and the logic lives inside the report. |
| Where rules run | Python job with unit tests. Version, sidecar name and exclusions live in `core.setting`. | DAX or Power Query. Harder to test and hides the logic in the report. |
| Table shape | Generic rule results keyed by rule and compliance. | A single `oc_compliance` table, which needs a new table for every later compliance. |
| Namespaces without the label | Recorded as ignored and counted on every run. | Dropped with no record. |
| Stale clusters | Shown as Unknown, left out of the percentage, with the count shown beside it. | Carrying the last known result forward. |
| Percentage weighting | Namespace-weighted. | Pod-weighted. An application-level view can be added later as a separate measure. |
| Ownership data | Copied from PostgreSQL on every run. Unmatched app ids go to `UNASSIGNED`. | A live join at report time, which leaves no trace of which owner data a report used. |
| Role of AI | Later: questions and summaries over the reporting views. Never decides a verdict. | AI-evaluated compliance, which is not reproducible for audit. |

### Open before build

- Confirm the label key in live data (`istio.io/rev`) and the exact format of the expected revision value.
- Confirm the data-agent exports `status.phase` for pods, so finished Job pods can be skipped.
- Agree the staleness limit. 24 hours is proposed.
- Decide whether a namespace with no running pods is scored or marked not applicable.
- Choose where the ingestion job runs and how it is scheduled.

Source: `schema.sql`, PostgreSQL syntax. The schema has not yet been run against a database.