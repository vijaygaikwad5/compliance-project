OC Compliance Database Architecture

Technical Design Proposal | Version 1.0 | For Technical Lead Approval

1. Objective

Design a centralized database to store, evaluate, and report OC compliance across Azure Kubernetes Service (AKS). It supports two Power BI pages: (1) overall OC compliance percentage and (2) namespace-level compliance status, criteria, application ownership and filters. The architecture should support future compliance categories.

Platform overview

|Parameter            |Details                             |
|---------------------|------------------------------------|
|Container platform   |Azure Kubernetes Service (AKS)      |
|Total clusters       |10                                  |
|Total namespaces     |Approximately 100                   |
|Initial compliance   |OC                                  |
|Criteria             |OC-1 and OC-2                       |
|Primary data source  |JSON snapshots in Azure Blob Storage|
|Application ownership|Existing PostgreSQL owner table     |
|Evaluation           |Python ingestion and rule engine    |
|Database             |PostgreSQL                          |
|Reporting            |Power BI                            |

2. Power BI dashboard requirements

Dashboard 1: Overall OC compliance

Display the overall OC compliance percentage, evaluated namespace count, compliant count, non-compliant count and unknown count. Example values (illustrative only): 85% compliance, 100 evaluated namespaces, 85 compliant, 15 non-compliant and 0 unknown.

Formula:

OC Compliance % = Compliant Namespaces / (Compliant + Non-Compliant Namespaces) * 100

Only eligible, evaluated namespaces from fresh clusters count toward the percentage. Ignored/excluded namespaces and stale/unknown results are excluded from the denominator. The percentage is namespace-weighted, not pod-weighted.

Dashboard 2: Namespace-level OC compliance

|Sr No|Namespace Name|Cluster Name|OC Status    |OC Criteria 1|OC Criteria 2|Application Name|Application ID|Application Owner|
|-----|--------------|------------|-------------|-------------|-------------|----------------|--------------|-----------------|
|1    |payment-api   |aks-prod-01 |Compliant    |Passed       |Passed       |Payment Service |APP-101       |Owner A          |
|2    |payment-worker|aks-prod-02 |Non-compliant|Passed       |Failed       |Payment Service |APP-101       |Owner A          |
|3    |order-api     |aks-prod-01 |Non-compliant|Failed       |Passed       |Order Service   |APP-102       |Owner B          |
|4    |customer-api  |aks-prod-03 |Compliant    |Passed       |Passed       |Customer Service|APP-103       |Owner C          |

Example rows, not actual compliance data.

Filters: Cluster Name, Application Name, Application ID, Application Owner, OC Compliance Status, OC Criteria 1, OC Criteria 2. Support multi-select and combined filters.

One application can span several clusters and namespaces. For example, APP-101 may own payment-api and payment-db in AKS Cluster 01, payment-worker and payment-cache in Cluster 02, and payment-gateway in Cluster 03. Selecting APP-101 must display all five namespaces.

3. Proposed database architecture

|Layer    |Schema   |Responsibility                           |
|---------|---------|-----------------------------------------|
|Staging  |`staging`|Temporary/raw ingestion data             |
|Core     |`core`   |Master entities and compliance results   |
|Audit    |`audit`  |Source traceability and execution history|
|Reporting|`rpt`    |SQL views consumed by Power BI           |

AKS clusters -> data-agent -> Azure Blob JSON snapshots
                                   |
                                   v
                      Python ingestion/evaluation <--- PostgreSQL owner table
                                   |
                                   v
                          PostgreSQL database
                          | core dimensions/facts
                          | audit and settings
                                   |
                                   v
                          SQL reporting views
                          | OC summary
                          | Namespace details
                                   |
                                   v
                            Power BI (2 pages)

The supplied SQL creates a staging schema but does not yet define staging tables.

4. Database table structures

A. Dimension tables

1. core.dim_cluster

Purpose: Master list of monitored AKS clusters.

|Column        |Type   |Key|Description       |
|--------------|-------|---|------------------|
|`cluster_id`  |TEXT   |PK |Unique cluster ID |
|`cluster_name`|TEXT   |   |Display name      |
|`region`      |TEXT   |   |Azure region      |
|`environment` |TEXT   |   |DEV / QA / PROD   |
|`is_active`   |BOOLEAN|   |Monitoring enabled|

One cluster contains many namespaces.

2. core.dim_application

Purpose: Application ownership data imported from PostgreSQL.

