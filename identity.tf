# Customer sign-in (SEC-01). The bank's sign-in is mocked: a service account is the identity
# provider. Google publishes its public keys (JWKS), API Gateway verifies the customer tokens
# it signs, and the team mints demo tokens without downloading any key:
#
#   scripts/issue-demo-token.sh CLI-DEMO-001
#
# Only enforced when var.customer_sign_in is true; a real bank swaps this issuer for its own.

resource "google_service_account" "demo_idp" {
  account_id   = "lir-demo-idp"
  display_name = "Lir demo sign-in (mock identity provider for customer JWTs)"
}

# Team members sign demo customer tokens as the issuer (iam.serviceAccounts.signJwt).
resource "google_service_account_iam_member" "demo_idp_signers" {
  for_each = toset(keys(var.team_members))

  service_account_id = google_service_account.demo_idp.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "user:${each.value}"
}

locals {
  customer_jwt_issuer   = google_service_account.demo_idp.email
  customer_jwt_jwks_uri = "https://www.googleapis.com/service_accounts/v1/jwk/${google_service_account.demo_idp.email}"
}
