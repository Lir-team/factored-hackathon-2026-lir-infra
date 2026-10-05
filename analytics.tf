# Analytics: the agent's audit trail and the evaluation runs in BigQuery, for Looker Studio.
#
# Cloud Run writes every audit entry to stdout as structured JSON (AUDIT_SINK=stdout). A Cloud
# Logging sink streams the entries tagged log=lir_audit into a BigQuery dataset, where views
# turn them into one row per turn, per session and per day. The evals upload their trials to
# the eval_trials table (app/evals/upload_bigquery.py in the agent repository).

locals {
  # Table the sink creates on the first exported entry (named after the log, partitioned).
  audit_log_table = "${var.project_id}.${google_bigquery_dataset.analytics.dataset_id}.run_googleapis_com_stdout"

  # Views read jsonPayload as JSON text, so they do not depend on the columns BigQuery infers.
  analytics_views = {
    audit_events = <<-SQL
      SELECT
        timestamp,
        JSON_VALUE(p, '$.event') AS event,
        JSON_VALUE(p, '$.session_id') AS session_id,
        resource.labels.revision_name AS revision,
        p AS payload
      FROM (
        SELECT timestamp, resource, TO_JSON_STRING(jsonPayload) AS p
        FROM `${local.audit_log_table}`
      )
    SQL

    turns = <<-SQL
      SELECT
        timestamp,
        session_id,
        JSON_VALUE(payload, '$.decision_model') AS decision_model,
        JSON_QUERY(payload, '$.decision_fallback') IS NOT NULL
          AND JSON_QUERY(payload, '$.decision_fallback') != 'null' AS decision_fallback,
        JSON_VALUE(payload, '$.turn_lane') AS turn_lane,
        JSON_VALUE(payload, '$.turn_rule') AS turn_rule,
        JSON_VALUE(payload, '$.case_lane') AS case_lane,
        JSON_VALUE(payload, '$.case_rule') AS case_rule,
        JSON_VALUE(payload, '$.policy_version') AS policy_version,
        JSON_VALUE(payload, '$.llm_model') AS llm_model,
        JSON_VALUE(payload, '$.handoff_id') AS handoff_id,
        ARRAY_LENGTH(JSON_QUERY_ARRAY(payload, '$.tools')) AS tool_calls,
        SAFE_CAST(JSON_VALUE(payload, '$.latency_ms') AS FLOAT64) AS latency_ms,
        SAFE_CAST(JSON_VALUE(payload, '$.input_tokens') AS INT64) AS input_tokens,
        SAFE_CAST(JSON_VALUE(payload, '$.output_tokens') AS INT64) AS output_tokens,
        SAFE_CAST(JSON_VALUE(payload, '$.cost_usd') AS FLOAT64) AS cost_usd,
        JSON_VALUE(payload, '$.decisions.intencion.value') AS intent,
        SAFE_CAST(JSON_VALUE(payload, '$.decisions.intencion.probability') AS FLOAT64) AS intent_probability,
        SAFE_CAST(JSON_VALUE(payload, '$.decisions.pide_humano.probability') AS FLOAT64) AS wants_human_probability,
        SAFE_CAST(JSON_VALUE(payload, '$.decisions.sospecha_robo.probability') AS FLOAT64) AS theft_probability
      FROM `${var.project_id}.${google_bigquery_dataset.analytics.dataset_id}.audit_events`
      WHERE event = 'turn_completed'
    SQL

    outcomes = <<-SQL
      SELECT
        timestamp,
        session_id,
        event,
        CASE
          WHEN event = 'tool_result' AND JSON_VALUE(payload, '$.tool') = 'open_dispute'
            AND JSON_VALUE(payload, '$.status') = 'verified' THEN 'dispute_opened'
          -- Disputes open when their last approver (the specialist) approves.
          WHEN event = 'approval_decided'
            AND JSON_VALUE(payload, '$.result.dispute_case_id') IS NOT NULL THEN 'dispute_opened'
          WHEN event = 'approval_decided' AND JSON_VALUE(payload, '$.decision') = 'rejected'
            THEN CONCAT('rejected_by_', JSON_VALUE(payload, '$.role'))
          -- A specialist resolved an escalated case (the customer's claim accepted or not).
          WHEN event = 'handoff_resolved' THEN CONCAT('claim_', JSON_VALUE(payload, '$.decision'))
          WHEN event = 'handoff_created' THEN 'handoff'
          WHEN event = 'output_blocked' THEN 'reply_blocked'
          WHEN event = 'tool_denied' THEN 'tool_denied'
          WHEN event = 'session_refused' THEN 'session_refused'
          WHEN event = 'decision_fallback' THEN 'decision_fallback'
          WHEN event = 'handoff_report_viewed' THEN 'report_viewed'
        END AS outcome,
        COALESCE(
          JSON_VALUE(payload, '$.trigger'),
          JSON_VALUE(payload, '$.reason'),
          JSON_VALUE(payload, '$.result.dispute_case_id')
        ) AS detail
      FROM `${var.project_id}.${google_bigquery_dataset.analytics.dataset_id}.audit_events`
      WHERE event IN ('tool_result', 'handoff_created', 'output_blocked', 'tool_denied',
                      'session_refused', 'decision_fallback', 'handoff_report_viewed',
                      'approval_decided', 'handoff_resolved')
        AND NOT (event = 'tool_result' AND (JSON_VALUE(payload, '$.tool') != 'open_dispute'
                 OR JSON_VALUE(payload, '$.status') != 'verified'))
        AND NOT (event = 'approval_decided' AND JSON_VALUE(payload, '$.decision') = 'approved'
                 AND JSON_VALUE(payload, '$.result.dispute_case_id') IS NULL)
    SQL

    sessions = <<-SQL
      SELECT
        session_id,
        MIN(timestamp) AS started_at,
        MAX(timestamp) AS last_turn_at,
        COUNT(*) AS turns,
        ARRAY_AGG(case_lane IGNORE NULLS ORDER BY timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS final_case_lane,
        LOGICAL_OR(turn_lane = 'escalate' OR case_lane = 'escalate') AS escalated,
        LOGICAL_OR(handoff_id IS NOT NULL) AS handed_off,
        SUM(cost_usd) AS cost_usd,
        SUM(latency_ms) AS total_latency_ms
      FROM `${var.project_id}.${google_bigquery_dataset.analytics.dataset_id}.turns`
      GROUP BY session_id
    SQL

    daily_kpis = <<-SQL
      SELECT
        DATE(t.timestamp) AS day,
        COUNT(DISTINCT t.session_id) AS sessions,
        COUNT(*) AS turns,
        COUNTIF(t.case_lane = 'dispute') AS dispute_lane_turns,
        COUNTIF(t.turn_lane = 'escalate' OR t.case_lane = 'escalate') AS escalated_turns,
        APPROX_QUANTILES(t.latency_ms, 100)[SAFE_OFFSET(50)] AS latency_p50_ms,
        APPROX_QUANTILES(t.latency_ms, 100)[SAFE_OFFSET(95)] AS latency_p95_ms,
        SUM(t.cost_usd) AS cost_usd,
        SAFE_DIVIDE(SUM(t.cost_usd), COUNT(DISTINCT t.session_id)) AS cost_per_session_usd,
        COUNTIF(t.decision_fallback) AS decision_fallbacks
      FROM `${var.project_id}.${google_bigquery_dataset.analytics.dataset_id}.turns` AS t
      GROUP BY day
    SQL
  }
}

resource "google_bigquery_dataset" "analytics" {
  dataset_id    = var.analytics_dataset_id
  friendly_name = "Lir analytics"
  description   = "Audit trail of the Lir agent (Cloud Logging sink) and evaluation runs."
  location      = var.analytics_location

  depends_on = [google_project_service.enabled]
}

resource "google_logging_project_sink" "audit_to_bigquery" {
  name        = "lir-audit-to-bigquery"
  description = "Audit entries of the Lir agent (log=lir_audit) into BigQuery."
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.analytics.dataset_id}"
  filter      = "resource.type=\"cloud_run_revision\" AND jsonPayload.log=\"lir_audit\""

  unique_writer_identity = true
  bigquery_options {
    use_partitioned_tables = true
  }
}

resource "google_bigquery_dataset_iam_member" "sink_writes" {
  dataset_id = google_bigquery_dataset.analytics.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.audit_to_bigquery.writer_identity
}

resource "google_bigquery_table" "eval_trials" {
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "eval_trials"
  description         = "One row per evaluation trial (app/evals), uploaded after each run."
  deletion_protection = false

  time_partitioning {
    type  = "DAY"
    field = "run_at"
  }

  schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "REQUIRED" },
    { name = "run_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "git_sha", type = "STRING", mode = "NULLABLE" },
    { name = "agent_model", type = "STRING", mode = "NULLABLE" },
    { name = "scenario_id", type = "STRING", mode = "NULLABLE" },
    { name = "jtbd", type = "STRING", mode = "REPEATED" },
    { name = "kind", type = "STRING", mode = "NULLABLE" },
    { name = "lang", type = "STRING", mode = "NULLABLE" },
    { name = "expected", type = "STRING", mode = "NULLABLE" },
    { name = "code_pass", type = "BOOL", mode = "NULLABLE" },
    { name = "rubric_pass", type = "BOOL", mode = "NULLABLE" },
    { name = "outcome", type = "FLOAT64", mode = "NULLABLE" },
    { name = "safety", type = "FLOAT64", mode = "NULLABLE" },
    { name = "grounding", type = "FLOAT64", mode = "NULLABLE" },
    { name = "language", type = "FLOAT64", mode = "NULLABLE" },
    { name = "efficiency", type = "FLOAT64", mode = "NULLABLE" },
    { name = "quality", type = "FLOAT64", mode = "NULLABLE" },
    { name = "handoffs", type = "INT64", mode = "NULLABLE" },
    { name = "disputes", type = "INT64", mode = "NULLABLE" },
    { name = "latency_ms", type = "FLOAT64", mode = "NULLABLE" },
    { name = "cost_usd", type = "FLOAT64", mode = "NULLABLE" },
    { name = "error", type = "STRING", mode = "NULLABLE" },
    { name = "reason", type = "STRING", mode = "NULLABLE" },
  ])
}

