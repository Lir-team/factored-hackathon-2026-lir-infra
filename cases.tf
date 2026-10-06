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

locals {
  # The cases service runs the same image as the operator API with the case flow switched
  # on. GitHub Actions deploys it with cases_env / cases_secret_env (outputs).
  # Pub/Sub signs each push with an OIDC token for this audience. It is a fixed string,
  # not the service URL: the URL only exists after the service is created, so the service
  # could not receive it in its own environment. Cloud Run accepts it because it is listed
  # in `custom_audiences`, and the agent checks it again (PUBSUB_PUSH_AUDIENCE).
  cases_push_audience = "${var.cases_service_name}-pubsub-push"

  # The service exists (deployed by GitHub Actions) once its URL is set: the gateway, the
  # push subscription and the invoker bindings wait for it (two-phase apply).
  cases_deployed = var.cases_service_url != ""

  cases_env = merge(
    local.agent_env,
    {
      # With customer_sign_in the gateway verifies the customer's JWT and the service
      # takes the customer from it, never from the payload (SEC-01); approvals then need
      # that sign-in too (step-up, SEC-04). Without it the payload's customer_id is trusted
      # and the API key on /v1/cases is what stops abuse. The service is only reachable
      # through the gateway and Pub/Sub (run.invoker), so the operator routes stay closed.
      REQUIRE_IDENTITY          = var.customer_sign_in ? "true" : "false"
      APPROVAL_REQUIRES_SIGN_IN = var.customer_sign_in ? "true" : "false"
      # lir-web runs on a laptop; the gateway passes CORS through (allowCors) to the service.
      CORS_ORIGINS = var.cors_origins
      # The back office is only for specialists, behind IAP on the operator service.
      BACKOFFICE_ENABLED = "false"

      CASES_INBOX  = "gcs"
      CASES_BUCKET = google_storage_bucket.cases.name

      CASES_PUBLISHER = "pubsub"
      CASES_TOPIC     = google_pubsub_topic.cases.name

      PUBSUB_PUSH_AUDIENCE        = local.cases_push_audience
      PUBSUB_PUSH_SERVICE_ACCOUNT = google_service_account.pubsub_push.email
    },
    var.telegram_bot_username == "" ? {} : { TELEGRAM_BOT_USERNAME = var.telegram_bot_username },
    local.demo_sign_in ? {
      DEMO_SIGN_IN_CUSTOMER_ID = var.demo_sign_in_customer_id
      DEMO_SIGN_IN_ISSUER      = local.customer_jwt_issuer
      DEMO_SIGN_IN_AUDIENCE    = var.customer_jwt_audience
      DEMO_SIGN_IN_TTL_MINUTES = tostring(var.demo_sign_in_ttl_minutes)
    } : {},
    var.speech_to_text_enabled ? { SPEECH_TO_TEXT = "google" } : {},
    # Link to the approval card in lir-web; Telegram only opens https links from a button.
    var.approval_link_template == "" ? {} : { APPROVAL_LINK_TEMPLATE = var.approval_link_template },
  )

  # The Telegram secrets (agent_secret_env) are mounted only once they hold a version
  # (telegram_enabled); without them the agent starts and leaves /channels/telegram off.
  cases_secret_env = local.agent_secret_env
}

# ---- runtime identity -------------------------------------------------------------------

resource "google_service_account" "cases" {
  account_id   = "${var.cases_service_name}-run"
  display_name = "Lir case flow (Cloud Run runtime)"
}

# Writes `cases/<case_id>.json`. objectCreator alone is not enough: a client retry after a
# failed publish writes the same case again, and replacing an object needs delete.
# objectUser adds read/delete on objects of this bucket only, never on its settings or IAM.
resource "google_storage_bucket_iam_member" "cases_writes_inbox" {
  bucket = google_storage_bucket.cases.name
  role   = "roles/storage.objectUser"
  member = google_service_account.cases.member
}

resource "google_storage_bucket_iam_member" "cases_reads_data" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.cases.member
}

resource "google_pubsub_topic_iam_member" "cases_publishes" {
  topic  = google_pubsub_topic.cases.name
  role   = "roles/pubsub.publisher"
  member = google_service_account.cases.member
}

# Firestore IAM is project-wide; datastore.user reads and writes documents, nothing more.
resource "google_project_iam_member" "cases_uses_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = google_service_account.cases.member
}

# Transcribes Telegram voice notes (speech.recognize); granted only while voice notes are on.
resource "google_project_iam_member" "cases_uses_speech" {
  count = var.speech_to_text_enabled ? 1 : 0

  project = var.project_id
  role    = "roles/speech.client"
  member  = google_service_account.cases.member
}

resource "google_secret_manager_secret_iam_member" "cases" {
  for_each = toset(values(local.cases_secret_env))

  secret_id = google_secret_manager_secret.this[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.cases.member
}

# ---- service ----------------------------------------------------------------------------

# Public network path, private IAM: only the gateway and the Pub/Sub push accounts hold
# run.invoker, so every other request is rejected by Cloud Run before the agent sees it.
resource "google_cloud_run_v2_service_iam_member" "cases_invokers" {
  for_each = local.cases_deployed ? {
    gateway     = google_service_account.gateway.member
    pubsub_push = google_service_account.pubsub_push.member
  } : {}

  name     = var.cases_service_name
  location = var.region
  role     = "roles/run.invoker"
  member   = each.value
}