|Column                        |Type       |Key|Description              |
|------------------------------|-----------|---|-------------------------|
|`app_id_key`                  |TEXT       |PK |Normalized application ID|
|`app_id_raw`                  |TEXT       |   |Original application ID  |
|`app_name`                    |TEXT       |   |Application name         |
|`app_owner_name`              |TEXT       |   |Owner name               |
|`app_owner_email`             |TEXT       |   |Owner email              |
|`app_owner_support_team_name` |TEXT       |   |Support team             |
|`app_owner_support_team_email`|TEXT       |   |Support email            |
|`source_load_id`              |BIGINT     |FK |Source import reference  |
|`loaded_at`                   |TIMESTAMPTZ|   |Import time              |

One application can own multiple namespaces across multiple clusters. Unmatched application IDs map to the sentinel UNASSIGNED record.

3. core.dim_namespace

Purpose: Current metadata for each namespace; connects clusters, applications and compliance facts.

|Column              |Type       |Key|Description                   |
|--------------------|-----------|---|------------------------------|
|`namespace_key`     |TEXT       |PK |`cluster_id/namespace_name`   |
|`cluster_id`        |TEXT       |FK |Cluster reference             |
|`namespace_name`    |TEXT       |   |Kubernetes namespace          |
|`app_id_label_raw`  |TEXT       |   |Namespace `app-id` label      |
|`app_id_key`        |TEXT       |FK |Application reference         |
|`owner_match_status`|TEXT       |   |Matched / no label / unmatched|
|`istio_rev_value`   |TEXT       |   |`istio.io/rev` label          |
|`scope_status`      |TEXT       |   |In scope / ignored / excluded |
|`labels`            |JSONB      |   |All namespace labels          |
|`first_seen_ts`     |TIMESTAMPTZ|   |First discovery               |
|`last_seen_ts`      |TIMESTAMPTZ|   |Latest discovery              |

Namespace names are not globally unique. For example, aks-prod-01/payment-api and aks-prod-02/payment-api are different records.

4. core.dim_compliance

Purpose: Defines compliance categories, beginning with OC.

|Column         |Type|Key|Description            |
|---------------|----|---|-----------------------|
|`compliance_id`|TEXT|PK |`OC` or future category|
|`name`         |TEXT|   |Display name           |
|`description`  |TEXT|   |Compliance definition  |

5. core.dim_rule

Purpose: Defines rules belonging to each compliance category.

|Column          |Type|Key|Description           |
|----------------|----|---|----------------------|
|`rule_id`       |TEXT|PK |`OC-1`, `OC-2`        |
|`compliance_id` |TEXT|FK |Parent compliance     |
|`rule_name`     |TEXT|   |Rule name             |
|`description`   |TEXT|   |Rule definition       |
|`expected_value`|TEXT|   |Expected configuration|
|`severity`      |TEXT|   |Rule severity         |
|`rule_version`  |TEXT|   |Rule version          |

|Rule|Criterion                                                                     |Expected value          |
|----|------------------------------------------------------------------------------|------------------------|
|OC-1|Namespace `istio.io/rev` matches expected revision                            |`1.29` (initial setting)|
|OC-2|Every evaluated pod contains `istio-proxy` in `containers` or `initContainers`|`istio-proxy`           |

Succeeded and Failed pods are excluded from OC-2 evaluation.

B. Fact tables

6. core.fact_namespace_compliance

Purpose: Overall compliance verdict per namespace, compliance category and run. Primary source for compliance percentage.

|Column             |Type       |Key   |Description                   |
|-------------------|-----------|------|------------------------------|
|`run_id`           |BIGINT     |PK, FK|Ingestion run                 |
|`namespace_key`    |TEXT       |PK, FK|Namespace                     |
|`compliance_id`    |TEXT       |PK, FK|Compliance category           |
|`cluster_id`       |TEXT       |      |Cluster                       |
|`snapshot_ts`      |TIMESTAMPTZ|      |Source collection time        |
|`compliance_status`|TEXT       |      |Compliant / NonCompliant      |
|`failed_rules`     |TEXT[]     |      |Failed rule IDs               |
|`app_id_key`       |TEXT       |      |Application at evaluation time|
|`app_owner_name`   |TEXT       |      |Owner at evaluation time      |
|`support_team_name`|TEXT       |      |Team at evaluation time       |

PRIMARY KEY (run_id, namespace_key, compliance_id)

|run_id|namespace_key             |compliance_id|compliance_status|failed_rules|
|------|--------------------------|-------------|-----------------|------------|
|1001  |aks-prod-01/payment-api   |OC           |Compliant        |{}          |
|1001  |aks-prod-02/payment-worker|OC           |NonCompliant     |{OC-2}      |
|1001  |aks-prod-01/order-api     |OC           |NonCompliant     |{OC-1}      |

7. core.fact_rule_result

Purpose: Individual rule verdicts. Feeds OC Criteria 1 and OC Criteria 2 columns.

