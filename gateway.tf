# Public entry of the case flow: API Gateway in front of the cases service.
#   POST /v1/cases          lir-web form, requires the API key (?key=)
#   POST /channels/telegram Telegram webhook, authenticated by the agent's secret_token check
# Nothing else of the service is exposed. The gateway calls the service as lir-gateway.

resource "google_service_account" "gateway" {
  account_id   = "lir-gateway"
  display_name = "Lir case flow gateway (API Gateway backend calls)"
}

resource "google_api_gateway_api" "cases" {
  provider = google-beta

  api_id       = "lir-cases"
  display_name = "Lir case flow"

  depends_on = [google_project_service.enabled]
}

resource "google_api_gateway_api_config" "cases" {
  count    = local.deploy ? 1 : 0
  provider = google-beta

  api = google_api_gateway_api.cases.api_id
  # Configs are immutable: every spec change creates a new one, swapped in before the old
  # one is deleted so the gateway is never left without a config.
  api_config_id_prefix = "lir-cases-"
  display_name         = "Lir case flow"

  openapi_documents {
    document {
      path = "cases.yaml"
      contents = base64encode(templatefile("${path.module}/openapi/cases.yaml.tftpl", {
        title           = "Lir case flow"
        managed_service = google_api_gateway_api.cases.managed_service
        backend_address = google_cloud_run_v2_service.cases[0].uri
      }))
    }
  }

  gateway_config {
    backend_config {
      google_service_account = google_service_account.gateway.email
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_api_gateway_gateway" "cases" {
  count    = local.deploy ? 1 : 0
  provider = google-beta

  gateway_id   = "lir-cases"
  display_name = "Lir case flow"
  region       = var.region
  api_config   = google_api_gateway_api_config.cases[0].id
}

# API keys only work for a gateway whose managed service is enabled in the project.
resource "google_project_service" "cases_api" {
  count = local.deploy ? 1 : 0

  service            = google_api_gateway_api.cases.managed_service
  disable_on_destroy = false

  depends_on = [google_api_gateway_gateway.cases]
}

# Key for lir-web, usable only against this gateway. It ends up in a browser, so it only
# rate-limits and gates abuse; it is not a secret that proves who the caller is.
resource "google_apikeys_key" "cases" {
  name         = "lir-cases-web"
  display_name = "Lir case flow (lir-web)"

  restrictions {
    api_targets {
      service = google_api_gateway_api.cases.managed_service
    }
  }

  depends_on = [google_project_service.enabled]
}
