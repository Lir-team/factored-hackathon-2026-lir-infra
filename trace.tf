# Cloud Trace: both runtime accounts write the agent's spans (TRACE_TO_CLOUD in agent_env).

resource "google_project_iam_member" "writes_traces" {
  for_each = var.trace_enabled ? {
    agent = google_service_account.agent.member
    cases = google_service_account.cases.member
  } : {}

  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = each.value
}
