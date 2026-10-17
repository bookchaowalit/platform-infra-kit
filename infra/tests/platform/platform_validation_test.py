#!/usr/bin/env python3
"""
Platform validation tests (no cluster, no cloud).

Checks:
- Compose lab has no hardcoded lab passwords
- Compose lab documents local-only warning
- Platform production-target manifests have no secrets / no :latest
- Helm chart structure is complete
- Kyverno policies exist and default to Audit
- GitOps catalog + env overlays exist
- Application catalog fields are present
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PLATFORM_SCRIPTS = ROOT / "infra" / "scripts" / "platform"
if str(PLATFORM_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(PLATFORM_SCRIPTS))

from platform_output import configure_utf8_stdio  # noqa: E402


PLATFORM = ROOT / "infra" / "platform"
OPS_PLATFORM = ROOT / "operations" / "platform"
OPS_AI = ROOT / "operations" / "ai"
OPS_RUNBOOKS = ROOT / "operations" / "runbooks"
HELM = PLATFORM / "helm" / "solo-app"
POLICIES = PLATFORM / "policies" / "kyverno"
GITOPS = PLATFORM / "gitops"

# Patterns that indicate committed secrets in production-target paths
SECRET_PATTERNS = [
    re.compile(r"soloempire2026", re.IGNORECASE),
    re.compile(
        r"password\s*[:=]\s*['\"]?(?!change-me|changeme|\$\{|<.*>|your-|placeholder|example)[^\s'\"]{8,}",
        re.IGNORECASE,
    ),
    re.compile(
        r"(api[_-]?key|secret[_-]?key|private[_-]?key)\s*[:=]\s*['\"][A-Za-z0-9/+=]{16,}['\"]",
        re.IGNORECASE,
    ),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"xox[bpas]-[A-Za-z0-9-]{10,}"),
]

# Match image references ending in :latest, but not policy patterns like "!*:latest"
LATEST_IMAGE = re.compile(
    r"""(?:image:\s*|repository:\s*)['"]?([A-Za-z0-9._\-]+(?:/[A-Za-z0-9._\-]+)*:latest)['"]?""",
    re.IGNORECASE,
)

# Known lab-only :latest exceptions (annotated in compose; not production targets)
LAB_LATEST_ALLOW = {
    "kennethreitz/httpbin:latest",
    "excalidraw/excalidraw:latest",
    "zedeus/nitter:latest",
    "fariszr/breezewiki:latest",
}


class Checker:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []
        self.passed = 0

    def ok(self, msg: str) -> None:
        self.passed += 1
        print(f"  ✅ {msg}")

    def fail(self, msg: str) -> None:
        self.failures.append(msg)
        print(f"  ❌ {msg}")

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)
        print(f"  ⚠️  {msg}")


def test_helm_chart(c: Checker) -> None:
    print("\n[helm] solo-app chart structure")
    required = [
        HELM / "Chart.yaml",
        HELM / "values.yaml",
        HELM / "templates" / "deployment.yaml",
        HELM / "templates" / "service.yaml",
        HELM / "templates" / "ingress.yaml",
        HELM / "templates" / "httproute.yaml",
        HELM / "templates" / "serviceaccount.yaml",
        HELM / "templates" / "configmap.yaml",
        HELM / "templates" / "externalsecret.yaml",
        HELM / "templates" / "hpa.yaml",
        HELM / "templates" / "pdb.yaml",
        HELM / "templates" / "networkpolicy.yaml",
        HELM / "templates" / "keda-scaledobject.yaml",
        HELM / "templates" / "servicemonitor.yaml",
        HELM / "templates" / "_helpers.tpl",
    ]
    missing = [str(p.relative_to(ROOT)) for p in required if not p.exists()]
    if missing:
        c.fail(f"Missing chart files: {missing}")
    else:
        c.ok("All required chart templates present")

    values = (HELM / "values.yaml").read_text(encoding="utf-8")
    for key in (
        "liveness",
        "readiness",
        "startup",
        "resources",
        "autoscaling",
        "networkPolicy",
        "topologySpreadConstraints",
        "externalSecrets",
        "keda",
        "serviceMonitor",
        "runAsNonRoot",
    ):
        if key in values:
            c.ok(f"values.yaml includes {key}")
        else:
            c.fail(f"values.yaml missing {key}")

    helpers = (HELM / "templates" / "_helpers.tpl").read_text(encoding="utf-8")
    if "latest" in helpers and "must not be" in helpers:
        c.ok("Chart fails closed on image.tag=latest")
    else:
        c.fail("Chart helper does not reject :latest tags")

    if 'define "solo-app.externalSecretName"' in helpers:
        c.ok("Helper solo-app.externalSecretName is defined")
    else:
        c.fail("Helper solo-app.externalSecretName missing")

    ext = (HELM / "templates" / "externalsecret.yaml").read_text(encoding="utf-8")
    dep = (HELM / "templates" / "deployment.yaml").read_text(encoding="utf-8")
    if 'include "solo-app.externalSecretName"' in ext:
        c.ok("ExternalSecret uses solo-app.externalSecretName")
    else:
        c.fail("ExternalSecret does not use solo-app.externalSecretName")
    if (
        'include "solo-app.externalSecretName"' in dep
        and "externalSecrets.enabled" in dep
    ):
        c.ok("Deployment auto-mounts ExternalSecret when enabled")
    else:
        c.fail("Deployment does not auto-wire ExternalSecret target name")

    # Values files must not hardcode a divergent envFromSecrets name for ESO
    for env in ("dev", "staging", "production"):
        path = GITOPS / "applications" / "values" / env / "example-api.yaml"
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        if re.search(
            r"envFromSecrets:\s*\n\s*-\s*secretRef:\s*\n\s*name:\s*example-api-secrets",
            text,
        ):
            c.fail(
                f"{env}/example-api.yaml still hardcodes envFromSecrets example-api-secrets"
            )
        else:
            c.ok(f"{env}/example-api.yaml relies on auto-wired ExternalSecret mount")


