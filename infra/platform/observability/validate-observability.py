#!/usr/bin/env python3
"""
Offline validation for Homelab observability / SRE baseline.

No cluster access required. Ensures docs, scripts, and design-only alerts
stay within safety boundaries (read-only scripts, no cloud apply, no secrets).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "infra" / "platform"))
sys.path.insert(0, str(ROOT / "infra" / "scripts" / "platform"))
from platform_output import configure_utf8_stdio  # noqa: E402
from git_file_mode import FileModeError, has_executable_bit  # noqa: E402

OBS = ROOT / "infra" / "platform" / "observability"
BOOT = ROOT / "infra" / "platform" / "bootstrap" / "homelab"
DOCS = ROOT / "operations" / "platform"

SCRIPT = BOOT / "verify-homelab-observability.sh"
RUNBOOK = DOCS / "HOMELAB-OBSERVABILITY-RUNBOOK.md"
SLO = DOCS / "SLO-SLI-BASELINE.md"
ALERTS_README = OBS / "alerts" / "README.md"
ALERTS_YAML = OBS / "alerts" / "homelab-alerts.yaml"

MUTATING = re.compile(
    r"\b(kubectl\s+(apply|delete|scale|patch|replace|create|rollout\s+restart|edit|drain|cordon|taint)|"
    r"helm\s+(install|upgrade|uninstall)|"
    r"tofu\s+apply|terraform\s+apply|"
    r"argocd\s+app\s+(sync|delete|set)|"
    r"docker\s+compose\s+.*\b(up\s+-d|down)\b)",
    re.IGNORECASE,
)

# Allowed mentions of apply in comments about "do not apply"
SECRET_PAT = re.compile(
    r"(password|api[_-]?key|secret[_-]?key)\s*[:=]\s*['\"][^$'\"]{8,}|"
    r"sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}",
    re.IGNORECASE,
)
# Match real image refs only (not prose that mentions the word ":latest").
LATEST = re.compile(r"(?i)(?:image|repository)\s*:\s*['\"]?[A-Za-z0-9._\-./]+:latest\b")


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


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8") if path.exists() else ""


def validate_docs(c: Checker) -> None:
    print("\n[observability] Required documentation")
    for path, label in (
        (RUNBOOK, "HOMELAB-OBSERVABILITY-RUNBOOK.md"),
        (SLO, "SLO-SLI-BASELINE.md"),
        (ALERTS_README, "alerts/README.md"),
        (ALERTS_YAML, "alerts/homelab-alerts.yaml"),
        (SCRIPT, "verify-homelab-observability.sh"),
    ):
        if path.exists():
            c.ok(f"present: {label}")
        else:
            c.fail(f"missing: {label}")

    runbook = _read(RUNBOOK)
    for term in (
        "metrics-server",
        "Prometheus",
        "Grafana",
        "SLI",
        "availability",
        "Argo",
        "restart",
        "saturation",
        "NetworkPolicy",
        "incident",
        "escalation",
        "kube-prometheus-stack",
        "DEMO",
    ):
        if term.lower() in runbook.lower():
            c.ok(f"runbook mentions {term}")
        else:
            c.fail(f"runbook missing {term}")

    slo = _read(SLO)
    for term in (
        "SLI",
        "SLO",
        "healthz",
        "readyz",
        "Synced",
        "Healthy",
        "restart",
        "CrashLoopBackOff",
        "ImagePullBackOff",
        "75%",
        "85%",
        "70%",
        "99%",
        "no production SLA",
    ):
        if term.lower() in slo.lower() or term in slo:
            c.ok(f"SLO doc mentions {term}")
        else:
            # flexible for percentage formats
            alt = term.replace("%", "")
            if alt in slo and "%" in slo:
                c.ok(f"SLO doc mentions {term} (flexible)")
            else:
                c.fail(f"SLO doc missing {term}")


def validate_script(c: Checker) -> None:
    print("\n[observability] Verify script safety")
    if not SCRIPT.exists():
        c.fail("verify script missing")
        return
    try:
        executable = has_executable_bit(SCRIPT, ROOT)
    except FileModeError:
        c.fail("could not verify observability script executable mode")
        return
    if executable:
        c.ok("verify script is executable")
    else:
        c.fail("verify script not executable")

    text = _read(SCRIPT)
    if (
        "read-only" in text.lower()
        or "does not mutate" in text.lower()
        or "Read-only" in text
    ):
        c.ok("script documents read-only intent")
    else:
        c.fail("script must document read-only intent")

    # Mutating kubectl/helm/tofu — allow only in comment lines that forbid them
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        if MUTATING.search(line):
            # allow strings in log messages about not doing these?
            if re.search(r"(never|do not|must not|not\s+)", line, re.IGNORECASE):
                continue
            c.fail(f"mutating command in script L{i}: {stripped[:80]}")
            return
    c.ok("no mutating kubectl/helm/tofu apply commands in script body")

    for needle in (
        "K3S_HOST",
        "K3S_USER",
        "kubectl top",
        "metrics-server",
        "Synced",
        "healthz",
    ):
        if needle in text:
            c.ok(f"script contains {needle}")
        else:
            c.fail(f"script missing {needle}")

    if SECRET_PAT.search(text):
        c.fail("possible secret in verify script")
    else:
        c.ok("no secret patterns in verify script")


def validate_alerts(c: Checker) -> None:
    print("\n[observability] Design-only alerts")
    readme = _read(ALERTS_README)
    yaml_text = _read(ALERTS_YAML)
    for blob, name in ((readme, "README"), (yaml_text, "YAML")):
        if re.search(r"design-only|DO NOT APPLY|do not apply", blob, re.IGNORECASE):
            c.ok(f"alerts {name} marked design-only / do-not-apply")
        else:
            c.fail(f"alerts {name} must be marked design-only")

    for alert in (
        "ArgoApplicationDegraded",
        "PodUnavailable",
        "PodRestartIncrease",
        "CrashLoopBackOff",
        "ImagePullBackOff",
        "NodeMemoryPressure",
        "NodeCPUSaturation",
        "IngressHigh5xx",
        "CertificateExpirySoon",
    ):
        if alert in yaml_text:
            c.ok(f"alert defined: {alert}")
        else:
            c.fail(f"alert missing: {alert}")

    if LATEST.search(yaml_text) or LATEST.search(readme):
        c.fail(":latest image reference in alerts")
    else:
        c.ok("no :latest in alert files")

    if SECRET_PAT.search(yaml_text) or SECRET_PAT.search(readme):
        c.fail("possible secret in alert files")
    else:
        c.ok("no secret patterns in alert files")


def validate_platform_refs(c: Checker) -> None:
    print("\n[observability] Platform status / services alignment")
    status = _read(DOCS / "PLATFORM-STATUS.md")
    gaps = _read(DOCS / "PRODUCTION-GAPS.md")
    services = _read(ROOT / "infra" / "platform" / "PLATFORM-SERVICES.yaml")
    if "metrics-server" in status.lower():
        c.ok("PLATFORM-STATUS mentions metrics-server")
    else:
        c.fail("PLATFORM-STATUS should mention metrics-server")
    if "observability" in status.lower() or "SLO" in status:
        c.ok("PLATFORM-STATUS mentions observability/SLO")
    else:
        # soft: will update PLATFORM-STATUS in same change set
        c.fail("PLATFORM-STATUS should mention observability baseline")
    if "metrics-server" in gaps.lower() or "Observability" in gaps:
        c.ok("PRODUCTION-GAPS still tracks observability gap")
    else:
        c.fail("PRODUCTION-GAPS observability section missing")
    if "prometheus" in services.lower() and "grafana" in services.lower():
        c.ok("PLATFORM-SERVICES lists Compose observability inventory")
    else:
        c.fail("PLATFORM-SERVICES should list prometheus/grafana inventory")


def main() -> int:
    configure_utf8_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    c = Checker()
    print("Solo Empire observability validation (offline)")
    print("=" * 60)
    validate_docs(c)
    validate_script(c)
    validate_alerts(c)
    validate_platform_refs(c)
    print("=" * 60)
    print(f"Observability: Passed={c.passed}  Failures={len(c.failures)}")
    if c.failures:
        print("FAILURES:")
        for f in c.failures:
            print(f"  - {f}")
        return 1
    print("All observability validation checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
