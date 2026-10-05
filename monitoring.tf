# Cloud Monitoring: the team hears by email when a case is lost, the case flow fails, or the
# public page goes down. Off until var.monitoring_enabled is true.

locals {
  alert_emails = var.monitoring_enabled ? toset(coalescelist(var.alert_emails, keys(var.team_members))) : toset([])
  web_host     = trimsuffix(trimprefix(var.web_url, "https://"), "/")
}

resource "google_monitoring_notification_channel" "team" {
  for_each = local.alert_emails

  display_name = "Lir alerts: ${each.value}"
  type         = "email"
  labels       = { email_address = each.value }

  depends_on = [google_project_service.enabled]
}

# A case Pub/Sub could not deliver after every retry: the customer never got an answer.
resource "google_monitoring_alert_policy" "dead_letter" {
  count = var.monitoring_enabled ? 1 : 0

  display_name          = "Lir: a case reached the dead-letter topic"
  combiner              = "OR"
  notification_channels = [for c in google_monitoring_notification_channel.team : c.id]

  conditions {
    display_name = "Undelivered cases in ${google_pubsub_subscription.cases_dead_letter.name}"
    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.labels.subscription_id = \"${google_pubsub_subscription.cases_dead_letter.name}\" AND metric.type = \"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  documentation {
    content   = "A case failed every delivery attempt and sits in `${google_pubsub_subscription.cases_dead_letter.name}`. Inspect it with `gcloud pubsub subscriptions pull ${google_pubsub_subscription.cases_dead_letter.name}` and check the case flow service logs."
    mime_type = "text/markdown"
  }
}

# The case flow answers with server errors: customers cannot file cases or chat.
resource "google_monitoring_alert_policy" "cases_errors" {
  count = var.monitoring_enabled ? 1 : 0

  display_name          = "Lir: server errors in ${var.cases_service_name}"
  combiner              = "OR"
  notification_channels = [for c in google_monitoring_notification_channel.team : c.id]

  conditions {
    display_name = "5xx responses from ${var.cases_service_name}"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${var.cases_service_name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.labels.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.error_alert_threshold
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  documentation {
    content   = "More than ${var.error_alert_threshold} server errors in 5 minutes. Check the `${var.cases_service_name}` logs in Cloud Logging."
    mime_type = "text/markdown"
  }
}

# The public page the customers (and the jury) open.
resource "google_monitoring_uptime_check_config" "web" {
  count = var.monitoring_enabled && var.web_url != "" ? 1 : 0

  display_name = "lir-web is up"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path         = "/"
    port         = 443
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type   = "uptime_url"
    labels = { project_id = var.project_id, host = local.web_host }
  }
}

resource "google_monitoring_alert_policy" "web_down" {
  count = var.monitoring_enabled && var.web_url != "" ? 1 : 0

  display_name          = "Lir: lir-web is down"
  combiner              = "OR"
  notification_channels = [for c in google_monitoring_notification_channel.team : c.id]

  conditions {
    display_name = "Uptime check failing"
    condition_threshold {
      filter          = "resource.type = \"uptime_url\" AND metric.type = \"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.labels.check_id = \"${google_monitoring_uptime_check_config.web[0].uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "600s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  documentation {
    content   = "The uptime check on ${var.web_url} failed from more than one region for 10 minutes."
    mime_type = "text/markdown"
  }
}
