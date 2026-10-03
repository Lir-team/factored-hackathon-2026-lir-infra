# lir-infra

Terraform for the `lir-agent` GCP project of team Lir (Factored AI & Data Hackathon 2026).
The agent, the evals and the data pipeline live in
[factored-hackathon-2026-lir-agent](https://github.com/Lir-team/factored-hackathon-2026-lir-agent);
infrastructure is kept in its own repository so its changes are reviewed and applied on their own.

Currently managed:

- **Resource hierarchy:** folder `lir` in the team organization, holding the `lir-agent`
  project (imported, with `deletion_policy = "PREVENT"`).
- **Team access:** additive IAM bindings per teammate (`team_members`).
- **Base APIs:** Resource Manager, IAM, Organization Policy, Service Usage.

The Cloud Run service, Pub/Sub, Cloud Storage, Firestore, Secret Manager and BigQuery
resources from the architecture diagram will be added here as they are deployed.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.6
- `gcloud` signed in with an account that can manage IAM on the project
- Application Default Credentials for Terraform:

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project lir-agent
```

## First time only

The state lives in a versioned GCS bucket so the whole team shares it:

```bash
bash scripts/bootstrap-state.sh lir-agent
```

Creating the folder needs folder permissions on the organization, which organization
admins do not have by default. Grant them once to the account that runs Terraform:

```bash
gcloud organizations add-iam-policy-binding <organization-id> \
  --member="user:<admin-account>" --role="roles/resourcemanager.folderAdmin" --condition=None
```

## Usage

```bash
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars   # fill in the real team emails
terraform init -backend-config=backend.hcl
terraform fmt -check && terraform validate
terraform plan -out=team.tfplan
terraform apply team.tfplan
```

`terraform.tfvars` and `backend.hcl` are git-ignored: the repository is public and the
tfvars file holds team emails, the organization id and the billing account.

## Organization notes

- The organization allows members from any domain (`iam.allowedPolicyMemberDomains`), so
  teammates' Gmail accounts can be granted roles.
- Service account key creation and upload are disabled by organization policy: CI and
  deploys authenticate with Workload Identity Federation, never with key files.
- A project inside an organization can move between folders, but not back to having no
  organization without Google support.

## Access model

- Bindings use `google_project_iam_member`, which only adds access: it never removes the
  project owner or roles granted outside Terraform.
- `roles/owner` is rejected by validation; ownership stays with the project creator.
- `roles/editor` lets teammates view and use every resource without managing IAM.
  Narrower roles (for example `roles/run.developer`, `roles/pubsub.editor`,
  `roles/storage.objectAdmin`) can replace it per person in `terraform.tfvars`.
