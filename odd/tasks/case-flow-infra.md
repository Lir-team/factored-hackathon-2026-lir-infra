# Case flow infrastructure

Locator: `odd/tasks/case-flow-infra.md` · Engram mirror: `odd/case-flow-infra/tasks`
Delivery: `auto-chain`, `stacked-to-main` · Status: in progress (T4; T1-T3 written, not applied)

## Objective

Provision on GCP everything the agent's case flow needs (`POST /v1/cases` →
Pub/Sub → agent → Telegram, state in Firestore), plus a GitHub → Cloud Build →
Artifact Registry → Cloud Run deploy flow, without touching the working
operator service.

## Decisions (2026-10-04, with the user)

- **Two Cloud Run services, same image.** `lir-agent` (existing, operator API) keeps
  IAP and `REQUIRE_IDENTITY=true`; it is NOT renamed (a rename recreates it).
  New `lir-agent-cases`: no IAP, ingress all, invokers only the API Gateway SA and
  the Pub/Sub push SA.
- **Direct publish stays.** The API archives the case in the bucket and publishes to
  Pub/Sub itself (ordering key = customer). No GCS `OBJECT_FINALIZE` notification.
- **No customer auth for now.** `lir-agent-cases` runs `REQUIRE_IDENTITY=false` and
  trusts the payload's `customer_id` so testers can switch customers fast. The
  Gateway requires an API key on `/v1/cases` to stop abuse.
- **lir-web is not deployed.** It runs on `http://localhost:5500` and calls the
  Gateway: CORS passes through (`allowCors`) and the service sets `CORS_ORIGINS`.
- **Secrets are easy to find.** Terraform creates the containers; values are added by
  hand; the README lists every secret, who reads it and the command to set it.
- **Deploys don't need `terraform apply`.** Terraform owns service config and ignores
  the image; CI deploys new images with `gcloud run deploy`.
- `terraform apply` is run only after the user approves.

## Tasks

- [x] **T1 Base** (`feat/case-flow-base`): enable APIs (pubsub, firestore, apigateway,
  servicemanagement, servicecontrol, sts, iamcredentials); Firestore native DB +
  TTL policy on start tokens / claims `expires_at`; cases inbox bucket; secrets
  `telegram-bot-token`, `telegram-webhook-secret`; remove unused AWS secrets;
  README rewrite with resource inventory and secrets table.
- [x] **T2 Cases service** (`feat/case-flow-service`, on T1): `lir-agent-cases` Cloud Run
  with its SA and least-privilege roles (bucket object create, topic publish,
  Firestore user, secret access); case-flow env vars; topic `lir-cases` + push
  subscription (OIDC SA, audience, 120s ack, ordering, retry backoff, dead-letter
  topic after 5 attempts with the Pub/Sub service agent grants); API Gateway
  (OpenAPI spec: `/v1/cases` with API key + CORS, `/channels/telegram` no auth,
  backend auth to the service) and an API key restricted to the gateway service.
- [x] **T3 Deploy flow** (`feat/ci-deploy`, on T2): Workload Identity pool + GitHub
  provider restricted to `Lir-team/factored-hackathon-2026-lir-agent`; deploy SA
  with Cloud Build submit, Artifact Registry write, Run developer on both
  services, `actAs` on runtime SAs; outputs for the workflow.
- [ ] **T4 Agent repo workflow** (agent repo, branch `ci/deploy-workflow`):
  GitHub Actions on push to `main`: WIF auth → `gcloud builds submit` →
  `gcloud run deploy` both services with the new image.
- [ ] **T5 lir-web** (lir-web repo): fix `docs/case-contract.md` (direct publish, not
  bucket notification); `config.js` reads the Gateway URL and key from an
  untracked local override.

## Checks

- `terraform fmt -check -recursive`, `terraform init -backend=false && terraform validate`,
  `tflint` per task. No `apply` without approval.

## Route

- T1-T3: one writer in lir-infra (several non-trivial files). T4, T5: one writer
  each in their repo.

## Progress

