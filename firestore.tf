# Case store of the agent (CASE_STORE=firestore): receipts, idempotency claims, start
# tokens, chat links, case conversations and replies waiting for a chat.

resource "google_firestore_database" "default" {
  # The client libraries use "(default)" unless FIRESTORE_DATABASE says otherwise.
  name = "(default)"
  # us-east1 is a regional Firestore location, so the store sits next to the services.
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  # Case state must survive a mistaken destroy: Terraform only forgets the database, and
  # Google refuses to delete it while delete protection is on.
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
  deletion_policy         = "ABANDON"

  depends_on = [google_project_service.enabled]
}

locals {
  # Collections whose documents carry an `expires_at` timestamp. Firestore deletes them
  # some time (usually within a day) after it passes; the agent already ignores expired
  # documents, so TTL only keeps the store from growing forever.
  ttl_collections = toset(["claims", "start_tokens"])
}

resource "google_firestore_field" "expires_at_ttl" {
  for_each = local.ttl_collections

  database   = google_firestore_database.default.name
  collection = "${var.firestore_collection_prefix}${each.value}"
  field      = "expires_at"

  ttl_config {}

  # An empty block exempts the field from single-field indexes: documents are read by id,
  # never queried by expiry, and indexing a TTL timestamp only adds write hotspots.
  index_config {}
}
