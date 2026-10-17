#!/usr/bin/env python3
"""
Offline validation for Homelab URL catalog and DNS helpers.
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

DOCS = ROOT / "operations" / "platform"
BOOT = ROOT / "infra" / "platform" / "bootstrap" / "homelab"

CATALOG = DOCS / "HOMELAB-URL-CATALOG.md"
FRAGMENT = BOOT / "hosts.homelab.fragment"
SYNC = BOOT / "sync-homelab-dns.sh"
VERIFY = BOOT / "verify-homelab-urls.sh"
ARGO_DESIGN = (
    ROOT
    / "infra"
    / "platform"
    / "gitops"
    / "homelab"
    / "design"
    / "argocd-private-ingress.design.md"
)

REQUIRED_URLS = [
    "http://ai-doc-assistant.homelab.local",
    "http://booknbook.homelab.local",
    "http://platform-smoke.local",
    "registry.homelab.local",
]

REQUIRED_HOSTS = [
    "ai-doc-assistant.homelab.local",
    "booknbook.homelab.local",
    "platform-smoke.local",
    "registry.homelab.local",
]

MUTATING = re.compile(
    r"(?i)(^|[;&|`$(\s])kubectl\s+(apply|delete|scale|patch|replace|edit)\b"
)
SECRET_PAT = re.compile(
    r"(?i)(password|api[_-]?key|secret[_-]?key)\s*[:=]\s*['\"][^$'\"]{8,}|"
    r"sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|BEGIN (RSA |OPENSSH )?PRIVATE KEY"
)
PUBLIC_IP = re.compile(
    r"(?i)\b(?!192\.168\.|10\.|127\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)"
    r"(?:\d{1,3}\.){3}\d{1,3}\b"
)


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


def validate_files(c: Checker) -> None:
    print("\n[url-catalog] Required files")
    for path, label in (
        (CATALOG, "HOMELAB-URL-CATALOG.md"),
        (FRAGMENT, "hosts.homelab.fragment"),
        (SYNC, "sync-homelab-dns.sh"),
        (VERIFY, "verify-homelab-urls.sh"),
        (ARGO_DESIGN, "argocd-private-ingress.design.md"),
    ):
        if path.exists():
            c.ok(f"present: {label}")
        else:
            c.fail(f"missing: {label}")

    for script in (SYNC, VERIFY):
        if not script.exists():
            continue
        try:
            executable = has_executable_bit(script, ROOT)
        except FileModeError:
            c.fail(f"could not verify executable mode: {script.name}")
            continue
        if executable:
            c.ok(f"executable: {script.name}")
        else:
            c.fail(f"not executable: {script.name}")


def validate_catalog(c: Checker) -> None:
    print("\n[url-catalog] Catalog content")
    text = _read(CATALOG)
    for url in REQUIRED_URLS:
        if url in text:
            c.ok(f"catalog has {url}")
        else:
            c.fail(f"catalog missing {url}")

    for term in (
        "192.168.152.114",
        "192.168.152.12",
        "port-forward",
        "kubectl",
        "Kyverno",
        "metrics-server",
        "External Secrets",
        "cert-manager",
        "Docker Compose",
        "127.0.0.1",
        "private LAN",
        "argocd",
    ):
        if term.lower() in text.lower():
            c.ok(f"catalog mentions {term}")
        else:
            c.fail(f"catalog missing {term}")

    # Homelab URLs must not be documented as 127.0.0.1
    for host in (
        "ai-doc-assistant.homelab.local",
        "booknbook.homelab.local",
        "platform-smoke.local",
        "registry.homelab.local",
    ):
        # bad pattern: 127.0.0.1 host
        if re.search(rf"127\.0\.0\.1\s+{re.escape(host)}", text):
            c.fail(f"catalog maps {host} to 127.0.0.1")
        else:
            c.ok(f"catalog does not map {host} to loopback")

    # Docker lab grafana should not point at homelab node in catalog claims
    if re.search(r"192\.168\.152\.114\s+grafana\.local", text):
        c.fail("catalog maps Docker Lab grafana.local to Homelab IP")
    else:
        c.ok("no Docker Lab hostname mapped to Homelab IP in catalog")

    # Fail only on affirmative public-DNS requirements, not "no public DNS" prose.
    if re.search(
        r"(?i)(require[sd]?|use|enable|configure)\s+public\s+DNS|Route53|Cloudflare DNS for homelab",
        text,
    ):
        c.fail("catalog claims public DNS")
    else:
        c.ok("no public DNS claim")


def validate_fragment(c: Checker) -> None:
    print("\n[url-catalog] hosts.homelab.fragment")
    text = _read(FRAGMENT)
    if "# BEGIN Solo Empire Homelab" in text and "# END Solo Empire Homelab" in text:
        c.ok("fragment has Homelab markers")
    else:
        c.fail("fragment missing BEGIN/END markers")

    for host, ip in (
        ("ai-doc-assistant.homelab.local", "192.168.152.114"),
        ("booknbook.homelab.local", "192.168.152.114"),
        ("platform-smoke.local", "192.168.152.114"),
        ("registry.homelab.local", "192.168.152.12"),
    ):
        if re.search(rf"^{re.escape(ip)}\s+{re.escape(host)}\s*$", text, re.MULTILINE):
            c.ok(f"fragment {ip} {host}")
        else:
            c.fail(f"fragment missing {ip} {host}")

    if re.search(r"(?m)^127\.0\.0\.1\s+\S+", text):
        c.fail("fragment must not map hosts to 127.0.0.1")
    else:
        c.ok("fragment has no loopback host mappings")


def validate_scripts(c: Checker) -> None:
    print("\n[url-catalog] Script safety")
    for path in (SYNC, VERIFY):
        text = _read(path)
        if not text:
            continue
        if "DRY_RUN" in text or path == VERIFY:
            c.ok(f"{path.name}: dry-run or read-only path")
        if path == SYNC and "BEGIN Solo Empire Homelab" in text:
            c.ok("sync manages Homelab marker only")
        if path == SYNC and "BEGIN Solo Empire Services" in text:
            # should mention not touching lab block
            if "must not" in text.lower() or "Never" in text or "never" in text:
                c.ok("sync documents not touching Compose Lab block")
            else:
                c.fail("sync should refuse/avoid Compose Lab block")
        for i, line in enumerate(text.splitlines(), 1):
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            if MUTATING.search(s):
                c.fail(f"{path.name}:{i} mutating kubectl: {s[:80]}")
                return
        c.ok(f"{path.name}: no kubectl apply/delete/patch/scale")
        if SECRET_PAT.search(text):
            c.fail(f"{path.name}: possible secret")
        else:
            c.ok(f"{path.name}: no secret patterns")

    verify = _read(VERIFY)
    for host in REQUIRED_HOSTS:
        if host in verify:
            c.ok(f"verify script mentions {host}")
        else:
            c.fail(f"verify script missing {host}")


def validate_controller_docs(c: Checker) -> None:
    print("\n[url-catalog] Controller access docs")
    for path in (
        DOCS / "HOMELAB-K3S-RUNBOOK.md",
        DOCS / "HOMELAB-PLATFORM-OPERATIONS.md",
        DOCS / "PLATFORM-STATUS.md",
        CATALOG,
    ):
        text = _read(path)
        if not text:
            c.fail(f"missing {path.name}")
            continue
        if (
            "port-forward" in text
            or "URL catalog" in text
            or "HOMELAB-URL-CATALOG" in text
        ):
            c.ok(f"{path.name} references URL/port-forward guidance")
        else:
            c.fail(f"{path.name} should document controller/URL access")

    design = _read(ARGO_DESIGN)
    if re.search(r"(?i)design-only|do not apply", design):
        c.ok("Argo private ingress marked design-only")
    else:
        c.fail("Argo design must be design-only")


def main() -> int:
    configure_utf8_stdio()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    c = Checker()
    print("Solo Empire Homelab URL catalog validation (offline)")
    print("=" * 60)
    validate_files(c)
    validate_catalog(c)
    validate_fragment(c)
    validate_scripts(c)
    validate_controller_docs(c)
    print("=" * 60)
    print(f"URL-catalog: Passed={c.passed}  Failures={len(c.failures)}")
    if c.failures:
        print("FAILURES:")
        for f in c.failures:
            print(f"  - {f}")
        return 1
    print("All URL catalog validation checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