- **T1 done** (`feat/case-flow-base`, work commit `240ced1`, route: delegated writer).
  Added `firestore.tf` (`(default)` native DB in `var.region`, delete protection on,
  `deletion_policy = ABANDON`; TTL + index exemption on `expires_at` of `lir_claims` and
  `lir_start_tokens`), `cases.tf` (`<project>-cases`, uniform access, PAP enforced, no
  versioning, optional `cases_retention_days` lifecycle), Telegram secret containers, the
  seven APIs, outputs `cases_bucket` / `firestore_database`, README rewrite (inventory,
  apply steps, secrets table). Checks observed: `terraform fmt -check -recursive` ok,
  `terraform init -backend=false` ok, `terraform validate` ok, `tflint` ok (no findings).
  - Apply impact: removing `aws-access-key-id` / `aws-secret-access-key` destroys both
    containers and their values.
  - Assumption: no Firestore `(default)` database exists yet; README gives the import
    command if it does.
  - `.terraform.lock.hcl` gained the linux `h1:` hashes written by `terraform init`.
- **T2 done** (`feat/case-flow-service`, work commit `2ec4774`, route: delegated writer).
  `cases.tf` (SA `lir-agent-cases-run`, service `lir-agent-cases`, invokers), `pubsub.tf`
  (topics, push + dead-letter subscriptions, `lir-pubsub-push`, service agent grants),
  `gateway.tf` + `openapi/cases.yaml.tftpl` (API, config, gateway, `lir-gateway`, managed
  service enablement, API key `lir-cases-web`), outputs, README case-flow section.
  Checks observed: `terraform fmt -check -recursive` ok, `terraform init -backend=false`
  ok, `terraform validate` ok, `tflint` ok (no findings). 569 added lines: above the
  ~400 heuristic because service, queue and gateway only work together.
  - Push audience: fixed string `lir-agent-cases-pubsub-push`, listed in the service's
    `custom_audiences` (Cloud Run accepts it) and passed as `PUBSUB_PUSH_AUDIENCE`
    (the agent's `verify_oauth2_token` checks `aud` equals it). Avoids the service
    referencing its own URL.
  - Inbox grant is `roles/storage.objectUser` on the cases bucket, not `objectCreator`:
    a retry after a failed publish rewrites `cases/<case_id>.json`, and replacing an
    object needs `storage.objects.delete`.
  - Gateway CORS: `allowCors: true` plus an explicit `OPTIONS /v1/cases` without
    security; the service answers it from `CORS_ORIGINS`. API key only on
    `POST /v1/cases` (`?key=`); `/channels/telegram` open at the gateway, checked by the
    agent's secret token. Backend deadline 60 s.
  - Both services ignore `image`, `template.revision`, `client`, `client_version`
    (in-place change only, no replacement of `lir-agent`).
  - Assumption: `FIRESTORE_DATABASE` / `FIRESTORE_COLLECTION_PREFIX` are set explicitly
    from Terraform so the TTL collections and the app always agree.
- **T3 done** (`feat/ci-deploy`, work commit `8799fbb`, route: delegated writer).
  `ci.tf`: pool `github`, provider `lir-team` (condition: repository
  `Lir-team/factored-hackathon-2026-lir-agent` and ref `refs/heads/main`, both variables),
  `lir-deploy` with `workloadIdentityUser` for the repository principalSet; project roles
  `cloudbuild.builds.editor`, `serviceusage.serviceUsageConsumer`, `logging.viewer`;
  `objectCreator` + `legacyBucketReader` on the build source bucket; `serviceAccountUser`
  on `lir-build`, `lir-agent-run`, `lir-agent-cases-run`; `artifactregistry.reader` on
  the repository; `run.developer` on both services. Outputs `wif_provider`,
  `deploy_service_account`; README deploy flow + GitHub repository variables.
  Checks observed: `terraform fmt -check -recursive` ok, `terraform init -backend=false`
  ok, `terraform validate` ok, `tflint` ok (no findings).
  - Assumption: `serviceUsageConsumer` and `logging.viewer` are needed because
    `gcloud builds submit` uses the project's APIs and streams logs of a build that logs to
    Cloud Logging only; drop `logging.viewer` if the workflow passes `--suppress-logs`.
  - Note: a deleted Workload Identity pool id stays reserved for 30 days.