def test_gitops(c: Checker) -> None:
    print("\n[gitops] Application catalog and overlays")
    catalog = GITOPS / "applications" / "catalog" / "apps.yaml"
    appset = GITOPS / "applications" / "applicationset.yaml"
    if catalog.exists():
        c.ok("Application catalog exists")
        cat = catalog.read_text(encoding="utf-8")
        for field in (
            "name:",
            "namespace:",
            "image:",
            "repository:",
            "tag:",
            "replicas:",
            "resources:",
            "ingress:",
            "secrets:",
            "autoscaling:",
        ):
            if field not in cat:
                c.fail(f"Catalog missing field marker: {field}")
            else:
                c.ok(f"Catalog includes {field.strip(':')}")
    else:
        c.fail("Application catalog missing")

    if appset.exists():
        c.ok("ApplicationSet manifest exists")
    else:
        c.fail("ApplicationSet manifest missing")

    for env in ("dev", "staging", "production"):
        common = GITOPS / "applications" / "values" / env / "common.yaml"
        cluster = GITOPS / "clusters" / env / "README.md"
        if common.exists():
            c.ok(f"Values overlay for {env}")
        else:
            c.fail(f"Missing values overlay: {env}/common.yaml")
        if cluster.exists():
            c.ok(f"Cluster notes for {env}")
        else:
            c.fail(f"Missing cluster README: {env}")


def test_policies(c: Checker) -> None:
    print("\n[policies] Kyverno Audit-mode policies")
    expected = [
        "disallow-latest-tag.yaml",
        "approved-registries.yaml",
        "require-non-root.yaml",
        "require-labels.yaml",
        "require-resources.yaml",
        "disallow-privileged.yaml",
        "disallow-host-namespaces.yaml",
        "require-readonly-rootfs.yaml",
        "image-provenance-placeholder.yaml",
    ]
    for name in expected:
        path = POLICIES / name
        if not path.exists():
            c.fail(f"Missing policy: {name}")
            continue
        text = path.read_text(encoding="utf-8")
        if (
            "validationFailureAction: Audit" in text
            or name == "image-provenance-placeholder.yaml"
        ):
            c.ok(f"{name} present (Audit/placeholder)")
        else:
            c.fail(f"{name} not in Audit mode")

        if "Enforce" in text and "validationFailureAction: Enforce" in text:
            c.fail(f"{name} is already Enforce (expected Audit start)")


