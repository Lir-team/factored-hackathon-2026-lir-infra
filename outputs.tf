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
