# Shared infrastructure release and rollback

Stage: **implemented-local**. No production service was changed. A local wheel
bundle and an observed HTTP acceptance run are inputs to the staging release;
they are not a substitute for a tested OCI image and configured provider.

## Build immutable inputs

Use an isolated Python >=3.12 build environment with pip/setuptools installed.
Create a private JSON mapping of ten repository names to their explicit clean
checkout paths: `platform-backend-core`, `platform-observability`,
`platform-infra-kit`, `platform-workflow`, `platform-data`, `platform-developer`,
`platform-security`, `platform-communication`, `platform-media`,
`platform-payment`. The builder records each exact Git revision, builds the
service wheels without fetching build dependencies, downloads compatible
CPython3.12/Linux x86_64 dependency wheels and hashes the entire wheel set.
It refuses dirty or changing source and an existing output directory.

```bash
python -m shared_infra.bundle --sources /private/source-paths.json --output /private/releases/shared-candidate
python -m shared_infra verify-bundle /private/releases/shared-candidate
```

The bundle Dockerfile installs without network access and checks every wheel
digest before installation. Supply a reviewed Python3.12-slim base image by its
actual SHA256 digest. Build on Linux x86_64 with the container engine; the wheel
bundle intentionally does not include ARM or another Python ABI.

```bash
docker build --build-arg BASE_IMAGE="$PINNED_PYTHON_BASE" --tag shared-infra:candidate /private/releases/shared-candidate
```

Run the acceptance harness in that image against an explicitly disposable test
PostgreSQL instance. Publish the tested image through the chosen registry and
record its returned repository manifest digest. A local image configuration ID
is not a registry manifest digest. This toolkit never invents an image digest,
pushes an image, creates resources or applies a workload.

Identity and the TypeScript AI gateway retain independent images and release
pipelines. Their staged configuration and gates are documented by their owners
(`platform-identity/docs/SHARED-RATE-LIMIT.md` and AI `docs/shared-admission.md`).
Do not switch production issuers or trust before the identity migration gate.

## Database and runtime configuration

Use a separate database and non-owner NOSUPERUSER/NOBYPASSRLS runtime role for
each service. Set a global connection allocation that includes all API maxima,
workers, identity, AI, administration and restore headroom. Each API uses one
bounded pool; API process replicas and worker processes count separately.

Migrate through the explicit operator command, with the DDL connection supplied
only to that short-lived process. There is no automatic startup migration:

```bash
PLATFORM_SERVICE=data python -m shared_infra.runtime migrate
```

The migration command reads `DATABASE_MIGRATION_DSN`. Serving processes receive
only `DATABASE_URL` and runtime settings. Use owning service documentation for
the exact grants. Namespace names are `workflow`, `data`, `flags` (developer),
`security`, `communication`, `platform_media`, `platform_payment`. Migration
history is checksummed; do not edit an applied migration. Readiness verifies
the service's migration history, forced RLS and required effective privileges.
The security audit table additionally forbids UPDATE/DELETE/TRUNCATE grants.

All seven API runtimes require explicit `PLATFORM_SERVICE`, `DATABASE_URL`,
`JWT_ISSUER`, `JWT_AUDIENCE`, and `JWT_PUBLIC_KEY` or `JWT_JWKS_URL`. The launcher
uses bounded pool/statement/request timeouts, port8080, concurrency64, graceful
shutdown and no access logs or proxy-header authority. Optional `METRICS_TOKEN`
enables authenticated metrics; `OTEL_TRACES_ENDPOINT` enables HTTPS export.
Missing provider configuration keeps the relevant API unready.

Configure provider variables only for the service that owns them. Media owns
S3 object credentials; payment owns Stripe **test mode only** and server-owned
plan catalog; communication owns the selected delivery adapters. The current
payment implementation deliberately rejects live Stripe keys/events. A real
payment release needs sandbox acceptance and a separately reviewed live-mode
change. No fixture adapter is selected by the production launcher.

## Render a bounded deployment

Create the version1 release plan described in README with an actual image
digest for every service. `replicas` is the minimum/fixed count;
`max_replicas` optionally enables CPU autoscaling. Connection allocation uses
the maximum, including worker allocations. The renderer currently emits API
workloads only and rejects a nonzero `workers` field so a worker allocation
cannot silently disappear. It emits no Secret, external ingress or database.

```bash
python -m shared_infra check-release /private/release.yaml
python -m shared_infra render-kubernetes /private/release.yaml --namespace shared-staging --output /private/workloads.yaml
```

Provision each `<service>-runtime` Secret with only approved runtime keys. A
`required_env` list is documentation/validation, never secret material. Do not
put migration/admin credentials in that Secret. The generated Deployment uses
the pinned image, non-root UID10001, read-only filesystem, private Service,
resource limits, probes, no API service-account token, spread across nodes,
disruption budget and at most the budgeted HPA count. Rolling updates use no
surge to keep the connection ceiling. Review namespace network policy against
the selected private database, DNS, provider egress and monitoring endpoints.

Workers use the same immutable image in separately budgeted workspace
Deployments. `platform-workflow worker` verifies its workspace worker JWT on
each poll; only `health.noop` is built in. Application handlers are trusted code
registered in their owning image, never caller-provided executable URLs.
Communication uses `python -m platform_communication worker` with the explicit
trusted `COMMUNICATION_WORKSPACE_ID`; mount only its database/provider settings.
Run multiple workers to increase throughput, retain lease fencing and rotate
worker JWTs before expiry. Use per-workspace worker groups; no wildcard tenant
worker bypasses RLS. Drain/stop workers before a rollback and allow leases to
expire before restarting replacements. Unknown external delivery remains
quarantined until trusted reconciliation.

## Acceptance, approval and rollback

Run the actual Python3.12 image against PostgreSQL16 (or the chosen matching
server), configured sandbox providers and the same network/proxy topology.
Exercise signed browser login → mapped permission → service JWT scopes,
simultaneous replicas/workers, global and tenant AI limits, webhook replay,
object checksums, billing/refunds and missing dependencies. Record actual
error/p95/throughput at increasing workload, the saturation point, backup age
and measured recovery time. This local run supplies no production SLA.

Run the safe backup/restore command into a **new** database and reopen services
using newly provisioned restricted roles. Backups exclude owners/grants, so
explicitly restore least privileges; they also exclude object-store bytes,
identity keys and provider configuration. Configure encrypted archive storage,
retention, object versioning/replication and alert receiver ownership before
production. Validate Prometheus rules with the chosen binary and drill a test
alert and its recovery without contacting a production receiver.

The reviewable production decision consists of image manifest digests, source
SHA/wheel hashes, configuration key names, capacity/cost, migrations, successful
sandbox acceptance, restore evidence and the previous compatible image. Apply
only after that decision is authorized. Existing production remains in its
documented migration state while this candidate is staged.

For rollback, disable new traffic, drain workers, restore the prior compatible
image and confirm readiness and tenant isolation. Leave additive schema in
place; do not apply destructive down-migrations. Payment migration002 needs a
rollback image that understands its billing/refund state. If data rollback is
required, restore to a new database, verify it and explicitly cut over; never
overwrite the live database as a rollback shortcut.
