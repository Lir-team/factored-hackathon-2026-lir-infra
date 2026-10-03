# Places the project under the team organization, inside its own folder.
#
# The project already exists, so it is imported instead of created. Its id, name and
# billing account are pinned to the current values: the only intended change is the parent.

resource "google_folder" "team" {
  display_name        = var.folder_display_name
  parent              = "organizations/${var.organization_id}"
  deletion_protection = true
}

import {
  to = google_project.this
  id = var.project_id
}

resource "google_project" "this" {
  project_id      = var.project_id
  name            = var.project_name
  folder_id       = google_folder.team.folder_id
  billing_account = var.billing_account

  # Never delete the project from Terraform; never create the default VPC.
  deletion_policy     = "PREVENT"
  auto_create_network = false

  lifecycle {
    # The default network setting only applies at creation time.
    ignore_changes = [auto_create_network]
  }
}