# The views read the table the sink creates on its first exported entry, so they are created
# in a second apply (analytics_views_enabled = true) once the agent has served one turn.
# Each view reads the previous ones, hence the explicit chain.
resource "google_bigquery_table" "view_audit_events" {
  count               = var.analytics_views_enabled ? 1 : 0
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "audit_events"
  deletion_protection = false
  view {
    query          = local.analytics_views.audit_events
    use_legacy_sql = false
  }
}

resource "google_bigquery_table" "view_turns" {
  count               = var.analytics_views_enabled ? 1 : 0
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "turns"
  deletion_protection = false
  view {
    query          = local.analytics_views.turns
    use_legacy_sql = false
  }
  depends_on = [google_bigquery_table.view_audit_events]
}

resource "google_bigquery_table" "view_outcomes" {
  count               = var.analytics_views_enabled ? 1 : 0
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "outcomes"
  deletion_protection = false
  view {
    query          = local.analytics_views.outcomes
    use_legacy_sql = false
  }
  depends_on = [google_bigquery_table.view_audit_events]
}

resource "google_bigquery_table" "view_sessions" {
  count               = var.analytics_views_enabled ? 1 : 0
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "sessions"
  deletion_protection = false
  view {
    query          = local.analytics_views.sessions
    use_legacy_sql = false
  }
  depends_on = [google_bigquery_table.view_turns]
}

resource "google_bigquery_table" "view_daily_kpis" {
  count               = var.analytics_views_enabled ? 1 : 0
  dataset_id          = google_bigquery_dataset.analytics.dataset_id
  table_id            = "daily_kpis"
  deletion_protection = false
  view {
    query          = local.analytics_views.daily_kpis
    use_legacy_sql = false
  }
  depends_on = [google_bigquery_table.view_turns]
}
