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
  # on. Pub/Sub signs each push with an OIDC token for this audience. It is a fixed string,
  # not the service URL: the URL only exists after the service is created, so the service
  # could not receive it in its own environment. Cloud Run accepts it because it is listed
  # in `custom_audiences`, and the agent checks it again (PUBSUB_PUSH_AUDIENCE).
  cases_push_audience = "${var.cases_service_name}-pubsub-push"

  cases_env = merge(
    local.agent_env,
    {
      # No customer login yet: the payload's customer_id is trusted, and the gateway's API
      # key on /v1/cases is what stops abuse. The service is only reachable through the
      # gateway and Pub/Sub (run.invoker), so the operator routes stay closed.
      REQUIRE_IDENTITY = "false"
      # lir-web runs on a laptop; the gateway passes CORS through (allowCors) to the service.
      CORS_ORIGINS = var.cors_origins

      CASES_INBOX  = "gcs"
      CASES_BUCKET = google_storage_bucket.cases.name

      CASES_PUBLISHER      = "pubsub"
      GOOGLE_CLOUD_PROJECT = var.project_id
      CASES_TOPIC          = google_pubsub_topic.cases.name

      PUBSUB_PUSH_AUDIENCE        = local.cases_push_audience
      PUBSUB_PUSH_SERVICE_ACCOUNT = google_service_account.pubsub_push.email

      CASE_STORE                  = "firestore"
      FIRESTORE_DATABASE          = google_firestore_database.default.name
      FIRESTORE_COLLECTION_PREFIX = var.firestore_collection_prefix
    },
    var.telegram_bot_username == "" ? {} : { TELEGRAM_BOT_USERNAME = var.telegram_bot_username },
  )

  cases_secret_env = merge(
    local.agent_secret_env,
    {
      TELEGRAM_BOT_TOKEN      = "telegram_bot_token"
      TELEGRAM_WEBHOOK_SECRET = "telegram_webhook_secret"
    },
  )
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

resource "google_secret_manager_secret_iam_member" "cases" {
  for_each = toset(values(local.cases_secret_env))

  secret_id = google_secret_manager_secret.this[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.cases.member
}

# ---- service ----------------------------------------------------------------------------

resource "google_cloud_run_v2_service" "cases" {
  count = local.deploy ? 1 : 0

  name     = var.cases_service_name
  location = var.region
  # Public network path, private IAM: only the gateway and the Pub/Sub push accounts hold
  # run.invoker, so every other request is rejected by Cloud Run before the agent sees it.
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false
  custom_audiences    = [local.cases_push_audience]

  template {
    service_account       = google_service_account.cases.email
    execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

    scaling {
      min_instance_count = 0
      # ADK sessions live in memory: a second instance would not know the conversation.
      max_instance_count = var.cases_max_instances
    }

    containers {
      image = var.agent_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      dynamic "env" {
        for_each = local.cases_env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.cases_secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this[env.value].secret_id
              version = "latest"
            }
          }
        }
      }

      volume_mounts {
        name       = "data"
        mount_path = "/mnt/data"
      }

      startup_probe {
        http_get {
          path = "/health"
        }
      }
    }

    volumes {
      name = "data"
      gcs {
        bucket    = google_storage_bucket.data.name
        read_only = true
      }
    }
  }

  lifecycle {
    # CI deploys new images with `gcloud run deploy`, which also stamps the client fields
    # and names the revision; Terraform owns the rest of the configuration.
    ignore_changes = [
      template[0].containers[0].image,
      template[0].revision,
      client,
      client_version,
      scaling,
    ]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.cases,
    google_storage_bucket_iam_member.cases_reads_data,
    google_storage_bucket_iam_member.cases_writes_inbox,
  ]
}

resource "google_cloud_run_v2_service_iam_member" "cases_invokers" {
  for_each = local.deploy ? {
    gateway     = google_service_account.gateway.member
    pubsub_push = google_service_account.pubsub_push.member
  } : {}

  name     = google_cloud_run_v2_service.cases[0].name
  location = var.region
  role     = "roles/run.invoker"
  member   = each.value
}