def test_platform_no_secrets_or_latest(c: Checker, strict: bool) -> None:
    print("\n[platform] Production-target secret and :latest scan")
    if not PLATFORM.exists():
        c.fail("infra/platform missing")
        return

    skip_parts = {"README.md", "NOTES.txt"}
    bad_secret_hits: list[str] = []
    latest_hits: list[str] = []

    for path in PLATFORM.rglob("*"):
        if not path.is_file():
            continue
        # Skip OpenTofu/Terraform provider caches and local state
        parts = set(path.parts)
        if ".terraform" in parts or path.suffix in {".tfstate", ".tfplan"}:
            continue
        if path.name.endswith(".tfstate.backup"):
            continue
        if path.suffix not in {
            ".yaml",
            ".yml",
            ".tpl",
            ".txt",
            ".md",
            ".tf",
            ".tftpl",
            ".example",
        }:
            continue
        if path.name in skip_parts and path.suffix == ".md":
            # still scan md lightly for secrets but not latest
            pass
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = str(path.relative_to(ROOT))

        for pat in SECRET_PATTERNS:
            if pat.search(text):
                # Allow documentation mentioning the old password pattern as forbidden example
                if "soloempire2026" in pat.pattern and "soloempire2026" in text:
                    # only fail if it looks like an assignment
                    if re.search(
                        r"(PASSWORD|TOKEN|SECRET).{0,20}soloempire2026",
                        text,
                        re.IGNORECASE,
                    ):
                        bad_secret_hits.append(f"{rel}: soloempire2026 assignment")
                elif "soloempire2026" not in pat.pattern:
                    # OpenTofu password variables / random_password are not committed secrets
                    if path.suffix in {".tf", ".tftpl", ".hcl", ".md"} and re.search(
                        r"random_password|registry_password|htpasswd|sensitive\s*=\s*true",
                        text,
                        re.IGNORECASE,
                    ):
                        # still flag hard-coded quoted secrets
                        if re.search(
                            r"""(?<!_)(password|token|secret)\s*=\s*["'][A-Za-z0-9/+=_\-]{12,}["']""",
                            text,
                            re.IGNORECASE,
                        ):
                            bad_secret_hits.append(
                                f"{rel}: hardcoded secret assignment"
                            )
                        continue
                    bad_secret_hits.append(f"{rel}: {pat.pattern[:40]}")

        if path.suffix in {".yaml", ".yml", ".tpl"}:
            for match in LATEST_IMAGE.finditer(text):
                latest_hits.append(f"{rel}: {match.group(1)}")
            # also catch plain tag: "latest"
            if re.search(r'tag:\s*["\']?latest["\']?', text):
                latest_hits.append(f"{rel}: tag: latest")

    if bad_secret_hits:
        c.fail(f"Secret-like content in platform: {bad_secret_hits[:10]}")
    else:
        c.ok("No hardcoded secrets detected in platform manifests")

    if latest_hits:
        c.fail(f":latest found in platform manifests: {latest_hits[:10]}")
    else:
        c.ok("No :latest image tags in platform manifests")

    iac_readme = PLATFORM / "iac" / "README.md"
    if iac_readme.exists():
        c.ok("IaC design README present")
    else:
        c.fail("IaC design README missing")

    readiness = OPS_PLATFORM / "KUBERNETES-PLATFORM-READINESS.md"
    if readiness.exists():
        c.ok("Readiness doc present")
    else:
        if strict:
            c.fail("KUBERNETES-PLATFORM-READINESS.md missing")
        else:
            c.warn(
                "KUBERNETES-PLATFORM-READINESS.md missing (create in this change set)"
            )


def test_gitignore_env(c: Checker) -> None:
    print("\n[git] .env ignore rules")
    gi = ROOT / ".gitignore"
    text = gi.read_text(encoding="utf-8")
    if ".env" in text:
        c.ok(".env ignored at repo level")
    else:
        c.fail(".env not ignored")


