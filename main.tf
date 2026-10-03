locals {
  # One entry per (member, role) pair, keyed so plans stay stable when the map changes.
  team_bindings = {
    for binding in flatten([
      for email, roles in var.team_members : [
        for role in roles : { email = email, role = role }
      ]
    ]) : "${binding.email}|${binding.role}" => binding
  }
}

resource "google_project_service" "enabled" {
  for_each = var.enabled_apis

  service            = each.value
  disable_on_destroy = false
}

# Additive bindings (google_project_iam_member): never removes access granted elsewhere,
# such as the project owner's.
resource "google_project_iam_member" "team" {
  for_each = local.team_bindings

  project = var.project_id
  role    = each.value.role
  member  = "user:${each.value.email}"

  depends_on = [google_project_service.enabled]
}
