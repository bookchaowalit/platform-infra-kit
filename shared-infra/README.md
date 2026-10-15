# Shared infrastructure reference deployment

Status: implemented-local. Production activation requires reviewed service
artifacts, environment configuration and an explicit release decision.

Use [the release and rollback runbook](RELEASE.md) for the portable wheel
bundle, instrumented launcher, deployment rendering and workspace workers.
[Acceptance](ACCEPTANCE.md) supplies a repeatable real multi-process HTTP and
restore drill with local measurements.

The owning service repositories install `platform-backend-core` and keep their
own database migrations and runtime roles. This toolkit never imports the hub
or reads local credential files. A production service must use a non-superuser,
non-BYPASSRLS role with the exact table grants required by its API. Migration
credentials are separate and are not injected into the serving process.

## Release checks

`python -m shared_infra check-release release.yaml` checks immutable image
digests, bounded replicas/pools/memory/timeouts and the total API plus worker
connection allocation. `required_env` lists variable names only. No credential
values belong in a release file. Each service owns a Dockerfile and staged
Railway manifest; build and migration commands remain explicit, not API startup
side effects. Replica counts can increase only within the database allocation.

The release plan is an operator artifact with `version: 1`, explicit
`stage: staged|production`, `database_connection_budget` and a `services` list.
Each service requires `name`, an actual `image@sha256:<digest>`, `replicas`,
`pool_max`, `workers`, `worker_pool_max`, `memory_mb` and
`request_timeout_seconds`. Optional `max_replicas` is included at its maximum
in the database allocation and enables the generated API autoscaler.
An unbuilt image is not a release candidate; this
repository does not ship invented image digests.

## Backup and restore

Use PostgreSQL client tools matching the server major version. Connections are
supplied by an explicit environment variable; the CLI accepts its name, not a
credential value on the command line. libpq receives individual variables and
automatic `.pgpass` discovery is disabled. Provider credential files are not read.

```bash
python -m shared_infra backup --dsn-env BACKUP_DATABASE_URL \
  --output /private/backups/snapshot.dump --pg-bin /usr/lib/postgresql/18/bin
python -m shared_infra restore --dsn-env RESTORE_ADMIN_DATABASE_URL \
  --archive /private/backups/snapshot.dump --target restore_candidate \
  --confirm-new-database restore_candidate --pg-bin /usr/lib/postgresql/18/bin
```

Archives are published atomically with mode 0600; an existing backup is never
replaced. Restore refuses existing databases, uses no `--clean`/drop option,
and performs restoration in one transaction. A failed restore leaves its newly
created target for inspection. Backup files require encrypted storage and an
environment-specific retention policy before production use. Object-store
bytes need their own versioning/replication policy; restoring database metadata
alone does not restore file bytes.

## Verification environment

```bash
python -m pip install pytest psycopg[binary] PyYAML
# Install platform-backend-core from the reviewed wheel/checkout for fixtures.
PLATFORM_TEST_DSN='<explicit disposable administrator connection>' \
PLATFORM_PG_BIN=/usr/lib/postgresql/18/bin \
python -m pytest tests/test_shared_infra.py
```

Tests create uniquely named databases and nonprivileged runtime roles. They
exercise real pg_dump/pg_restore, preserve synthetic data through a restore,
and prove that an existing database or backup is not overwritten. Database
tests skip explicitly when their disposable configuration is absent; such a run
is partial verification and cannot satisfy the release gate.
