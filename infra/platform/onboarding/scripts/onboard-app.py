#!/usr/bin/env python3
"""
Scaffold Solo Empire Kubernetes pilot app artifacts from templates.

Does not deploy, push, or touch cloud/production. Does not modify Docker Compose.
Existing apps with values_customized: true are not overwritten unless --force.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ONBOARDING = SCRIPTS.parent
PLATFORM = ONBOARDING.parent
ROOT = PLATFORM.parent.parent
TEMPLATES = ONBOARDING / "templates"
APPS = ONBOARDING / "apps"

sys.path.insert(0, str(SCRIPTS))


NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,48}$")


def render(template: str, mapping: dict[str, str], *, allow_remaining: bool = False) -> str:
    out = template
    for k, v in mapping.items():
        out = out.replace(f"__{k}__", v)
    missing = re.findall(r"__[A-Z0-9_]+__", out)
    if missing and not allow_remaining:
        raise SystemExit(f"Unreplaced placeholders: {sorted(set(missing))}")
    return out


def security_context_block(run_as_user: str | None) -> str:
    if not run_as_user:
        return (
            "# Use chart defaults for securityContext / podSecurityContext\n"
            "# (runAsNonRoot required by platform policies)\n"
        )
    uid = run_as_user
    return f"""podSecurityContext:
  runAsNonRoot: true
  runAsUser: {uid}
  runAsGroup: {uid}
  fsGroup: {uid}
  seccompProfile:
    type: RuntimeDefault

securityContext:
  allowPrivilegeEscalation: false
  privileged: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: {uid}
  capabilities:
    drop:
      - ALL
"""


def write_file(path: Path, content: str, *, force: bool, dry_run: bool) -> str:
    if path.exists() and not force:
        return f"skip (exists): {path.relative_to(ROOT)}"
    if dry_run:
        return f"would write: {path.relative_to(ROOT)}"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return f"wrote: {path.relative_to(ROOT)}"


def ensure_catalog_entry(entry: str, name: str, *, force: bool, dry_run: bool) -> str:
    catalog = PLATFORM / "gitops" / "applications" / "catalog" / "apps.yaml"
    text = catalog.read_text(encoding="utf-8")
    if re.search(rf"(?m)^\s+-\s+name:\s+{re.escape(name)}\s*$", text):
        if not force:
            return f"skip (catalog has {name}): {catalog.relative_to(ROOT)}"
        # force: leave catalog as-is (manual edit); do not duplicate
        return f"skip (catalog already has {name}; edit manually): {catalog.relative_to(ROOT)}"
    if dry_run:
        return f"would append catalog entry for {name}"
    if not text.endswith("\n"):
        text += "\n"
    text += "\n" + entry.rstrip() + "\n"
    catalog.write_text(text, encoding="utf-8")
    return f"appended catalog entry: {catalog.relative_to(ROOT)}"


def write_definition(
    name: str,
    args: argparse.Namespace,
    *,
    dry_run: bool,
    force: bool,
) -> Path:
    path = APPS / f"{name}.yaml"
    content = f"""# Pilot app definition — source of truth for onboarding metadata.
apiVersion: solo.empire/v1
kind: PilotApp
metadata:
  name: {name}
spec:
  team: {args.team}
  component: {args.component}
  mode: {args.mode}
  partOf: solo-empire
  environment: dev
  region: local
  cluster: k3d-solo-dev
  source_path: {args.source_path}
  dockerfile: {args.dockerfile or (args.source_path.rstrip('/') + '/Dockerfile')}
  image_name: {args.image_name or f'solo-empire/{name}'}
  data_contract: {args.data_contract}
  target_port: {args.target_port}
  run_as_user: {args.run_as_user or 'null'}
  ingress_hostname: {args.ingress_hostname or f'{name}.dev.local'}
  probes:
    liveness: {args.liveness}
    readiness: {args.readiness}
    startup: {args.startup}
  resources:
    requests:
      cpu: {args.cpu_request}
      memory: {args.memory_request}
    limits:
      cpu: "{args.cpu_limit}"
      memory: {args.memory_limit}
  autoscaling:
    enabled: true
    minReplicas: 1
    maxReplicas: 2
    targetCPUUtilizationPercentage: 80
  runbook: operations/{name.upper().replace('-', '_')}-PILOT-RUNBOOK.md
  values_customized: false
