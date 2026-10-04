# lir-infra

Terraform for the `lir-agent` GCP project of team Lir (Factored AI & Data Hackathon 2026).
The agent, the evals and the data pipeline live in
[factored-hackathon-2026-lir-agent](https://github.com/Lir-team/factored-hackathon-2026-lir-agent);
infrastructure is kept in its own repository so its changes are reviewed and applied on their own.

## What is managed

| Area | Resources | File |
|---|---|---|
| Resource hierarchy | Folder `lir` in the team organization holding the `lir-agent` project (imported, `deletion_policy = "PREVENT"`) | `organization.tf` |
| Team access | Additive IAM bindings per teammate (`team_members`) | `main.tf` |
| APIs | Every API in `enabled_apis` (never disabled on destroy) | `main.tf`, `variables.tf` |
| Images and builds | Artifact Registry repository `lir`, build service account `lir-build`, build source bucket `<project>-build-source` (objects deleted after 7 days) | `agent.tf`, `build.tf` |
| Operator API | Cloud Run service `lir-agent` behind IAP, runtime account `lir-agent-run`, data lake bucket `<project>-data` mounted read-only at `/mnt/data` | `agent.tf` |
| Secrets | Secret Manager containers only: values are added by hand (see [Secrets](#secrets)) | `agent.tf` |
| Case store | Firestore `(default)` database (native mode, delete protection on) with TTL on `expires_at` of `lir_claims` and `lir_start_tokens` | `firestore.tf` |
| Cases inbox | Bucket `<project>-cases`: the archive of every accepted case (`cases/<case_id>.json`) | `cases.tf` |
| Case flow service | Cloud Run service `lir-agent-cases` (same image, no IAP), runtime account `lir-agent-cases-run` | `cases.tf` |
| Case queue | Topic `lir-cases`, push subscription `lir-cases-push` (signed as `lir-pubsub-push`), dead-letter topic and subscription `lir-cases-dead-letter` | `pubsub.tf` |
| Public gateway | API Gateway `lir-cases` (spec in `openapi/cases.yaml.tftpl`), backend account `lir-gateway`, API key `lir-cases-web` | `gateway.tf` |
| CI deploys | Workload Identity pool `github` with provider `lir-team` (agent repository, `main` only), deploy account `lir-deploy` | `ci.tf` |

The Cloud Run services, the push subscription and the gateway are only created once
`agent_image` is set, so the registry and the secrets can be prepared first. After that,
Terraform ignores the image: new images are deployed with `gcloud run deploy`.

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

## Apply

```bash
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars   # fill in the real values
terraform init -backend-config=backend.hcl
terraform fmt -check -recursive && terraform validate
terraform plan -out=lir.tfplan                  # read it before applying
terraform apply lir.tfplan
```

Add the value of every secret the services read (next section) **before** the apply that
creates the services: a Cloud Run revision that mounts a secret without a version fails
to start. The first apply can run with `agent_image = ""` to create the containers.

`terraform.tfvars` and `backend.hcl` are git-ignored: the repository is public and the
tfvars file holds team emails, the organization id and the billing account.

Notes for the next apply:

- The AWS secrets (`aws-access-key-id`, `aws-secret-access-key`) were never read by the
  agent and are no longer declared: the plan **destroys both containers and their values**.
- Newly enabled APIs can take a minute to propagate. If a resource fails right after its
  API was enabled, run `terraform apply` again.
- If the project already has a Firestore `(default)` database, import it instead of
  creating it: `terraform import google_firestore_database.default "projects/lir-agent/databases/(default)"`.

## Secrets

Terraform creates the containers; nobody's key ever reaches the Terraform state. Set or
rotate a value with:

```bash
printf %s "$VALUE" | gcloud secrets versions add <secret id> --data-file=- --project lir-agent
```

`printf %s` avoids the trailing newline that `echo` would store in the secret.

| Secret id | Env var | Read by | Needed when | How to get the value |
|---|---|---|---|---|
| `openai-api-key` | `LLM_API_KEY`, `OPENAI_API_KEY` | `lir-agent`, `lir-agent-cases` | always | OpenAI dashboard → API keys |
| `openrouter-api-key` | `OPENROUTER_API_KEY` | `lir-agent`, `lir-agent-cases` | `decision_llm_model` starts with `openrouter/` | OpenRouter → Keys |
| `cloudflare-account-id` | `CLOUDFLARE_ACCOUNT_ID` | `lir-agent`, `lir-agent-cases` | `jev_enabled = true` | Cloudflare dashboard → account id |
| `cloudflare-api-token` | `CLOUDFLARE_API_TOKEN` | `lir-agent`, `lir-agent-cases` | `jev_enabled = true` | Cloudflare → API tokens (Workers AI) |
| `telegram-bot-token` | `TELEGRAM_BOT_TOKEN` | `lir-agent-cases` | always | BotFather → `/newbot` or `/token` |
| `telegram-webhook-secret` | `TELEGRAM_WEBHOOK_SECRET` | `lir-agent-cases` | always | Any random string, e.g. `openssl rand -hex 32` (letters, digits, `_` and `-` only) |

`terraform output secrets` lists every container.

## Case flow

`lir-web` files a case, Pub/Sub carries it to the agent and the customer continues on
Telegram (see `docs/architecture/case-flow.md` in the agent repository).

| Route | Through | Auth |
|---|---|---|
| `POST <cases_gateway_url>/v1/cases` | API Gateway → `lir-agent-cases` | API key in `?key=`; CORS for `cors_origins` answered by the service |
| `POST <cases_gateway_url>/channels/telegram` | API Gateway → `lir-agent-cases` | Telegram's `X-Telegram-Bot-Api-Secret-Token`, checked by the agent |
| `POST <cases_service_url>/pubsub/push` | Pub/Sub push subscription `lir-cases-push` | OIDC token of `lir-pubsub-push` for audience `lir-agent-cases-pubsub-push` |

Only `lir-gateway` and `lir-pubsub-push` can invoke the service; it runs with
`REQUIRE_IDENTITY=false`, so the form's `customer_id` is trusted (testers switch customers
freely) and the API key is what stops abuse. A case that fails 5 deliveries goes to
`lir-cases-dead-letter`; read it with
`gcloud pubsub subscriptions pull lir-cases-dead-letter --limit 10 --project lir-agent`.

After the apply that creates the gateway:

1. Read the API key and the gateway URL for `lir-web`:

   ```bash
   terraform output -raw cases_api_key
   terraform output -raw cases_gateway_url
   ```

2. Point the Telegram bot at the gateway (once, and again if the gateway URL or the secret
   changes):

   ```bash
   TOKEN=$(gcloud secrets versions access latest --secret telegram-bot-token --project lir-agent)
   SECRET=$(gcloud secrets versions access latest --secret telegram-webhook-secret --project lir-agent)
   curl -s "https://api.telegram.org/bot$TOKEN/setWebhook" \
     -d url="$(terraform output -raw cases_gateway_url)/channels/telegram" \
     -d secret_token="$SECRET"
   ```

   Set `telegram_bot_username` (without `@`) so the `202` answer carries the start link.

## Deploy flow

Image deploys never need `terraform apply`. On every push to `main` of the agent
repository, GitHub Actions:

1. exchanges its OIDC token for `lir-deploy` through the `github` pool (`google-github-actions/auth`
   with `WIF_PROVIDER` and `DEPLOY_SA`); tokens from other repositories or branches are rejected;
2. builds the image with `gcloud builds submit` as `BUILD_SA`, staging the source in
   `BUILD_BUCKET` and pushing to `<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/<AR_REPO>`;
3. rolls it out with `gcloud run deploy <service> --image ...` to `lir-agent` and
   `lir-agent-cases`. Terraform ignores the image, so the next apply keeps it.

`lir-deploy` can create builds, stream their logs, upload build sources, act as
`lir-build` and both runtime accounts, read images and deploy revisions
(`roles/run.developer` on the two services only). It cannot change IAM.

Set these **repository variables** in GitHub (Settings → Secrets and variables → Actions →
Variables) on the agent repository; none of them is secret:

| Variable | Value |
|---|---|
| `GCP_PROJECT_ID` | `lir-agent` |
| `GCP_REGION` | `us-east1` (`region`) |
| `WIF_PROVIDER` | `terraform output -raw wif_provider` |
| `DEPLOY_SA` | `terraform output -raw deploy_service_account` |
| `AR_REPO` | `lir` (`artifact_repository_id`) |
| `BUILD_SA` | `terraform output -raw build_service_account` |
| `BUILD_BUCKET` | `terraform output -raw build_source_bucket` |

## Organization notes

- The organization allows members from any domain (`iam.allowedPolicyMemberDomains`), so
  teammates' Gmail accounts can be granted roles.
- Service account key creation and upload are disabled by organization policy: nothing
  here uses key files. CI deploys authenticate with Workload Identity Federation.
- The organization disables automatic grants to default service accounts, so every
  workload (builds, Cloud Run) runs as a dedicated account with explicit roles.
- A project inside an organization can move between folders, but not back to having no
  organization without Google support.

## Access model

- Bindings use `google_project_iam_member`, which only adds access: it never removes the
  project owner or roles granted outside Terraform.
- `roles/owner` is rejected by validation; ownership stays with the project creator.
- `roles/editor` lets teammates view and use every resource without managing IAM.
  Narrower roles (for example `roles/run.developer`, `roles/pubsub.editor`,
  `roles/storage.objectAdmin`) can replace it per person in `terraform.tfvars`.
