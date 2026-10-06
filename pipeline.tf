# Data pipeline as a Cloud Run job: reads the organizers' S3 bucket with the AWS secrets,
# runs every stage (ingest -> staging -> quality -> curated -> insights) and publishes
# staging/ and curated/ to the data lake bucket that the agent mounts read-only at /mnt/data.
#
# The job itself is created by hand outside Terraform (README, "Cloud Run is deployed outside
# Terraform"); Terraform owns its runtime account, its data lake write access and its secrets.
#
# Run it with: gcloud run jobs execute <pipeline_job_name> --region <region> --wait

locals {
  pipeline_secret_env = {
    AWS_ACCESS_KEY_ID     = "aws_access_key_id"
    AWS_SECRET_ACCESS_KEY = "aws_secret_access_key"
  }
}

resource "google_service_account" "pipeline" {
  account_id   = "${var.pipeline_job_name}-run"
  display_name = "Lir data pipeline (Cloud Run job runtime)"
}

# The only writer of the data lake: the agent and the case flow only read it.
resource "google_storage_bucket_iam_member" "pipeline_writes_data" {
  bucket = google_storage_bucket.data.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.pipeline.member
}

resource "google_secret_manager_secret_iam_member" "pipeline" {
  for_each = toset(values(local.pipeline_secret_env))

  secret_id = google_secret_manager_secret.this[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.pipeline.member
}

