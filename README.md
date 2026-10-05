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
| Operator API | Runtime account `lir-agent-run`, IAP access to the `lir-agent` service (deployed by GitHub Actions), data lake bucket `<project>-data` | `agent.tf` |
| Secrets | Secret Manager containers only: values are added by hand (see [Secrets](#secrets)) | `agent.tf` |
| Case store | Firestore `(default)` database (native mode, delete protection on) with TTL on `expires_at` of `lir_claims` and `lir_start_tokens` | `firestore.tf` |
| Data pipeline | Runtime account `lir-pipeline-run` of the `lir-pipeline` job (created by hand), only writer of the data bucket | `pipeline.tf` |
| Cases inbox | Bucket `<project>-cases`: the archive of every accepted case (`cases/<case_id>.json`) | `cases.tf` |
| Case flow service | Runtime account `lir-agent-cases-run`, `run.invoker` for the gateway and Pub/Sub on `lir-agent-cases` (deployed by GitHub Actions) | `cases.tf` |
| Case queue | Topic `lir-cases`, push subscription `lir-cases-push` (signed as `lir-pubsub-push`), dead-letter topic and subscription `lir-cases-dead-letter` | `pubsub.tf` |
| Public gateway | API Gateway `lir-cases` (spec in `openapi/cases.yaml.tftpl`), backend account `lir-gateway`, API key `lir-cases-web` | `gateway.tf` |
| CI deploys | Workload Identity pool `github` with provider `lir-team` (agent repository, `main` only), deploy account `lir-deploy` | `ci.tf` |

Cloud Run itself (the two services and the pipeline job) is **not** managed here: see
[Cloud Run is deployed outside Terraform](#cloud-run-is-deployed-outside-terraform).

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.7 (`removed` blocks)
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

Add the value of every secret the services read (next section) **before** GitHub Actions
deploys them: a Cloud Run revision that mounts a secret without a version fails to start.

`terraform.tfvars` and `backend.hcl` are git-ignored: the repository is public and the
tfvars file holds team emails, the organization id and the billing account.

Notes for the next apply:

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
| `aws-access-key-id` | `AWS_ACCESS_KEY_ID` | `lir-pipeline` job | data pipeline | Data dictionary of the organizers (never commit it) |
| `aws-secret-access-key` | `AWS_SECRET_ACCESS_KEY` | `lir-pipeline` job | data pipeline | Data dictionary of the organizers (never commit it) |
| `telegram-bot-token` | `TELEGRAM_BOT_TOKEN` | `lir-agent-cases` | `telegram_enabled = true` | BotFather → `/newbot` or `/token` |
| `telegram-webhook-secret` | `TELEGRAM_WEBHOOK_SECRET` | `lir-agent-cases` | `telegram_enabled = true` | Any random string, e.g. `openssl rand -hex 32` (letters, digits, `_` and `-` only) |

`terraform output secrets` lists every container.

## Customer sign-in (SEC-01) and step-up approvals (SEC-04)

The bank's sign-in is mocked with a service account as identity provider (`identity.tf`):
Google publishes its public keys, API Gateway verifies the customer JWTs it signs, and team
members mint demo tokens through the IAM API, without downloading any key:

```bash
scripts/issue-demo-token.sh CLI-DEMO-001        # prints a JWT for that customer (60 min)
```

IAM `signJwt` caps a token at 12 hours, so the deployed lir-web does not carry one: with
`demo_sign_in_customer_id` set, the case flow service answers `POST /v1/demo/sign-in` (API key
only) with a fresh short-lived token for that customer, and lir-web asks for it on load
(`LIR_SIGN_IN_ENDPOINT`).

Set `customer_sign_in = true` to enforce it:

| Route | Without sign-in | With `customer_sign_in` |
|---|---|---|
| `POST /v1/cases` | API key; the payload's `customer_id` is trusted | API key **and** the customer's JWT; the customer comes from the token (`REQUIRE_IDENTITY=true`) |
| `GET /v1/approvals/{id}`, `POST .../decision` | the single-use link token | the link token **and** the JWT of that same customer (`APPROVAL_REQUIRES_SIGN_IN=true`); Telegram only links to the card |

Paste the token into lir-web's `js/config.js` as `authToken`. Set `approval_link_template`
to the `https` URL of lir-web's `aprobar.html` so Telegram can link to the card.

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

2. Turn on Telegram: add a version to `telegram-bot-token` and `telegram-webhook-secret`, set
   `telegram_enabled = true` and apply. Then point the bot at the gateway (once, and again
   if the gateway URL or the secret changes):

   ```bash
   TOKEN=$(gcloud secrets versions access latest --secret telegram-bot-token --project lir-agent)
   SECRET=$(gcloud secrets versions access latest --secret telegram-webhook-secret --project lir-agent)
   curl -s "https://api.telegram.org/bot$TOKEN/setWebhook" \
     -d url="$(terraform output -raw cases_gateway_url)/channels/telegram" \
     -d secret_token="$SECRET"
   ```

   Set `telegram_bot_username` (without `@`) so the `202` answer carries the start link.

3. Optional, voice notes: set `speech_to_text_enabled = true` and apply. It grants
   `roles/speech.client` to `cases_service_account` and adds `SPEECH_TO_TEXT=google` to
   `cases_env` (`speech.googleapis.com` is always enabled). The deploy workflow only changes
   the image, so set the variable on the running service once:

   ```bash
   gcloud run services update lir-agent-cases --region us-east1 --project lir-agent \
     --update-env-vars SPEECH_TO_TEXT=google
   ```

   Voice notes up to 60 s are transcribed (`es-US`, `pt-BR`) and answered like typed text.

## Cloud Run is deployed outside Terraform

Since 2026-10-04 Terraform no longer owns `lir-agent`, `lir-agent-cases` (GitHub Actions
creates and deploys them) or the `lir-pipeline` job (created by hand). `removed` blocks with
`destroy = false` drop them, and the old service-scoped `run.developer` bindings of
`lir-deploy`, from the state **without destroying them**. Terraform keeps everything around
them: runtime accounts, secrets, buckets, registry, Pub/Sub, gateway and the IAM.

Apply in two phases:

1. **First apply** with `agent_service_deployed = false` and `cases_service_url = ""`:
   accounts, registry, secrets, buckets, topics and CI identity. Add the secret values.
2. **Deploy** both services with the GitHub Actions workflow (settings below) and create the
   pipeline job by hand.
3. **Second apply** with `agent_service_deployed = true` and `cases_service_url` set to the
   cases service URL: service-scoped IAP and `run.invoker` bindings, the API Gateway and the
   Pub/Sub push subscription. Leaving `cases_service_url` empty later would destroy them.

### Service settings the workflow must carry

Read the values with `terraform output` (`-json` for maps). Both services:

| Setting | `lir-agent` | `lir-agent-cases` |
|---|---|---|
| Region | `region` (`us-east1`) | same |
| Image | `<image_registry>/lir-agent:<tag>` | same image |
| `--service-account` | `agent_service_account` | `cases_service_account` |
| `--set-env-vars` | `agent_env` | `cases_env` (adds case flow, Pub/Sub, Firestore, CORS) |
| `--set-secrets` (`NAME=SECRET:latest`) | `agent_secret_env` | `cases_secret_env` |
| Auth | `--iap` (IAP on Cloud Run, `gcloud beta run deploy`), `--no-allow-unauthenticated` | `--no-allow-unauthenticated`, `--add-custom-audiences <cases_push_audience>` |
| Ingress | `--ingress all` | `--ingress all` |
| Scaling | `--min-instances 0 --max-instances 1` (sessions in memory) | same |
| Resources | `--cpu 1 --memory 1Gi --port 8080`, `--execution-environment gen2` | same |
| Data lake | `--add-volume name=data,type=cloud-storage,bucket=<data_bucket>,readonly=true --add-volume-mount volume=data,mount-path=/mnt/data` | same |
| Startup probe | HTTP `GET /health`, `periodSeconds=10`, `failureThreshold=12` (the data bucket mount can take over 30 s) | same |

`lir-deploy` has `roles/run.developer` on the project (it must create the services) but
cannot set IAM: never pass `--allow-unauthenticated`. Invokers and IAP users come from
the second apply.

### Pipeline job (created by hand)

```bash
gcloud run jobs create lir-pipeline --region us-east1 \
  --image <image_registry>/lir-pipeline:<tag> \
  --service-account "$(terraform output -raw pipeline_service_account)" \
  --tasks 1 --max-retries 1 --task-timeout 3600s --cpu 8 --memory 32Gi \
  --execution-environment gen2 \
  --set-env-vars LAKE_DIR=/mnt/lake,AWS_DEFAULT_REGION=us-east-2 \
  --set-secrets AWS_ACCESS_KEY_ID=aws-access-key-id:latest,AWS_SECRET_ACCESS_KEY=aws-secret-access-key:latest \
  --add-volume name=lake,type=cloud-storage,bucket="$(terraform output -raw data_bucket)" \
  --add-volume-mount volume=lake,mount-path=/mnt/lake
```

8 vCPU / 32Gi: the in-memory filesystem holds raw/ and the outputs; 8Gi was killed (OOM)
staging transactions. Image built with `data/cloudbuild.yaml` of the agent repository.

## Deploy flow

Image deploys never need `terraform apply`. On every push to `main` of the agent
repository, GitHub Actions:

1. exchanges its OIDC token for `lir-deploy` through the `github` pool (`google-github-actions/auth`
   with `WIF_PROVIDER` and `DEPLOY_SA`); tokens from other repositories or branches are rejected;
2. builds the image with `gcloud builds submit` as `BUILD_SA`, staging the source in
   `BUILD_BUCKET` and pushing to `<GCP_REGION>-docker.pkg.dev/<GCP_PROJECT_ID>/<AR_REPO>`;
3. deploys it with `gcloud run deploy <service> --image ...` to `lir-agent` and
   `lir-agent-cases`, with the settings above (Terraform does not manage the services).

`lir-deploy` can create builds, stream their logs, upload build sources, act as
`lir-build` and both runtime accounts, read images and create and deploy services
(`roles/run.developer` on the project). It cannot change IAM.

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