|Column          |Type       |Key|Description                |
|----------------|-----------|---|---------------------------|
|`result_id`     |BIGSERIAL  |PK |Result identifier          |
|`run_id`        |BIGINT     |FK |Ingestion run              |
|`cluster_id`    |TEXT       |   |Cluster                    |
|`snapshot_ts`   |TIMESTAMPTZ|   |Collection time            |
|`namespace_key` |TEXT       |FK |Namespace                  |
|`rule_id`       |TEXT       |FK |OC-1 / OC-2                |
|`status`        |TEXT       |   |Pass / Fail / NotApplicable|
|`actual_value`  |TEXT       |   |Observed value             |
|`expected_value`|TEXT       |   |Required value             |
|`pods_evaluated`|INTEGER    |   |Evaluated pod count        |
|`pods_failing`  |INTEGER    |   |Failing pod count          |
|`failing_pods`  |TEXT[]     |   |Failing pod names          |
|`failure_reason`|TEXT       |   |Failure details            |

UNIQUE (run_id, namespace_key, rule_id)

|namespace_key             |rule_id|status|
|--------------------------|-------|------|
|aks-prod-01/payment-api   |OC-1   |Pass  |
|aks-prod-01/payment-api   |OC-2   |Pass  |
|aks-prod-02/payment-worker|OC-1   |Pass  |
|aks-prod-02/payment-worker|OC-2   |Fail  |

The reporting view pivots these rule rows into OC-1 and OC-2 columns.

8. core.fact_namespace_scope

Purpose: Records every namespace seen in a snapshot, including excluded and ignored namespaces.

|Column         |Type       |Key   |Description                  |
|---------------|-----------|------|-----------------------------|
|`run_id`       |BIGINT     |PK, FK|Ingestion run                |
|`namespace_key`|TEXT       |PK, FK|Namespace                    |
|`cluster_id`   |TEXT       |      |Cluster                      |
|`snapshot_ts`  |TIMESTAMPTZ|      |Collection time              |
|`scope_status` |TEXT       |      |In scope / ignored / excluded|
|`scope_reason` |TEXT       |      |Explanation                  |

9. core.fact_pod

Purpose: Pod-level evidence supporting OC-2 troubleshooting.

|Column            |Type       |Key   |Description                    |
|------------------|-----------|------|-------------------------------|
|`run_id`          |BIGINT     |PK, FK|Ingestion run                  |
|`namespace_key`   |TEXT       |PK, FK|Namespace                      |
|`pod_name`        |TEXT       |PK    |Pod name                       |
|`cluster_id`      |TEXT       |      |Cluster                        |
|`snapshot_ts`     |TIMESTAMPTZ|      |Collection time                |
|`phase`           |TEXT       |      |Pod lifecycle phase            |
|`is_evaluated`    |BOOLEAN    |      |Whether evaluated              |
|`has_sidecar`     |BOOLEAN    |      |Sidecar present                |
|`sidecar_location`|TEXT       |      |`containers` / `initContainers`|

C. Audit tables

10. audit.ingestion_run

|Column                |Type       |Key|Description                           |
|----------------------|-----------|---|--------------------------------------|
|`run_id`              |BIGSERIAL  |PK |Execution ID                          |
|`started_at`          |TIMESTAMPTZ|   |Start time                            |
|`finished_at`         |TIMESTAMPTZ|   |End time                              |
|`status`              |TEXT       |   |Running / succeeded / partial / failed|
|`rules_config_version`|TEXT       |   |Rules configuration version           |
|`notes`               |TEXT       |   |Run notes                             |

11. audit.ingestion_file

|Column              |Type       |Key|Description                        |
|--------------------|-----------|---|-----------------------------------|
|`file_id`           |BIGSERIAL  |PK |File ID                            |
|`run_id`            |BIGINT     |FK |Ingestion run                      |
|`cluster_id`        |TEXT       |   |Source cluster                     |
|`blob_path`         |TEXT       |   |Azure Blob path                    |
|`blob_last_modified`|TIMESTAMPTZ|   |Blob modification time             |
|`snapshot_ts`       |TIMESTAMPTZ|   |Data collection time               |
|`checksum`          |TEXT       |   |File checksum                      |
|`status`            |TEXT       |   |Loaded / skipped_duplicate / failed|
|`error_message`     |TEXT       |   |Failure reason                     |
|`loaded_at`         |TIMESTAMPTZ|   |Import time                        |

Additional supporting tables

|Table                |Purpose                                                             |
|---------------------|--------------------------------------------------------------------|
|`audit.source_load`  |Tracks ownership source imports                                     |
|`audit.scope_summary`|Reconciles evaluated, ignored and excluded namespaces               |
|`core.setting`       |Configures expected revision, sidecar name, exclusions and freshness|
|`core.dim_date`      |Optional calendar dimension for future trends                       |

