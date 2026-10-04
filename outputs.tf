output "team_roles" {
  description = "Roles granted to each team member by this configuration."
  value       = var.team_members
}

output "image_registry" {
  description = "Prefix for image tags: <image_registry>/lir-agent:<tag>."
  value       = local.image_registry
}

output "data_bucket" {
  description = "Bucket with the data lake (staging/ is mounted by the agent at /mnt/data)."
  value       = google_storage_bucket.data.name
}

output "secrets" {
  description = "Secret Manager secrets whose values are added outside Terraform."
  value       = sort(values(local.secrets))
}

output "build_service_account" {
  description = "Service account for `gcloud builds submit --service-account`."
  value       = google_service_account.build.id
}

output "build_source_bucket" {
  description = "Bucket for `gcloud builds submit --gcs-source-staging-dir`."
  value       = google_storage_bucket.build_source.name
}

output "agent_url" {
  description = "Agent API URL (behind IAP). Empty until agent_image is set."
  value       = local.deploy ? google_cloud_run_v2_service.agent[0].uri : ""
}

output "enabled_apis" {
  description = "APIs enabled by this configuration."
  value       = sort(tolist(var.enabled_apis))
}

output "cases_bucket" {
  description = "Cases inbox bucket (the agent's CASES_BUCKET)."
  value       = google_storage_bucket.cases.name
}

output "firestore_database" {
  description = "Firestore database of the case store (the agent's FIRESTORE_DATABASE)."
  value       = google_firestore_database.default.name
}

output "cases_gateway_url" {
  description = "Public URL of the case flow (lir-web casesEndpoint base, Telegram webhook base)."
  value       = local.deploy ? "https://${google_api_gateway_gateway.cases[0].default_hostname}" : ""
}

output "cases_service_url" {
  description = "Cloud Run URL of the case flow service (invokers only: gateway and Pub/Sub)."
  value       = local.deploy ? google_cloud_run_v2_service.cases[0].uri : ""
}

output "cases_api_key" {
  description = "API key lir-web sends as ?key= on POST /v1/cases."
  value       = google_apikeys_key.cases.key_string
  sensitive   = true
}

output "cases_topics" {
  description = "Pub/Sub topics of the case queue and its dead letters."
  value = {
    cases       = google_pubsub_topic.cases.name
    dead_letter = google_pubsub_topic.cases_dead_letter.name
  }
}

output "wif_provider" {
  description = "Workload Identity provider for google-github-actions/auth (GitHub variable WIF_PROVIDER)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deploy_service_account" {
  description = "Service account CI impersonates to build and deploy (GitHub variable DEPLOY_SA)."
  value       = google_service_account.deploy.email
}
