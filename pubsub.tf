# Case queue: the cases service publishes each accepted case to `lir-cases` (ordering key =
# customer) and Pub/Sub pushes it back to `/pubsub/push`, where the agent works it.

resource "google_pubsub_topic" "cases" {
  name = "lir-cases"

  depends_on = [google_project_service.enabled]
}

# Cases that failed max_delivery_attempts times land here instead of being dropped.
resource "google_pubsub_topic" "cases_dead_letter" {
  name = "lir-cases-dead-letter"

  depends_on = [google_project_service.enabled]
}

# A topic without subscriptions discards what it receives: this one keeps dead letters
# for a week so they can be inspected (`gcloud pubsub subscriptions pull`).
resource "google_pubsub_subscription" "cases_dead_letter" {
  name                       = "lir-cases-dead-letter"
  topic                      = google_pubsub_topic.cases_dead_letter.id
  message_retention_duration = "604800s"

  expiration_policy {
    ttl = ""
  }
}

# Identity Pub/Sub signs the push requests as; the service only accepts its tokens.
resource "google_service_account" "pubsub_push" {
  account_id   = "lir-pubsub-push"
  display_name = "Lir case queue (Pub/Sub push to Cloud Run)"
}

resource "google_pubsub_subscription" "cases_push" {
  count = local.deploy ? 1 : 0

  name  = "lir-cases-push"
  topic = google_pubsub_topic.cases.id

  # The first agent turn (an LLM call) runs inside the push request.
  ack_deadline_seconds    = 120
  enable_message_ordering = true

  push_config {
    push_endpoint = "${google_cloud_run_v2_service.cases[0].uri}/pubsub/push"

    oidc_token {
      service_account_email = google_service_account.pubsub_push.email
      audience              = local.cases_push_audience
    }
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.cases_dead_letter.id
    max_delivery_attempts = 5
  }

  expiration_policy {
    ttl = ""
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.cases_invokers,
    google_service_account_iam_member.pubsub_signs_push,
  ]
}

# ---- Pub/Sub service agent ----------------------------------------------------------------

resource "google_project_service_identity" "pubsub" {
  provider = google-beta
  service  = "pubsub.googleapis.com"

  depends_on = [google_project_service.enabled]
}

# Mints the push OIDC tokens as lir-pubsub-push.
resource "google_service_account_iam_member" "pubsub_signs_push" {
  service_account_id = google_service_account.pubsub_push.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.pubsub.member
}

# Dead lettering: the service agent forwards from the subscription to the dead-letter topic.
resource "google_pubsub_topic_iam_member" "pubsub_dead_letters" {
  topic  = google_pubsub_topic.cases_dead_letter.name
  role   = "roles/pubsub.publisher"
  member = google_project_service_identity.pubsub.member
}

resource "google_pubsub_subscription_iam_member" "pubsub_forwards_dead_letters" {
  count = local.deploy ? 1 : 0

  subscription = google_pubsub_subscription.cases_push[0].name
  role         = "roles/pubsub.subscriber"
  member       = google_project_service_identity.pubsub.member
}