5. Database relationships

|Parent           |Child                      |Cardinality|
|-----------------|---------------------------|-----------|
|`dim_cluster`    |`dim_namespace`            |1:N        |
|`dim_application`|`dim_namespace`            |1:N        |
|`dim_namespace`  |`fact_namespace_compliance`|1:N        |
|`dim_namespace`  |`fact_rule_result`         |1:N        |
|`dim_compliance` |`dim_rule`                 |1:N        |
|`dim_compliance` |`fact_namespace_compliance`|1:N        |
|`dim_rule`       |`fact_rule_result`         |1:N        |
|`ingestion_run`  |`fact_namespace_compliance`|1:N        |
|`ingestion_run`  |`fact_rule_result`         |1:N        |

An application can be present across clusters through its associated namespaces. Compliance fact rows retain history across ingestion runs.

6. Reporting SQL views

Power BI reads reporting views, not normalized tables directly.

View 1: rpt.vw_oc_compliance_summary

Purpose: Summary metrics for Power BI Page 1. The original schema contains a generic rpt.vw_platform_compliance_summary; this OC-specific name is proposed.

|Output column        |Meaning                             |
|---------------------|------------------------------------|
|`compliance_id`      |OC                                  |
|`total_evaluated`    |Compliant + non-compliant namespaces|
|`compliant_count`    |Number compliant                    |
|`non_compliant_count`|Number non-compliant                |
|`unknown_count`      |Stale/unknown namespace results     |
|`oc_compliance_pct`  |Compliance percentage               |

Only the latest valid namespace results from fresh clusters enter the percentage.

View 2: rpt.vw_oc_namespace_details

Purpose: One row per namespace/cluster for the latest OC result, with the individual criteria pivoted into columns. This is a proposed new view not yet defined in the supplied SQL.

|Output column                  |Source                     |
|-------------------------------|---------------------------|
|`namespace_key` (hidden)       |`dim_namespace`            |
|`namespace_name`               |`dim_namespace`            |
|`cluster_name`                 |`dim_cluster`              |
|`oc_compliance_status`         |`fact_namespace_compliance`|
|`oc_criteria_1`                |`fact_rule_result` (OC-1)  |
|`oc_criteria_2`                |`fact_rule_result` (OC-2)  |
|`application_name`             |`dim_application`          |
|`application_id`               |`dim_application`          |
|`application_owner`            |`dim_application`          |
|`snapshot_ts` (hidden)         |Latest compliance fact     |
|`health_status` (hidden/filter)|Freshness view             |

Sr No is a display row number generated in Power BI. The view must pivot rule-result records so one namespace produces one displayed row.

Supporting view: rpt.vw_cluster_freshness

Already defined in the original SQL. Determines the latest loaded snapshot and whether each cluster is Fresh, Stale, or Missing. A 24-hour staleness threshold is proposed, subject to approval.

7. Design considerations for approval

|Area               |Proposal                                                 |
|-------------------|---------------------------------------------------------|
|Reporting grain    |One namespace per cluster per compliance evaluation      |
|Application mapping|One application may span multiple namespaces and clusters|
|Compliance logic   |Python rule engine, not Power BI                         |
|Rule evidence      |Separate rows in `fact_rule_result`                      |
|Overall verdict    |`fact_namespace_compliance`                              |
|History            |Retain facts for each run                                |
|Traceability       |File checksum, snapshot time and run ID                  |
|Stale data         |Unknown, excluded from percentage                        |
|Missing owner      |`UNASSIGNED`                                             |
|Power BI access    |Reporting views only                                     |
|Future rules       |Add rule definitions and evaluator functions             |

Implementation details to review

1. Historical ownership: The fact table snapshots owner information, but the supplied reporting view joins to the current application master. Historical reporting should use the captured owner values.
2. Dashboard reconciliation: The summary and detail pages must use the same latest valid namespace-level dataset.
3. Complete imports: Only fully processed and committed results should become visible as the latest snapshot.
4. Missing and excluded namespaces: Decide whether Page 2 includes them as Not Evaluated or shows only evaluated namespaces.
5. No running pods: Decide whether OC-2 is NotApplicable or another explicit outcome.

8. Recommendation and approval scope

Retain the normalized PostgreSQL model and expose two Power BI-facing views:

1. rpt.vw_oc_compliance_summary
2. rpt.vw_oc_namespace_details

Both should use the cluster freshness logic. The normalized model supports the initial two criteria, ownership filtering across multiple clusters, audit history and future compliance categories.

Request technical lead approval for: table responsibilities, keys and relationships; compliance fact granularity; source audit strategy; stale/ignored namespace semantics; and the two reporting-view contracts.