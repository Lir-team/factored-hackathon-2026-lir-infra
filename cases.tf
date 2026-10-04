# Case flow: the archive of every case accepted through `POST /v1/cases`.

resource "google_storage_bucket" "cases" {
  # The agent's CASES_BUCKET (CASES_INBOX=gcs): one `cases/<case_id>.json` per case.
  name                        = "${var.project_id}-cases"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  # Archived cases are the audit trail of what customers filed; never destroy them by accident.
  force_destroy = false

  # Each case is written once under its own id: versions would only duplicate it.
  versioning {
    enabled = false
  }

  dynamic "lifecycle_rule" {
    for_each = var.cases_retention_days > 0 ? [var.cases_retention_days] : []
    content {
      condition {
        age = lifecycle_rule.value
      }
      action {
        type = "Delete"
      }
    }
  }

  depends_on = [google_project_service.enabled]
}
