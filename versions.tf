terraform {
  # removed blocks (Cloud Run moved out of Terraform) need 1.7.
  required_version = ">= 1.7"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # API Gateway and service identities (IAP, Pub/Sub) are only in the beta provider.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }

  # Shared remote state. The bucket is passed at init time so it is not hardcoded:
  #   terraform init -backend-config=backend.hcl
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
  # Bill API calls to the project: some APIs (API Keys) reject user ADC without a quota project.
  billing_project       = var.project_id
  user_project_override = true
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
