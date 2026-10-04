# Data pipeline as a Cloud Run job: reads the organizers' S3 bucket with the AWS secrets,
# runs every stage (ingest -> staging -> quality -> curated -> insights) and publishes
# staging/ and curated/ to the data lake bucket that the agent mounts read-only at /mnt/data.
#
# Run it with: gcloud run jobs execute <pipeline_job_name> --region <region> --wait

locals {
  pipeline_deploy = var.pipeline_image != ""
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

resource "google_cloud_run_v2_job" "pipeline" {
  count = local.pipeline_deploy ? 1 : 0

  name                = var.pipeline_job_name
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account       = google_service_account.pipeline.email
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = var.pipeline_timeout
      max_retries           = 1

      containers {
        image = var.pipeline_image

        resources {
          limits = {
            cpu    = var.pipeline_cpu
            memory = var.pipeline_memory
          }
        }

        env {
          name  = "LAKE_DIR"
          value = "/mnt/lake"
        }

        env {
          name  = "AWS_DEFAULT_REGION"
          value = var.pipeline_aws_region
        }

        dynamic "env" {
          for_each = local.pipeline_secret_env
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
          name       = "lake"
          mount_path = "/mnt/lake"
        }
      }

      volumes {
        name = "lake"
        gcs {
          bucket    = google_storage_bucket.data.name
          read_only = false
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.pipeline,
    google_storage_bucket_iam_member.pipeline_writes_data,
  ]
}
