# lir-web CI deploys: GitHub Actions on the lir-web repository signs in with Workload Identity
# Federation, pushes the nginx image to its own registry and deploys the public Cloud Run
# service (created and configured by the workflow, not by Terraform).

locals {
  # Cloud Run runs lir-web as the project's default compute account.
  default_compute_account = "${google_project.this.number}-compute@developer.gserviceaccount.com"
}

resource "google_artifact_registry_repository" "web" {
  repository_id = var.web_repository
  location      = var.region
  format        = "DOCKER"
  description   = "Images of the lir-web frontend, pushed by its GitHub Actions workflow."

  depends_on = [google_project_service.enabled]
}

resource "google_iam_workload_identity_pool_provider" "web" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "lir-web"
  display_name                       = "lir-web on GitHub"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Tokens from any other repository or branch are rejected before any IAM check.
  attribute_condition = "assertion.repository == \"${var.web_github_repository}\" && assertion.ref == \"${local.deploy_ref}\""
}

resource "google_service_account" "web_deploy" {
  account_id   = "lir-web-sa"
  display_name = "lir-web GitHub deployer"
}

resource "google_service_account_iam_member" "github_impersonates_web_deploy" {
  service_account_id = google_service_account.web_deploy.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.web_github_repository}"
}

resource "google_artifact_registry_repository_iam_member" "web_deploy_pushes_images" {
  repository = google_artifact_registry_repository.web.name
  location   = var.region
  role       = "roles/artifactregistry.writer"
  member     = google_service_account.web_deploy.member
}

# run.admin: the workflow creates the service and makes it public (allUsers invoker).
resource "google_project_iam_member" "web_deploy_runs_services" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = google_service_account.web_deploy.member
}

resource "google_service_account_iam_member" "web_deploy_acts_as_compute" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.default_compute_account}"
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.web_deploy.member
}