"""
    # Fix run_as_user null representation and runbook path convention
    if not args.run_as_user:
        content = content.replace("  run_as_user: null\n", "")
    runbook_name = name.upper().replace("-", "-")
    # Prefer NAME with hyphens uppercased poorly; use stable slug style
    runbook_rel = f"operations/{name.upper()}-PILOT-RUNBOOK.md"
    # booknbook style is BOOKNBOOK; ai-doc is AI-DOC-ASSISTANT
    runbook_rel = f"operations/{name.upper()}-PILOT-RUNBOOK.md"
    content = re.sub(
        r"runbook:.*",
        f"runbook: {runbook_rel}",
        content,
    )
    if path.exists() and not force:
        print(f"skip (exists): {path.relative_to(ROOT)}")
        return path
    if dry_run:
        print(f"would write: {path.relative_to(ROOT)}")
        return path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    print(f"wrote: {path.relative_to(ROOT)}")
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description="Scaffold a pilot app (no deploy)")
    parser.add_argument("--name", required=True, help="App slug (lowercase, hyphens)")
    parser.add_argument("--source-path", default="", help="Path to app source from repo root")
    parser.add_argument("--dockerfile", default="", help="Dockerfile path (optional)")
    parser.add_argument("--team", default="product")
    parser.add_argument("--component", default="web")
    parser.add_argument("--mode", default="web", choices=["web", "worker"])
    parser.add_argument("--image-name", default="")
    parser.add_argument("--data-contract", default="pilot-local")
    parser.add_argument("--target-port", type=int, default=8080)
    parser.add_argument("--run-as-user", default="")
    parser.add_argument("--ingress-hostname", default="")
    parser.add_argument("--liveness", default="/healthz")
    parser.add_argument("--readiness", default="/readyz")
    parser.add_argument("--startup", default="/healthz")
    parser.add_argument("--cpu-request", default="100m")
    parser.add_argument("--memory-request", default="256Mi")
    parser.add_argument("--cpu-limit", default="1")
    parser.add_argument("--memory-limit", default="1Gi")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--force", action="store_true", help="Overwrite existing scaffold files")
    parser.add_argument(
        "--from-definition",
        action="store_true",
        help="Scaffold artifacts from existing apps/<name>.yaml only",
    )
    args = parser.parse_args()

    name = args.name.strip()
    if not NAME_RE.match(name):
        print(f"ERROR: invalid app name {name!r} (use lowercase + hyphens)", file=sys.stderr)
        return 1

    # Known pilots: allow --from-definition without re-creating definition
    def_path = APPS / f"{name}.yaml"
    if args.from_definition or (def_path.exists() and not args.source_path):
        if not def_path.exists():
            print(f"ERROR: missing definition {def_path}", file=sys.stderr)
            return 1
        from lib_yaml import load_pilot_app

        app = load_pilot_app(def_path)
        spec = app["spec"]
        source_path = str(spec.get("source_path", ""))
        image_name = str(spec.get("image_name", f"solo-empire/{name}"))
        team = str(spec.get("team", "product"))
        component = str(spec.get("component", "web"))
        mode = str(spec.get("mode", "web"))
        target_port = str(spec.get("target_port", 8080))
        ingress = str(spec.get("ingress_hostname", f"{name}.dev.local"))
        data_contract = str(spec.get("data_contract", "pilot-local"))
        probes = spec.get("probes") or {}
        liveness = str(probes.get("liveness", "/healthz"))
        readiness = str(probes.get("readiness", "/readyz"))
        startup = str(probes.get("startup", "/healthz"))
        res = spec.get("resources") or {}
        req = res.get("requests") or {}
        lim = res.get("limits") or {}
        cpu_req = str(req.get("cpu", "100m"))
        mem_req = str(req.get("memory", "256Mi"))
        cpu_lim = str(lim.get("cpu", "1"))
        mem_lim = str(lim.get("memory", "1Gi"))
        run_as = spec.get("run_as_user")
        run_as_s = str(run_as) if run_as not in (None, "", "null") else ""
        values_customized = bool(spec.get("values_customized"))
        runbook = str(spec.get("runbook", f"operations/{name.upper()}-PILOT-RUNBOOK.md"))
    else:
        if not args.source_path:
            print("ERROR: --source-path required for new apps", file=sys.stderr)
            return 1
        if not args.data_contract:
            print("ERROR: --data-contract is required (explicit data contract)", file=sys.stderr)
            return 1
        write_definition(name, args, dry_run=args.dry_run, force=args.force)
        source_path = args.source_path
        image_name = args.image_name or f"solo-empire/{name}"
        team = args.team
        component = args.component
        mode = args.mode
        target_port = str(args.target_port)
        ingress = args.ingress_hostname or f"{name}.dev.local"
        data_contract = args.data_contract
        liveness = args.liveness
        readiness = args.readiness
        startup = args.startup
        cpu_req = args.cpu_request
        mem_req = args.memory_request
        cpu_lim = args.cpu_limit
        mem_lim = args.memory_limit
        run_as_s = args.run_as_user
        values_customized = False
        runbook = f"operations/{name.upper()}-PILOT-RUNBOOK.md"

    mapping = {
        "APP_NAME": name,
        "TEAM": team,
        "COMPONENT": component,
        "MODE": mode,
        "IMAGE_NAME": image_name,
        "TARGET_PORT": target_port,
        "INGRESS_HOSTNAME": ingress,
        "DATA_CONTRACT": data_contract,
        "SOURCE_PATH": source_path,
        "LIVENESS_PATH": liveness,
        "READINESS_PATH": readiness,
        "STARTUP_PATH": startup,
        "CPU_REQUEST": cpu_req,
        "MEMORY_REQUEST": mem_req,
        "CPU_LIMIT": cpu_lim,
        "MEMORY_LIMIT": mem_lim,
        "SECURITY_CONTEXT_BLOCK": security_context_block(run_as_s or None),
    }

    actions: list[str] = []

    # Dev values
    values_path = PLATFORM / "gitops" / "applications" / "values" / "dev" / f"{name}.yaml"
    if values_customized and values_path.exists() and not args.force:
        actions.append(f"skip (values_customized): {values_path.relative_to(ROOT)}")
    else:
        tpl = (TEMPLATES / "values-dev.yaml.tpl").read_text(encoding="utf-8")
        actions.append(
            write_file(
                values_path,
                render(tpl, mapping),
                force=args.force,
                dry_run=args.dry_run,
            )
        )

    # Argo Application template (local bootstrap)
    argo_tpl_path = (
        PLATFORM
        / "bootstrap"
        / "local"
        / "applications"
        / f"{name}-dev.yaml.tpl"
    )
    argo_tpl = (TEMPLATES / "argo-application.yaml.tpl").read_text(encoding="utf-8")
    # Bind app identity only; leave __ARGOCD_* / __IMAGE_* for deploy-time render
    argo_mapping = {"APP_NAME": name, "TEAM": team}
    actions.append(
        write_file(
            argo_tpl_path,
            render(argo_tpl, argo_mapping, allow_remaining=True),
            force=args.force,
            dry_run=args.dry_run,
        )
    )

    # Catalog entry
    cat_tpl = (TEMPLATES / "catalog-entry.yaml.tpl").read_text(encoding="utf-8")
    actions.append(
        ensure_catalog_entry(
            render(cat_tpl, mapping),
            name,
            force=args.force,
            dry_run=args.dry_run,
        )
    )

    # Runbook
    runbook_path = ROOT / runbook
    if values_customized and runbook_path.exists() and not args.force:
        actions.append(f"skip (runbook exists/customized): {runbook}")
    else:
        rb_tpl = (TEMPLATES / "runbook.md.tpl").read_text(encoding="utf-8")
        actions.append(
            write_file(
                runbook_path,
                render(rb_tpl, mapping),
                force=args.force,
                dry_run=args.dry_run,
            )
        )

    print(f"Onboard scaffold for {name}:")
    for a in actions:
        print(f"  {a}")
    print("\nNext steps:")
    print(f"  1. Ensure APP-INVENTORY.yaml lists {name} as approved with data_contract")
    print(f"  2. python3 infra/platform/onboarding/scripts/validate-onboarding.py")
    print(f"  3. bash infra/platform/bootstrap/local/deploy-app.sh {name}")
    print("Never use real secrets. Local k3d only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
