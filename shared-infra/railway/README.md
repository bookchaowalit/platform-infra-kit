# Bounded Railway foundation test

This is an operator-driven synthetic staging test, not a production deployment or
cloud success claim. It makes no Railway API calls. The operator owns deployment,
actual replica changes/restarts, the shared clock and teardown of **only newly
created run resources**. Local tests use disposable PostgreSQL 18; the hosted image
contains PostgreSQL 16 clients for the planned Railway PostgreSQL 16 server.

The approved project is `74e1dc2e-a00c-4ce7-931d-a8f15039a1a8` and environment is
`d6178822-ac8b-4cb3-82f6-642c14163fa2`. The four HTTP destinations are exactly
`http://workflow.railway.internal:8080`, `http://data.railway.internal:8080`,
`http://developer.railway.internal:8080`, `http://security.railway.internal:8080`.
The only database host accepted by the CLI is
`staging-postgres.railway.internal:5432`. There is no CLI local-host override,
service-file resolution, ambient `PG*` configuration or credential discovery.
Returned DSNs explicitly disable `.pgpass`. Internal Python test seams are only
for disposable local fixtures and do not constitute cloud evidence.

## Hosted artifact

Configure Railway Dockerfile path `shared-infra/railway/Dockerfile`, context repo
root and the **nonsecret** build argument `INFRA_SOURCE_SHA=<reviewed public
40-character infrastructure commit>`. Never pass a DSN, key or password as a
build argument. That argument must include this runner; the old r4 infrastructure
SHA does not. The other nine public repositories use the exact r4 revisions in
[sources.json](sources.json). The same file locks every third-party wheel by
version, filename and SHA256, plus pinned setuptools/wheel build tools.

