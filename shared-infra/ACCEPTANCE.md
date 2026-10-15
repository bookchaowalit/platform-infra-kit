# Local shared infrastructure acceptance

Stage: **implemented-local**. Correlation: `SHARED-INFRA-2026-10-15`.
This harness does not deploy services, contact live providers, send actual
messages, create charges or certify a production SLA.

## Run

Install the core, seven service packages, and `platform-observability` from the
parent release's explicit wheel bundle or local checkouts. The runner imports
installed packages; it does not discover hub paths or import service databases.
Test dependencies include pytest, httpx, PyJWT crypto, psycopg and uvicorn.

Supply these environment variables explicitly in the test process:

- `PLATFORM_TEST_DSN`: disposable PostgreSQL fixture admin connection, including
  explicit database, user, and an absolute Unix socket directory or literal
  loopback address. The admin needs CREATE DATABASE and CREATE ROLE. Production
  DSNs, hostname discovery, service-file indirection and multi-host lists are
  rejected by the harness. Every ambient `PG*` variable is rejected before any
  connection; only `PLATFORM_PG_BIN` supplies the tool directory. Validated DSNs
  explicitly use `passfile=/dev/null`, including derived fixture connections,
  so default password-file discovery is disabled. Never supply production access.
- `PLATFORM_PG_BIN`: directory containing matching `pg_dump` and `pg_restore`.
  An unpacked local PostgreSQL distribution may also need its library directory
  in `LD_LIBRARY_PATH`; this is supplied by the local test environment.

```bash
python -m shared_infra.acceptance --output /tmp/shared-acceptance-run-1.json
python -m pytest tests/test_shared_stack.py -q
```

The CLI accepts `--operations` (8–1000, default 24) and `--concurrency` (2–16,
default 6). It refuses an existing evidence output path. Missing configuration
fails rather than skipping database checks. Failed CLI evidence contains a
sanitized exception class, never connection strings or exception payloads.
A failure is a nonzero exit; it cannot produce a passed acceptance result.

## What is exercised

The test creates seven fresh disposable databases, each with a different
NOSUPERUSER/NOBYPASSRLS runtime role. Migrations use the fixture admin; runtime
DML and all HTTP requests use the restricted role and verified workspace UUID.
The security audit role receives only SELECT/INSERT on its append-only table.
All resources have unique `accept_*` names and are cleaned after the run.
If the parent restore helper fails after creating a target, it deliberately
leaves that fresh target for inspection; the runner does not remove a database
unless the restore call returned it successfully.

The harness runs nine loopback API processes concurrently: two workflow, two
data, and one each for developer, security, communication, media and payment.
Every app is instrumented with `platform_observability` and an independently
generated, explicitly supplied metrics credential. JWT signing keys, actors,
workspace IDs and business records are synthetic fixtures generated per run.
They are never included in the evidence artifact.

| Flow | Acceptance evidence |
|---|---|
| Workflow across two API replicas | Concurrent identical requests create one job; changed request conflicts; foreign workspace gets 404. |
| Concurrent workflow workers | Two spawned processes claim distinct jobs with verified workspace authorization. |
| Worker termination/restart | A process is terminated after committing its claim. Real database-clock expiry allows replacement, increments attempts and rejects the stale token with HTTP 409. No administrative timestamp rewrite is used. |
| Durable drain | Two fresh worker processes execute an injected pure handler; every loaded job is read back over HTTP as succeeded with its expected result. |
| Data across two API replicas | Two separate client processes increment one counter without lost updates; cache writes and search documents are read through the other replica and remain isolated from a second workspace. |
| Shared quota | Concurrent requests across both API replicas admit exactly seven units; the remaining requests return expected 429 responses. A second workspace retains its independent quota. |
| Feature flags | Stable fixture evaluation and foreign-workspace denial through HTTP. |
| Security metadata/audit | Reference metadata remains isolated; duplicate audit operations resolve to one record. No secret values are resolved or stored. |
| Communication | Durable outbox deduplicates enqueue; an independent worker process marks delivery through an injected no-network adapter. Foreign-workspace reads fail. |
| Media | Upload intents deduplicate, completion checks synthetic object metadata, and foreign-workspace completion/read is denied. Real object storage and byte upload are explicitly outside this fixture. |
| Payment | One-time intents use an injected no-network provider, deduplicate requests, reject changed amounts and deny foreign-workspace reads. No actual charge, billing provider or webhook delivery is claimed. |
| Telemetry | `/metrics` rejects unauthenticated calls, accepts its explicit credential, includes route templates and excludes workspace/job IDs and bearer values. No telemetry exporter endpoint is configured. |
| Backup/restore | Parent `shared_infra.recovery` creates a custom archive, restores into a new database, grants the restricted runtime role and opens a new API process. Both fixture workspaces retain their rows and cross-workspace isolation over HTTP. |

The developer migration namespace is `flags`, matching its owning runtime and
readiness checks. Media/payment use `platform_media` / `platform_payment`;
other namespaces match the service name. The harness applies actual service
migrations through shared-core `MigrationRunner`.

## Reading the evidence

JSON reports actual Python/PostgreSQL/package versions, API/worker process
counts, workload operations/concurrency, admission/recovery outcomes and
per-operation count, errors, error rate, p50/p95 milliseconds, elapsed time and
throughput. Expected quota rejection and deliberate 404/409/401 checks count as
successful acceptance operations. Counter timings come from the independent
client processes; other timings measure complete HTTP round trips. Throughput
is the measured count divided by that operation group's first-to-last interval,
including intentional worker-expiry wait where applicable.

These are bounded local fixture measurements, not production capacity targets.
They do not prove live provider behavior, object durability, cloud networking,
production issuer cutover, billing lifecycle, regional failover, retention or
production backup recovery. Those remain separate release gates. A passed run
has no skipped checks within the declared fixture scope.

The separate generic-launcher HTTP regression uses an actual LOGIN runtime role
with a provisioned connection limit. It proves valid readiness, rejects unlimited
or oversized limits and admin-authenticated SET ROLE sessions, and holds actual
connections until PostgreSQL denies an additional login. Source acceptance app
fixtures use direct service factories and do not pretend those SET ROLE test
connections prove the production launcher connection ceiling.
