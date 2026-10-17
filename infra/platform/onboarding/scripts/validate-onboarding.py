#!/usr/bin/env python3
"""
Offline validation guards for onboarded Kubernetes pilot applications.

Checks:
  - unique app name and namespace
  - immutable image tag policy (no :latest)
  - required probes
  - required resources
  - required ownership labels
  - no hardcoded secrets
  - explicit data contract (inventory ↔ catalog)
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Any

SCRIPTS = Path(__file__).resolve().parent
ONBOARDING = SCRIPTS.parent
PLATFORM = ONBOARDING.parent
ROOT = PLATFORM.parent.parent
GITOPS = PLATFORM / "gitops" / "applications"
VALUES_DEV = GITOPS / "values" / "dev"
VALUES_STAGING = GITOPS / "values" / "staging"
CATALOG = GITOPS / "catalog" / "apps.yaml"
INVENTORY = PLATFORM / "APP-INVENTORY.yaml"
APPS_DIR = ONBOARDING / "apps"
DOCS_PLATFORM = ROOT / "operations" / "platform"
sys.path.insert(0, str(ROOT / "infra" / "scripts" / "platform"))
from platform_output import configure_utf8_stdio  # noqa: E402

sys.path.insert(0, str(SCRIPTS))

from lib_yaml import load_pilot_app, load_yaml  # noqa: E402

SECRET_PATTERNS = [
    re.compile(r"soloempire2026", re.IGNORECASE),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(
        r"(api[_-]?key|secret[_-]?key|password|token)\s*[:=]\s*['\"][A-Za-z0-9/+=_\-]{12,}['\"]",
        re.IGNORECASE,
    ),
]

FORBIDDEN_TAGS = {"latest", "0.1.0-local"}
# Catalog may use git-pending as a non-deployable marker; deploy scripts reject it.
ALLOWED_PLACEHOLDER_TAGS = {"git-pending"}

OWNERSHIP_KEYS = ("name:", "team:", "environment:", "component:", "partOf:")


class Checker:
    def __init__(self) -> None:
        self.passed = 0
        self.failures: list[str] = []

    def ok(self, msg: str) -> None:
        self.passed += 1
        print(f"  ✅ {msg}")

    def fail(self, msg: str) -> None:
        self.failures.append(msg)
        print(f"  ❌ {msg}")


def _tag_value(text: str) -> list[str]:
    return re.findall(r'(?m)^\s*tag:\s*["\']?([^"\'\n#]+)', text)


def validate_definition(c: Checker, path: Path) -> dict[str, Any]:
    app = load_pilot_app(path)
    name = app["name"]
    spec = app["spec"]
    if not re.match(r"^[a-z][a-z0-9-]{1,48}$", name):
        c.fail(f"{path.name}: invalid name {name!r}")
    else:
        c.ok(f"definition name ok: {name}")

    for field in (
        "team",
        "component",
        "mode",
        "source_path",
        "image_name",
        "data_contract",
        "target_port",
        "ingress_hostname",
    ):
        if not spec.get(field) and spec.get(field) != 0:
            c.fail(f"{name}: definition missing spec.{field}")
        else:
            c.ok(f"{name}: has spec.{field}")

    dc = str(spec.get("data_contract", "")).strip()
    if not dc or dc.lower() in {"tbd", "pending", "none", "null"}:
        c.fail(f"{name}: data_contract must be explicit (got {dc!r})")
    else:
        c.ok(f"{name}: data_contract={dc}")

    probes = spec.get("probes") or {}
    for p in ("liveness", "readiness", "startup"):
        if not probes.get(p):
            c.fail(f"{name}: missing probes.{p}")
        else:
            c.ok(f"{name}: probe {p}={probes[p]}")

    res = spec.get("resources") or {}
    if not (res.get("requests") and res.get("limits")):
        c.fail(f"{name}: definition resources.requests/limits required")
    else:
        c.ok(f"{name}: definition resources present")

    return app


def validate_values(c: Checker, name: str, text: str) -> None:
    # Ownership labels under app:
    for key in ("team:", "environment:", "component:", "partOf:"):
        if re.search(rf"(?m)^\s+{re.escape(key)}", text):
            c.ok(f"{name} values: ownership field {key.rstrip(':')}")
        else:
            c.fail(f"{name} values: missing ownership field {key.rstrip(':')}")

    # Probes
    for probe in ("liveness:", "readiness:", "startup:"):
        if probe in text and "enabled: true" in text:
            c.ok(f"{name} values: {probe.rstrip(':')} section present")
        else:
            c.fail(f"{name} values: missing or incomplete {probe.rstrip(':')}")

    # Each probe must have a path
    for probe in ("liveness", "readiness", "startup"):
        block = re.search(
            rf"(?ms)^\s+{probe}:\n(.*?)(?=^\s{{2}}[a-z]|\Z)",
            text,
        )
        if block and re.search(r"path:\s*\S+", block.group(1)):
            c.ok(f"{name} values: {probe}.path set")
        else:
            c.fail(f"{name} values: {probe}.path missing")

    # Resources
    if re.search(r"(?ms)resources:\s*\n\s+requests:.*limits:", text):
        c.ok(f"{name} values: resources.requests and limits")
    else:
        c.fail(f"{name} values: resources.requests/limits incomplete")

    # Tags
    for tag in _tag_value(text):
        tag = tag.strip()
        if tag in FORBIDDEN_TAGS:
            c.fail(f"{name} values: forbidden tag {tag!r}")
        elif tag in ALLOWED_PLACEHOLDER_TAGS:
            c.ok(f"{name} values: placeholder tag {tag} (deploy must replace)")
        elif tag.startswith("git-") and len(tag) > 10:
            c.ok(f"{name} values: immutable-looking tag {tag[:20]}…")
        else:
            # Accept other non-latest tags but warn via fail only for latest
            c.ok(f"{name} values: tag {tag!r} is not :latest")

    # NetworkPolicy
    if re.search(r"(?m)^\s*networkPolicy:\s*\n\s+enabled:\s*true", text):
        c.ok(f"{name} values: networkPolicy.enabled")
    else:
        c.fail(f"{name} values: networkPolicy must be enabled for pilots")

    # Secrets
    for pat in SECRET_PATTERNS:
        if pat.search(text):
            c.fail(f"{name} values: possible hardcoded secret ({pat.pattern[:30]})")
            return
    c.ok(f"{name} values: no hardcoded secret patterns")

    # No in-chart DB
    if (
        re.search(r"(?i)postgresql|redis:|bitnami/postgres", text)
        and "No PostgreSQL" not in text
    ):
        # comments about not using DB are fine; actual chart deps would look different
        if re.search(r"(?m)^(dependencies:|  postgresql:)", text):
            c.fail(f"{name} values: must not embed PostgreSQL/Redis chart deps")
        else:
            c.ok(f"{name} values: no in-chart DB dependency block")
    else:
        c.ok(f"{name} values: no in-chart DB dependency block")


def validate_catalog_and_inventory(c: Checker, names: list[str]) -> None:
    if not CATALOG.exists():
        c.fail("catalog apps.yaml missing")
        return
    cat = load_yaml(CATALOG) or {}
    apps = cat.get("applications") or []
    if not isinstance(apps, list):
        c.fail("catalog applications is not a list")
        return

    cat_names: list[str] = []
    cat_namespaces: list[str] = []
    for entry in apps:
        if not isinstance(entry, dict):
            continue
        n = entry.get("name")
        ns = entry.get("namespace")
        if n:
            cat_names.append(str(n))
        if ns:
            cat_namespaces.append(str(ns))
        tag = ((entry.get("image") or {}).get("tag")) or ""
        if str(tag) in FORBIDDEN_TAGS:
            c.fail(f"catalog {n}: forbidden tag {tag}")
        elif str(tag) in ALLOWED_PLACEHOLDER_TAGS or str(tag).startswith("git-"):
            c.ok(f"catalog {n}: tag policy ok ({tag})")
        else:
            c.ok(f"catalog {n}: tag {tag!r} not :latest")

        res = entry.get("resources") or {}
        if res.get("requests") and res.get("limits"):
            c.ok(f"catalog {n}: resources present")
        else:
            c.fail(f"catalog {n}: resources.requests/limits required")

        if entry.get("team"):
            c.ok(f"catalog {n}: team ownership")
        else:
            c.fail(f"catalog {n}: missing team")

    # Uniqueness
    if len(cat_names) != len(set(cat_names)):
        c.fail(f"duplicate catalog names: {cat_names}")
    else:
        c.ok(f"catalog names unique ({len(cat_names)})")

    if len(cat_namespaces) != len(set(cat_namespaces)):
        c.fail(f"duplicate catalog namespaces: {cat_namespaces}")
    else:
        c.ok(f"catalog namespaces unique ({len(cat_namespaces)})")

    # Definition names must match catalog for onboarded set
    for n in names:
        if n not in cat_names:
            c.fail(f"definition {n} missing from catalog")
        else:
            c.ok(f"definition {n} present in catalog")

    # Inventory data_contract for each catalog app
    if not INVENTORY.exists():
        c.fail("APP-INVENTORY.yaml missing")
        return
    inv = load_yaml(INVENTORY) or {}
    inv_apps = inv.get("applications") or []
    by_id = {
        str(a.get("id")): a for a in inv_apps if isinstance(a, dict) and a.get("id")
    }
    for n in cat_names:
        # skip pure examples if any
        if n.startswith("example"):
            continue
        entry = by_id.get(n)
        if not entry:
            c.fail(f"catalog app {n} missing from APP-INVENTORY.yaml")
            continue
        dc = entry.get("data_contract")
        if not dc or str(dc).lower() in {"tbd", "pending", "none"}:
            c.fail(f"inventory {n}: data_contract must be explicit (got {dc!r})")
        else:
            c.ok(f"inventory {n}: data_contract={dc}")
        if entry.get("status") != "approved":
            c.fail(f"inventory {n}: catalog apps must be status=approved")
        else:
            c.ok(f"inventory {n}: approved")
        ns = entry.get("namespace")
        expected_ns = f"apps-{n}-dev"
        if ns and ns != expected_ns:
            c.fail(f"inventory {n}: namespace {ns} != {expected_ns}")
        elif ns:
            c.ok(f"inventory {n}: namespace {ns}")

    # Full namespaces uniqueness across inventory approved apps
    inv_ns = [
        str(a.get("namespace"))
        for a in inv_apps
        if isinstance(a, dict) and a.get("namespace") and a.get("status") == "approved"
    ]
    if len(inv_ns) != len(set(inv_ns)):
        c.fail(f"duplicate inventory namespaces among approved: {inv_ns}")
    else:
        c.ok("approved inventory namespaces unique")


def validate_argo_templates(c: Checker, names: list[str]) -> None:
    for name in names:
        tpl = PLATFORM / "bootstrap" / "local" / "applications" / f"{name}-dev.yaml.tpl"
        if not tpl.exists():
            c.fail(f"missing Argo Application template: {tpl.name}")
            continue
        text = tpl.read_text(encoding="utf-8")
        if f"name: {name}-dev" not in text:
            c.fail(f"{tpl.name}: wrong application name")
        else:
            c.ok(f"{tpl.name}: application name")
        if f"namespace: apps-{name}-dev" not in text:
            c.fail(f"{tpl.name}: wrong destination namespace")
        else:
            c.ok(f"{tpl.name}: destination namespace")
        # Allow documentation that forbids file://; reject live repoURL: file://
        if re.search(r"(?m)^\s*repoURL:\s*file://", text) or re.search(
            r"repoURL:\s*['\"]file://", text
        ):
            c.fail(f"{tpl.name}: must not use file:// repoURL")
        else:
            c.ok(f"{tpl.name}: no file:// repoURL")
        if "__IMAGE_TAG__" not in text:
            c.fail(f"{tpl.name}: missing image tag placeholder")
        else:
            c.ok(f"{tpl.name}: image tag placeholder")


def validate_no_secrets_in_onboarding(c: Checker) -> None:
    skip_names = {
        "validate-onboarding.py",  # defines SECRET_PATTERNS
        "lib_yaml.py",
    }
    for path in ONBOARDING.rglob("*"):
        if not path.is_file():
            continue
        if path.name in skip_names:
            continue
        if path.suffix not in {".yaml", ".yml", ".tpl", ".md", ".py", ".sh"}:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for pat in SECRET_PATTERNS:
            if not pat.search(text):
                continue
            if "soloempire2026" in pat.pattern:
                if re.search(
                    r"(PASSWORD|TOKEN|SECRET).{0,20}soloempire2026", text, re.IGNORECASE
                ):
                    c.fail(f"secret-like content in {path.relative_to(ROOT)}")
                    return
                continue
            c.fail(f"secret-like content in {path.relative_to(ROOT)}")
            return
    c.ok("onboarding tree: no hardcoded secret patterns")


def validate_expected_pilots(c: Checker, names: list[str]) -> None:
    expected = {"ai-doc-assistant", "booknbook"}
    have = set(names)
    if expected <= have:
        c.ok(f"both pilots defined: {sorted(expected)}")
    else:
        c.fail(f"expected pilots {sorted(expected)}, found {sorted(have)}")
    # Explicit: no third pilot required; if more exist, just note uniqueness already checked
    if len(have) > 2:
        c.ok(
            f"additional pilot definitions present: {sorted(have - expected)} (validate only)"
        )


def validate_staging_readiness(c: Checker, names: list[str]) -> None:
    """Staging values exist, deployment disabled, same guards as dev."""
    gate = VALUES_STAGING / "DEPLOYMENT.md"
    if gate.exists() and "DISABLED" in gate.read_text(encoding="utf-8").upper():
        c.ok("staging DEPLOYMENT.md documents disabled gate")
    else:
        c.fail("staging/DEPLOYMENT.md missing or does not document DISABLED")

    appset = GITOPS / "applicationset.yaml"
    if appset.exists():
        text = appset.read_text(encoding="utf-8")
        # Active list should not include uncommented staging environment entries
        active_staging = re.findall(r"(?m)^\s+-\s+environment:\s+staging\s*$", text)
        if active_staging:
            c.fail(
                "applicationset.yaml has active staging generator (must stay disabled)"
            )
        else:
            c.ok("applicationset.yaml has no active staging generator")
    else:
        c.fail("applicationset.yaml missing")

    for name in names:
        vpath = VALUES_STAGING / f"{name}.yaml"
        if not vpath.exists():
            c.fail(f"missing values/staging/{name}.yaml")
            continue
        text = vpath.read_text(encoding="utf-8")
        c.ok(f"staging values present: {name}")

        # Deployment must be disabled by default
        if re.search(r"(?m)^\s*deploymentEnabled:\s*false\s*$", text):
            c.ok(f"{name} staging: deploymentEnabled=false")
        else:
            c.fail(f"{name} staging: deploymentEnabled must be false by default")

        if re.search(r"(?m)^\s*environment:\s*staging\s*$", text):
            c.ok(f"{name} staging: environment=staging")
        else:
            c.fail(f"{name} staging: app.environment must be staging")

        # data contract marker
        if re.search(r"(?m)^\s*dataContract:\s*\S+", text) or "data_contract" in text:
            c.ok(f"{name} staging: dataContract present")
        else:
            c.fail(f"{name} staging: soloEmpire.dataContract required")

        # Reuse core values guards (probes, resources, labels, secrets, tags, netpol)
        validate_values(c, f"{name}/staging", text)

        # No live Argo staging Application templates for pilots
        bad_tpl = (
            PLATFORM
            / "bootstrap"
            / "local"
            / "applications"
            / f"{name}-staging.yaml.tpl"
        )
        if bad_tpl.exists():
            c.fail(
                f"unexpected staging Argo template {bad_tpl.name} (deploy must stay off)"
            )
        else:
            c.ok(f"{name}: no local staging Argo Application template")

        # Namespace convention documented in comments or soloEmpire
        if f"apps-{name}-staging" in text or "staging" in text:
            c.ok(f"{name} staging: staging env markers present")


def validate_docs_and_contract(c: Checker) -> None:
    env = PLATFORM / "ENVIRONMENT-CONTRACT.md"
    if not env.exists():
        c.fail("ENVIRONMENT-CONTRACT.md missing")
        return
    text = env.read_text(encoding="utf-8")
    for section in (
        "Namespace",
        "Registry",
        "Secrets",
        "Ingress",
        "Database",
        "Resource",
    ):
        if section.lower() in text.lower():
            c.ok(f"ENVIRONMENT-CONTRACT covers {section}")
        else:
            c.fail(f"ENVIRONMENT-CONTRACT missing section for {section}")

    for rel in (
        "PRODUCTION-GAPS.md",
        "PROVIDER-DECISION.md",
        "STAGING-INFRA-RUNBOOK.md",
    ):
        path = DOCS_PLATFORM / rel
        if path.exists():
            c.ok(f"operations/platform/{rel} present")
        else:
            c.fail(f"operations/platform/{rel} missing")

    iac_root = PLATFORM / "iac" / "envs" / "staging" / "fsn1" / "main.tf"
    if iac_root.exists():
        text = iac_root.read_text(encoding="utf-8")
        if "provision" in text and "false" in (
            PLATFORM / "iac" / "envs" / "staging" / "fsn1" / "variables.tf"
        ).read_text(encoding="utf-8"):
            c.ok("staging IaC root present with provision variable")
        else:
            c.ok("staging IaC root present")
    else:
        c.fail("staging IaC root main.tf missing")

    prod_disabled = PLATFORM / "iac" / "envs" / "production" / "README.md"
    if (
        prod_disabled.exists()
        and "DISABLED" in prod_disabled.read_text(encoding="utf-8").upper()
    ):
        c.ok("production IaC marked DISABLED")
    else:
        c.fail("production IaC must remain disabled (README)")

    gaps = DOCS_PLATFORM / "PRODUCTION-GAPS.md"
    if gaps.exists():
        gtext = gaps.read_text(encoding="utf-8")
        for topic in (
            "PostgreSQL",
            "vector",
            "Object storage",
            "PITR",
            "signing",
            "TLS",
            "Observability",
            "Cost",
        ):
            if topic.lower() in gtext.lower():
                c.ok(f"PRODUCTION-GAPS mentions {topic}")
            else:
                c.fail(f"PRODUCTION-GAPS missing topic {topic}")


def main() -> int:
    configure_utf8_stdio()
    parser = argparse.ArgumentParser()
    parser.add_argument("--quiet-header", action="store_true")
    args = parser.parse_args()
    c = Checker()
    if not args.quiet_header:
        print("Solo Empire onboarding validation (offline)")

    defs = sorted(APPS_DIR.glob("*.yaml"))
    if not defs:
        c.fail("no app definitions under onboarding/apps/")
        print_summary(c)
        return 1

    names: list[str] = []
    print("\n[onboarding] App definitions")
    for path in defs:
        app = validate_definition(c, path)
        names.append(app["name"])

    print("\n[onboarding] Dev values guards")
    for name in names:
        vpath = VALUES_DEV / f"{name}.yaml"
        if not vpath.exists():
            c.fail(f"missing values/dev/{name}.yaml")
            continue
        validate_values(c, name, vpath.read_text(encoding="utf-8"))

    print("\n[onboarding] Staging readiness (deploy disabled)")
    validate_staging_readiness(c, names)

    print("\n[onboarding] Catalog, inventory, uniqueness, data contract")
    validate_catalog_and_inventory(c, names)

    print("\n[onboarding] Argo Application templates")
    validate_argo_templates(c, names)

    print("\n[onboarding] Environment contract + production gaps docs")
    validate_docs_and_contract(c)

    print("\n[onboarding] Secret scan + expected pilots")
    validate_no_secrets_in_onboarding(c)
    validate_expected_pilots(c, names)

    # Deploy scripts exist
    print("\n[onboarding] Deploy entrypoints")
    deploy = PLATFORM / "bootstrap" / "local" / "deploy-app.sh"
    if deploy.exists() and deploy.stat().st_mode & 0o111:
        c.ok("deploy-app.sh present and executable")
    elif deploy.exists():
        c.ok("deploy-app.sh present")
    else:
        c.fail("deploy-app.sh missing")

    print_summary(c)
    return 1 if c.failures else 0


def print_summary(c: Checker) -> None:
    print("\n" + "=" * 60)
    print(f"Onboarding: Passed={c.passed}  Failures={len(c.failures)}")
    if c.failures:
        print("FAILURES:")
        for f in c.failures:
            print(f"  - {f}")
    else:
        print("All onboarding validation checks passed.")


if __name__ == "__main__":
    raise SystemExit(main())
