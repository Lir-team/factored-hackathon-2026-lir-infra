#!/usr/bin/env bash
# Creates the GCS bucket that stores the shared Terraform state. Run once per project.
# Usage: scripts/bootstrap-state.sh <project-id> [location]
set -euo pipefail

PROJECT_ID="${1:?usage: $0 <project-id> [location]}"
LOCATION="${2:-us-east1}"
BUCKET="gs://${PROJECT_ID}-tfstate"

gcloud services enable storage.googleapis.com --project "${PROJECT_ID}"

if gcloud storage buckets describe "${BUCKET}" --project "${PROJECT_ID}" >/dev/null 2>&1; then
  echo "State bucket ${BUCKET} already exists."
else
  gcloud storage buckets create "${BUCKET}" \
    --project "${PROJECT_ID}" \
    --location "${LOCATION}" \
    --uniform-bucket-level-access \
    --public-access-prevention
  echo "Created state bucket ${BUCKET}."
fi

# Versioning lets a corrupted or overwritten state be recovered.
gcloud storage buckets update "${BUCKET}" --versioning --project "${PROJECT_ID}"