All source is fetched from exact public GitHub commit archives into fresh private
folders; archive links, traversal, `.gitmodules` and special files are rejected.
No local ignored `build/lib`, editable checkout or untracked source enters wheels.
Builds fix SOURCE_DATE_EPOCH to1980-01-01 and disable ambient pip configuration/cache.
The final image installs the exact regular wheel set offline with
`--only-binary=:all:` and checks all ten package imports and `pip check`.
Official `python:3.12-slim-bookworm` and `postgres:16-bookworm` **amd64 manifests**
are pinned in the Dockerfile. Digests were obtained from public Docker Hub
[Python tag metadata](https://hub.docker.com/v2/repositories/library/python/tags/3.12-slim-bookworm)
and [Postgres tag metadata](https://hub.docker.com/v2/repositories/library/postgres/tags/16-bookworm)
on 2026-10-15; tags are explanatory, digest selects content.
The shared Debian bookworm libraries and PostgreSQL 16 tools come from that pinned
Postgres image, without mutable apt resolution. Runtime is UID/GID65532.

`.github/workflows/shared-runtime.yml` builds the hosted Dockerfile using the
actual `GITHUB_SHA`, then runs imports/Python 3.12 and pg_dump/pg_restore 16 version
smokes with networking disabled. No registry publication occurs. Local public
source/wheel build verification and CI configuration are distinct from an actual
hosted Docker CI result, and from cloud runtime proof; record each separately.

## Shared variables and fixed output

Every process requires explicit `RAILWAY_PROJECT_ID`, `RAILWAY_ENVIRONMENT_ID`,
`STAGING_RUN_ID` (canonical UUID), `STAGING_STARTED_AT`, `STAGING_DEADLINE` (UTC
RFC3339, e.g. `2026-10-15T12:00:00Z`). Use **one unchanged start and deadline for
all processes**, starting the clock before the first runtime. The initial test
window is 20 minutes; deadline must be after now, at most 45 minutes after that same
start. Do not renew timestamps between modes. The runner bounds HTTP timeouts,
checks the remaining budget, gracefully stops serving before expiry, and installs
a hard process alarm even for blocked worker/backup calls. Every Railway service
must use deployment `restartPolicyType: NEVER`, including the one-shot operator;
otherwise PaaS restarts could defeat the intended shutdown. A deadline exits 0 and
emits `deadline-reached`; it is not evidence that an incomplete test passed.

Optional `STAGING_API_URLS` JSON must equal the four fixed URLs exactly. Each
command is `python -m shared_infra.railway_staging <mode>`, set directly as
Railway startCommand, no SSH required. Output is bounded JSON lines with
`schema=solo-empire.railway-staging.v1`, `run`, `status`, fixed counts/measurements
and synthetic IDs. Failure emits only `status=failed,error=staging_operation_failed`
and exit 1. No exception text, JWTs, DSNs, passwords, private keys or response bodies
are emitted. Unknown CLI arguments are redacted too. Retain parent/operator
checkpoints with actual Railway deployment/replica/restart IDs as cloud evidence.

Names are deterministic, using the 32 hex UUID digits:

- Database `stg_<hex>_<workflow|data|developer|security>`; restore target
  `stg_<hex>_restored`.
- Role `stg_<hex>_<service>_api` (LOGIN cap 4); worker
  `stg_<hex>_workflow_worker` (LOGIN cap 2).
- Workspaces are Python `uuid5(UUID(STAGING_RUN_ID),'workspace-a')` and
  `uuid5(UUID(STAGING_RUN_ID),'workspace-b')`.
- JWT issuer `https://railway-staging.invalid/<canonical run UUID>`, audience
  `shared-infrastructure-staging`; RS256, `sub` UUID, `ws` UUID, `scope` **string**,
  `iat`, `exp` no later than shared deadline, unique `jti`. No production issuer.

## Operator sequence

1. Generate fresh synthetic RSA signing keys and five fresh random role passwords
   outside public source. Record the unchanged shared timestamps/run UUID.
2. Bootstrap one shot with **only operator database authority**:
   `STAGING_ADMIN_DSN` explicitly selecting the fresh private staging PostgreSQL
   host, port, admin database, admin user and password;
   `STAGING_ROLE_PASSWORDS` JSON exact keys `workflow_api`, `data_api`,
   `developer_api`, `security_api`, `workflow_worker` (24..200 printable ASCII
   characters per value). Run `bootstrap`. It first refuses any existing run
   database/role (including restore target), then creates new databases/roles,
   applies namespaces `workflow/data/flags/security`, revokes PUBLIC database and
   schema grants and grants only service operations plus migration-history SELECT.
   Worker cannot INSERT workflow_jobs. Security audit has SELECT/INSERT only.
   All tenant tables retain FORCE RLS; runtime accounts own no tables and cannot
   create roles/databases, bypass RLS or use schema CREATE. Partial failures leave
   only newly named resources for operator inspection; retries refuse collisions.
3. Give each API only its run-derived `DATABASE_URL` with its actual LOGIN
   account, `PLATFORM_SERVICE`, `DATABASE_POOL_MAX=2`,
   `DATABASE_CONNECTION_CEILING=4`, `JWT_PUBLIC_KEY`, `JWT_ISSUER`, `JWT_AUDIENCE`,
   `PORT=8080` and shared guard variables. Do **not** give APIs the operator DSN,
   password map, signing key or JWKS URL. Run `serve`. It uses the reviewed generic
   app, migration/RLS/effective-grant and LOGIN-cap readiness checks and a dual-stack
   IPv6/IPv4 listener. No startup migrations or provider fixtures run. Each API role
   cap 4 bounds database sessions even during overlapping terminating replicas.
4. Give the single worker its separate `DATABASE_URL`, public JWT authority and
   `WORKFLOW_WORKER_AUTHORIZATION` JSON `{"a":"Bearer <token-a>","b":"Bearer <token-b>"}`.
   The operator mints both tokens with only `jobs:work`, matching their explicit
   run-derived workspace and shared expiry. Run `worker`. Tokens are verified on
   every poll; workspace/scope mismatch fails closed. The worker checks an actual
   nonprivileged LOGIN role with cap<=2, uses pool 2, and polls only queue `staging`
   in those two authorized workspaces. Only `health.noop` and `staging.restart`
   with the exact synthetic run payload are supported; no URLs/commands/handlers
   are accepted from callers. No signing key or admin DSN enters the worker.
5. Run operator `probe` with only `STAGING_JWT_PRIVATE_KEY`, shared guard variables
   and `STAGING_PHASE=baseline`, without **any** database credentials. Baseline
   submits 100 jobs; scaled submits 1000. After baseline, change actual Railway
   replicas and run scaled. Scale only two APIs simultaneously to stay within the
   owner's aggregate resource budget; do not count a loopback process as a cloud
   replica. The probe uses the existing private service addresses; parent must
   record actual replica configuration. Each phase also admits eight identical
   requests as one job, proves changed-body409, reclaims a one-second lease on a
   dedicated synthetic queue and proves stale acknowledgment409 plus idempotent
   successful completion. It drains jobs, concurrently increments shared state,
   admits exactly 7 reservations out of 32, exercises flags/audit idempotency and
   tenant isolation, then performs 12 post-traffic readiness checks. JSON includes
   measured count/errors/p50/p95/throughput, scoped only to this staging run.
6. `seed-restart` emits `restart_job` and `other_workspace_job`; copy those synthetic
   IDs into `STAGING_RESTART_JOB_ID` and `STAGING_OTHER_JOB_ID` on the HTTP-only
   operator. Wait for worker checkpoint `restart-held` (attempt 1). Actually restart
   that Railway worker. The first attempt deliberately receives no acknowledgment;
   the replacement reclaims after its 10-second lease and completes attempt 2.
   Run `verify-restart`; it requires attempt 2, completion of both workspace jobs,
   foreign-workspace404 and repeated ready checks. Do not run competing workers
   while intentionally holding this restart checkpoint.
7. Drain/stop worker and workflow traffic. One-shot `backup-restore` receives only
   the operator admin DSN, uses `/usr/lib/postgresql/16/bin` and writes a private
   temporary custom-format dump, restoring to the **new** `_restored` database.
   Existing target is refused; no `--clean`, DROP or overwrite is used. Restore
   grants only workflow API access, no worker CONNECT. Remove admin authority from
   subsequent probe. Repoint the workflow API's existing restricted LOGIN DSN to
   that new database, then run `verify-restored` with both original checkpoint IDs.
   This verification is HTTP read-only and never recreates missing rows. The
   operator must record the actual drain, repoint and deployment IDs.
8. Stop test processes before the unchanged deadline, then tear down only newly
   created synthetic Railway resources and run-derived resources as authorized.
   This module does not perform provider teardown, spend money or manage existing
   service resources. Parent controls approved memory/CPU and elapsed budgets.

A successful rerun of the same phase intentionally conflicts with existing flags,
counters and leases; use the next phase or a fresh explicitly authorized run UUID,
not a renewed clock or destructive reset. Main's independent review and hosted
CI must pass before deployment; no cloud success is claimed by this repository.