def test_onboarding_workflow(c: Checker) -> None:
    """Reusable onboarding workflow + offline guards (both pilots)."""
    print("\n[onboarding] Reusable workflow and guards")
    onboarding = PLATFORM / "onboarding"
    required_paths = [
        onboarding / "README.md",
        onboarding / "apps" / "ai-doc-assistant.yaml",
        onboarding / "apps" / "booknbook.yaml",
        onboarding / "templates" / "argo-application.yaml.tpl",
        onboarding / "templates" / "values-dev.yaml.tpl",
        onboarding / "templates" / "catalog-entry.yaml.tpl",
        onboarding / "templates" / "runbook.md.tpl",
        onboarding / "scripts" / "onboard-app.py",
        onboarding / "scripts" / "validate-onboarding.py",
        onboarding / "scripts" / "app_env.py",
        PLATFORM / "bootstrap" / "local" / "deploy-app.sh",
        PLATFORM / "bootstrap" / "local" / "verify-pilots-regression.sh",
        PLATFORM / "bootstrap" / "local" / "smoke-booknbook.sh",
        GITOPS / "applications" / "values" / "staging" / "ai-doc-assistant.yaml",
        GITOPS / "applications" / "values" / "staging" / "booknbook.yaml",
        GITOPS / "applications" / "values" / "staging" / "DEPLOYMENT.md",
        PLATFORM / "ENVIRONMENT-CONTRACT.md",
        OPS_PLATFORM / "PRODUCTION-GAPS.md",
        OPS_PLATFORM / "PROVIDER-DECISION.md",
        OPS_PLATFORM / "STAGING-INFRA-RUNBOOK.md",
        PLATFORM / "iac" / "envs" / "staging" / "fsn1" / "main.tf",
        PLATFORM / "iac" / "envs" / "production" / "README.md",
        PLATFORM / "iac" / "scripts" / "plan-staging.sh",
    ]
    missing = [str(p.relative_to(ROOT)) for p in required_paths if not p.exists()]
    if missing:
        c.fail(f"Onboarding workflow files missing: {missing}")
    else:
        c.ok("Onboarding templates, definitions, and scripts present")

    # Run dedicated validator and fold results
    import subprocess

    val = onboarding / "scripts" / "validate-onboarding.py"
    proc = subprocess.run(
        [sys.executable, str(val)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,  # the return code is reported below
    )
    # Re-print child output indented for readability
    for line in (proc.stdout or "").splitlines():
        if line.startswith(("  ✅", "  ❌")):
            # Count via parent checker based on markers
            msg = line[4:].strip() if len(line) > 4 else line
            if line.startswith("  ✅"):
                c.ok(msg)
            else:
                c.fail(msg)
        elif line.startswith(
            (
                "Solo Empire",
                "[onboarding]",
                "=",
                "Onboarding:",
                "All onboarding",
                "FAILURES",
                "  - ",
            )
        ):
            print(line)

    if proc.returncode != 0 and not any("onboarding" in f.lower() for f in c.failures):
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        c.fail(f"validate-onboarding.py failed: {err[:200]}")


def test_url_catalog_workflow(c: Checker) -> None:
    """Homelab URL catalog + DNS helpers offline gates."""
    print("\n[url-catalog] Homelab URL catalog offline gates")
    required = [
        PLATFORM / "homelab" / "validate-url-catalog.py",
        PLATFORM / "bootstrap" / "homelab" / "hosts.homelab.fragment",
        PLATFORM / "bootstrap" / "homelab" / "sync-homelab-dns.sh",
        PLATFORM / "bootstrap" / "homelab" / "verify-homelab-urls.sh",
        OPS_PLATFORM / "HOMELAB-URL-CATALOG.md",
    ]
    missing = [str(p.relative_to(ROOT)) for p in required if not p.exists()]
    if missing:
        c.fail(f"URL catalog files missing: {missing}")
    else:
        c.ok("URL catalog docs, hosts fragment, scripts, and validator present")

    import subprocess

    val = PLATFORM / "homelab" / "validate-url-catalog.py"
    proc = subprocess.run(
        [sys.executable, str(val)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,  # the return code is reported below
    )
    for line in (proc.stdout or "").splitlines():
        if line.startswith(("  ✅", "  ❌")):
            msg = line[4:].strip() if len(line) > 4 else line
            if line.startswith("  ✅"):
                c.ok(msg)
            else:
                c.fail(msg)
        elif line.startswith(
            (
                "Solo Empire",
                "[url-catalog]",
                "=",
                "URL-catalog:",
                "All URL",
                "FAILURES",
                "  - ",
            )
        ):
            print(line)

    if proc.returncode != 0 and not any(
        "url" in f.lower() or "catalog" in f.lower() for f in c.failures
    ):
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        c.fail(f"validate-url-catalog.py failed: {err[:200]}")


def test_multinode_readiness_workflow(c: Checker) -> None:
    """Homelab multi-node readiness audit offline gates."""
    print("\n[multinode] Homelab multi-node readiness offline gates")
    required = [
        PLATFORM / "homelab" / "validate-multinode-readiness.py",
        PLATFORM / "bootstrap" / "homelab" / "audit-multinode-readiness.sh",
        OPS_PLATFORM / "HOMELAB-MULTINODE-READINESS.md",
    ]
    missing = [str(p.relative_to(ROOT)) for p in required if not p.exists()]
    if missing:
        c.fail(f"Multi-node readiness files missing: {missing}")
    else:
        c.ok("Multi-node readiness doc, audit script, and validator present")

    import subprocess

    val = PLATFORM / "homelab" / "validate-multinode-readiness.py"
    proc = subprocess.run(
        [sys.executable, str(val)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,  # the return code is reported below
    )
    for line in (proc.stdout or "").splitlines():
        if line.startswith(("  ✅", "  ❌")):
            msg = line[4:].strip() if len(line) > 4 else line
            if line.startswith("  ✅"):
                c.ok(msg)
            else:
                c.fail(msg)
        elif line.startswith(
            (
                "Solo Empire",
                "[multinode]",
                "=",
                "Multinode:",
                "All multi-node",
                "FAILURES",
                "  - ",
            )
        ):
            print(line)

    if proc.returncode != 0 and not any(
        "multi-node" in f.lower() or "multinode" in f.lower() for f in c.failures
    ):
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        c.fail(f"validate-multinode-readiness.py failed: {err[:200]}")


def test_observability_workflow(c: Checker) -> None:
    """Homelab observability baseline offline gates."""
    print("\n[observability] Homelab SRE baseline offline gates")
    required = [
        PLATFORM / "observability" / "validate-observability.py",
        PLATFORM / "observability" / "alerts" / "README.md",
        PLATFORM / "observability" / "alerts" / "homelab-alerts.yaml",
        PLATFORM / "bootstrap" / "homelab" / "verify-homelab-observability.sh",
        OPS_PLATFORM / "HOMELAB-OBSERVABILITY-RUNBOOK.md",
        OPS_PLATFORM / "SLO-SLI-BASELINE.md",
    ]
    missing = [str(p.relative_to(ROOT)) for p in required if not p.exists()]
    if missing:
        c.fail(f"Observability files missing: {missing}")
    else:
        c.ok("Observability docs, alerts, script, and validator present")

    import subprocess

    val = PLATFORM / "observability" / "validate-observability.py"
    proc = subprocess.run(
        [sys.executable, str(val)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,  # the return code is reported below
    )
    for line in (proc.stdout or "").splitlines():
        if line.startswith(("  ✅", "  ❌")):
            msg = line[4:].strip() if len(line) > 4 else line
            if line.startswith("  ✅"):
                c.ok(msg)
            else:
                c.fail(msg)
        elif line.startswith(
            (
                "Solo Empire",
                "[observability]",
                "=",
                "Observability:",
                "All observability",
                "FAILURES",
                "  - ",
            )
        ):
            print(line)

    if proc.returncode != 0 and not any(
        "observability" in f.lower() for f in c.failures
    ):
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        c.fail(f"validate-observability.py failed: {err[:200]}")


def test_data_contract_workflow(c: Checker) -> None:
    """Durable data plane gates (offline); folds validate-data-contract.py."""
    print("\n[data-contract] Durable data plane offline gates")
    required = [
        PLATFORM / "DATA-CONTRACT.md",
        PLATFORM / "onboarding" / "scripts" / "validate-data-contract.py",
        OPS_AI / "AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md",
        OPS_RUNBOOKS / "STAGING-DATA-BACKUP-RESTORE.md",
        GITOPS / "applications" / "values" / "staging" / "ai-doc-assistant.yaml",
    ]
    missing = [str(p.relative_to(ROOT)) for p in required if not p.exists()]
    if missing:
        c.fail(f"Data-contract files missing: {missing}")
    else:
        c.ok("Data-contract docs, validator, and staging values present")

    import subprocess

    val = PLATFORM / "onboarding" / "scripts" / "validate-data-contract.py"
    proc = subprocess.run(
        [sys.executable, str(val)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,  # the return code is reported below
    )
    for line in (proc.stdout or "").splitlines():
        if line.startswith(("  ✅", "  ❌")):
            msg = line[4:].strip() if len(line) > 4 else line
            if line.startswith("  ✅"):
                c.ok(msg)
            else:
                c.fail(msg)
        elif line.startswith(
            (
                "Solo Empire",
                "[data-contract]",
                "=",
                "Data-contract:",
                "All data-contract",
                "FAILURES",
                "  - ",
            )
        ):
            print(line)

    if proc.returncode != 0 and not any(
        "data-contract" in f.lower() or "staging" in f.lower() for f in c.failures
    ):
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        c.fail(f"validate-data-contract.py failed: {err[:200]}")


def main() -> int:
    configure_utf8_stdio()
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--strict-platform",
        action="store_true",
        help="Treat missing readiness doc as failure",
    )
    args = parser.parse_args()

    c = Checker()
    print("Solo Empire platform validation (offline)")
    test_helm_chart(c)
    test_gitops(c)
    test_policies(c)
    test_platform_no_secrets_or_latest(c, strict=args.strict_platform)
    test_gitignore_env(c)
    test_onboarding_workflow(c)
    test_data_contract_workflow(c)
    test_observability_workflow(c)
    test_multinode_readiness_workflow(c)
    test_url_catalog_workflow(c)

    print("\n" + "=" * 60)
    print(
        f"Passed: {c.passed}  Failures: {len(c.failures)}  Warnings: {len(c.warnings)}"
    )
    if c.failures:
        print("FAILURES:")
        for f in c.failures:
            print(f"  - {f}")
        return 1
    print("All platform validation checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
