#!/usr/bin/env bash
# Mint a demo customer JWT: the mocked bank sign-in (identity.tf). It is signed by the
# lir-demo-idp service account through the IAM API, so no private key is ever downloaded.
# API Gateway accepts it on the case flow when customer_sign_in is true.
#
# Usage: scripts/issue-demo-token.sh <customer_id> [project_id] [audience] [minutes]
#   scripts/issue-demo-token.sh CLI-DEMO-001
# Use it as a Bearer token for API tests (curl, Swagger); the deployed lir-web signs in by itself.
set -euo pipefail

customer="${1:?customer id, e.g. CLI-DEMO-001}"
project="${2:-lir-agent}"
audience="${3:-lir-web}"
minutes="${4:-60}" # signJwt allows at most 12 hours

issuer="lir-demo-idp@${project}.iam.gserviceaccount.com"
now=$(date +%s)
exp=$((now + minutes * 60))

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%d,"exp":%d}' \
  "$issuer" "$customer" "$audience" "$now" "$exp" >"$workdir/claims.json"

gcloud iam service-accounts sign-jwt "$workdir/claims.json" "$workdir/token" \
  --iam-account="$issuer" --project="$project" --quiet
cat "$workdir/token"
echo
