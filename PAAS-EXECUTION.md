---
title: Governed PaaS Execution
created: 2026-09-07
updated: 2026-09-07
description: Local owner workflow for approved Render actions, verification, and non-replayable submission.
---

# Governed PaaS Execution

The Cloud/PaaS page at `/cloud` combines the existing catalog and usage views
with a local owner command workflow. The owner reviews the stored request,
approves it, explicitly submits it, and checks the result from the same page.
`infra/scripts/platform/paas_execute.py` owns orchestration;
`paas_action.py` owns canonical proposals and registration; SQLite
`decision_records` and `decision_events` remain the approval and audit store.

## Capability boundary

| Capability | Implemented behavior |
| --- | --- |
| Render deploy | Pinned 40-character Git commit SHA, web service only |
| Render rollback | Successful previous deploy belonging to the same service |
| Render restart | Submit restart; no inferred success when Render returns no deploy ID |
| Render set autoDeploy | Explicit `yes`/`no` service configuration through the same approval and verification flow |
| Approval and history | Local registration, explicit review/approval, exact request fingerprint, durable submission claim |
| Verification | Named deploy must be live; deploy revision must match; provider-owned HTTPS health endpoint must pass |
| Vercel, Railway, Fly.io, Heroku | Existing read adapters; write adapters remain disabled |
| Billing | Existing Vercel charges and R2 storage signals; other providers remain explicit gaps |
| Environment variables, new resources, infrastructure provisioning | No mutation adapter in this release |

This is an implemented Render execution lane, not a claim that the entire
multi-cloud management project or production acceptance is complete. Live
acceptance requires an owner-selected service/environment and exact action.

## Owner workflow

1. Start the dashboard API and frontend; open `/cloud` from `localhost`.
2. Use **ค้นหาแบบ read-only** in the Render target panel when a local Render
   CLI session or `RENDER_API_KEY` is available. Selecting a discovered service
   fills its service and environment IDs and, when Render exposes one, its
   configured health path; selecting a recent deploy while the action is
   `rollback` fills the rollback target. Discovery never sends a provider
   mutation and never returns provider payloads or credentials.
3. Select **ตรวจ action preflight** before creating a request. The bounded GET
   route derives the service's provider-owned Render health origin, checks the
   selected environment and recovery deploy, and verifies either the health
   endpoint or requested autoDeploy state. The page shows blockers and clears
   the result when a target field changes. It never sends a provider mutation.
4. Confirm `staging` or `production`, health path when the action needs it,
   action target, and a short non-secret reason. A discovered service with
   `autoDeploy` enabled remains blocked for deploy/restart/rollback until the
   owner creates and approves a separate **Set autoDeploy** request. That
   configuration action uses the same live preflight, atomic claim, provider
   PATCH, and post-write verification; it is never an implicit preflight side
   effect.
5. Create the request. This writes only local decision metadata.
6. Review the persisted request and select the approval confirmation.
7. Select the separate execution confirmation and submit.
8. Check provider results. A successful API submission is not deployment success.

The API must be directly reachable on loopback port `3456`. Browser commands
use `POST /api/paas/commands` directly, bypassing the Next.js read proxy.
Only loopback peers with a loopback Host, an allowed local Origin, JSON content
type, and `X-Solo-PaaS-Command: 1` are accepted. Forwarded requests are rejected.
This is a single-owner local boundary, not remote multi-user authentication.
Both `localhost` and `127.0.0.1` origins are supported by default.
To run the frontend on a different local port, add that exact localhost origin
to `DASHBOARD_CORS_ORIGINS` when starting the API. Do not expose a reverse proxy
that strips forwarding evidence and spoofs local origins.

## CLI protocol

`task paas:command` reads one JSON object from stdin (maximum 16 KiB). Prefer a
local file or a quoted here-document over shell interpolation. Never include
credentials or environment-variable values in a request.

```bash
task paas:command <<'JSON'
{"operation":"register","request":{"provider":"render","action":"rollback","resource_type":"service","resource_id":"srv-example","environment":"staging","environment_id":"evm-example","health_path":"/healthz","target_revision":null,"rollback_target":"dep-previous","reason":"Restore the tested revision"}}
JSON
```

The bounded service configuration action uses `action` `set-auto-deploy`, an
`auto_deploy` value of `yes` or `no`, and does not require a health path:

```json
{"operation":"register","request":{"provider":"render","action":"set-auto-deploy","resource_type":"service","resource_id":"srv-example","environment":"production","environment_id":"evm-example","health_path":null,"target_revision":null,"rollback_target":null,"auto_deploy":"no","reason":"Keep releases behind the governed control plane"}}
```

Commands after registration accept `decision_id`:

| Operation | Additional fields | Effects |
| --- | --- | --- |
| `status` | None | Read the stored request and latest attempt |
| `approve` | `proposal_id`, `confirm: true` | Approve the exact reviewed fingerprint locally |
| `execute` | `confirm: true` | Live preflight, atomic claim, one provider POST |
| `verify` | `confirm: true` | Provider reads and health check; append terminal evidence locally |

The existing decision CLI can also approve a registered request. Legacy
proposals lacking structured request metadata must be registered afresh with
the verification context. Request data is recovered from the canonical audit
event, never from a browser-supplied replacement at execution time.

## Preflight and uncertainty

- Verify the service ID, web-service type, active state, environment ID and
  environment name against Render.
- For deploy, restart, and rollback, require automatic deploys to be disabled
  and no deploy currently in progress.
- For `set-auto-deploy`, require a known current state that differs from the
  requested `yes`/`no` value, then verify the provider reflects that value.
- For deploy, restart, and rollback, record the existing live deploy as the
  recovery reference and require a successful same-service rollback target for
  rollback.
- For actions with health verification, use the service's
  `https://<service>.onrender.com` origin plus the approved health path; no
  custom hosts, queries, credentials, redirects, or proxies.
- Health probes allow up to 20 seconds for a Render cold start; a timeout is
  still a blocker and never triggers a retry or provider write.
- Recheck approval inside `BEGIN IMMEDIATE`, then persist the claim before POST.
- A second executor, requeued decision, or network timeout cannot replay the
  claim. Submission uncertainty remains blocked for operator reconciliation.
- Never send provider response bodies, tokens, or unbounded errors to the UI.

`pending` means a named deployment or configuration update still needs
verification. `succeeded` means the named deployment and health check passed,
or the requested configuration is visible on the provider. `failed` records a
terminal provider failure. `submission_unknown` requires provider inspection
before any new decision; `verification_required` means the provider
acknowledged a deployment call without a usable deploy ID (including the
documented restart response).
Verification after 15 minutes reports a timeout without resubmitting or
automatically rolling back. A rollback is always a separate reviewed request.

## Validation and remaining acceptance

`task test:platform` covers approval binding, revoked approvals, disabled
execution, malformed identifiers, replay attempts, transport uncertainty,
provider response filtering, revision verification, and the HTTP owner gate.
`task test`, `task typecheck`, `task docs:check`, and frontend type checking
cover the surrounding repository. These fixture checks do not establish live
Render permissions, health-route availability, or production readiness.

Provider contracts checked against official documentation:
[deploy](https://api-docs.render.com/reference/create-deploy),
[rollback](https://api-docs.render.com/reference/rollback-deploy),
[restart](https://api-docs.render.com/reference/restart-service),
[update service](https://api-docs.render.com/reference/update-service),
[retrieve deploy](https://api-docs.render.com/reference/retrieve-deploy), and
[retrieve environment](https://api-docs.render.com/reference/retrieve-environment).
In particular, the rollback path is `/rollback`, not `/rollbackTrigger`.
