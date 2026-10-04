# CI deploys: GitHub Actions on the agent repository signs in with Workload Identity
# Federation (no key files: the organization forbids them), builds the image with Cloud
# Build as lir-build and rolls it out to both Cloud Run services with `gcloud run deploy`.

locals {
  # Image deploys run on every push to the deploy branch of the agent repository only.
  deploy_ref = "refs/heads/${var.deploy_branch}"
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  description               = "Identities of GitHub Actions workflows that deploy Lir."

  depends_on = [google_project_service.enabled]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "lir-team"
  display_name                       = "Lir-team on GitHub"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Tokens from any other repository or branch are rejected before any IAM check.
  attribute_condition = "assertion.repository == \"${var.github_repository}\" && assertion.ref == \"${local.deploy_ref}\""
}

# ---- deploy identity --------------------------------------------------------------------

resource "google_service_account" "deploy" {
  account_id   = "lir-deploy"
  display_name = "Lir CI deploys (GitHub Actions)"
}

resource "google_service_account_iam_member" "github_impersonates_deploy" {
  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# `gcloud builds submit`: create builds, consume the project's APIs and stream the build
# logs (builds log to Cloud Logging only, see cloudbuild.yaml).
resource "google_project_iam_member" "deploy" {
  for_each = toset([
    "roles/cloudbuild.builds.editor",
    "roles/serviceusage.serviceUsageConsumer",
    "roles/logging.viewer",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.deploy.member
}

# Upload the source tarball to --gcs-source-staging-dir; gcloud also reads the bucket.
resource "google_storage_bucket_iam_member" "deploy_uploads_source" {
  for_each = toset([
    "roles/storage.objectCreator",
    "roles/storage.legacyBucketReader",
  ])

  bucket = google_storage_bucket.build_source.name
  role   = each.value
  member = google_service_account.deploy.member
}

# `--service-account lir-build` on the build, and `gcloud run deploy` keeping each
# service's runtime account, both need actAs on that account.
resource "google_service_account_iam_member" "deploy_acts_as" {
  for_each = {
    build = google_service_account.build.name
    agent = google_service_account.agent.name
    cases = google_service_account.cases.name
  }

  service_account_id = each.value
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.deploy.member
}

resource "google_artifact_registry_repository_iam_member" "deploy_reads_images" {
  repository = google_artifact_registry_repository.images.name
  location   = var.region
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.deploy.member
}

# New revisions only: run.developer cannot change who may invoke the services.
resource "google_cloud_run_v2_service_iam_member" "deploy_rolls_out" {
  for_each = local.deploy ? {
    agent = google_cloud_run_v2_service.agent[0].name
    cases = google_cloud_run_v2_service.cases[0].name
  } : {}

  name     = each.value
  location = var.region
  role     = "roles/run.developer"
  member   = google_service_account.deploy.member
}
