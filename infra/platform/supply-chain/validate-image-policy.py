#!/usr/bin/env python3
"""Offline guard for Kubernetes image supply-chain policy.

This validates repository intent only. It does not contact a registry, sign an
image, print credentials, or change a cluster.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PLATFORM = ROOT / "infra" / "platform"
GITOPS = PLATFORM / "gitops"
SUPPLY_CHAIN = PLATFORM / "supply-chain"

PASS = 0
FAIL = 0


def check(condition: bool, message: str) -> None:
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ✅ {message}")
    else:
        FAIL += 1
        print(f"  ❌ {message}")


def deployable_text() -> str:
    """Read only deployable pilot/staging image values, not prose/examples."""
    paths = [
        PLATFORM / "gitops" / "applications" / "catalog" / "apps.yaml",
        PLATFORM
        / "gitops"
        / "applications"
        / "values"
        / "dev"
        / "ai-doc-assistant.yaml",
        PLATFORM / "gitops" / "applications" / "values" / "dev" / "booknbook.yaml",
        PLATFORM
        / "gitops"
        / "applications"
        / "values"
        / "staging"
        / "ai-doc-assistant.yaml",
        PLATFORM / "gitops" / "applications" / "values" / "staging" / "booknbook.yaml",
        PLATFORM / "helm" / "solo-app" / "homelab" / "ai-doc-assistant.yaml",
        PLATFORM / "helm" / "solo-app" / "homelab" / "booknbook.yaml",
        PLATFORM / "helm" / "solo-app" / "pilot" / "ai-doc-assistant-dev.yaml",
        PLATFORM / "helm" / "solo-app" / "pilot" / "booknbook-dev.yaml",
    ]
    chunks: list[str] = []
    for path in paths:
        if path.exists():
            chunks.append(path.read_text(encoding="utf-8", errors="replace"))
    return "\n".join(chunks)


def main() -> int:
    print("Solo Empire supply-chain policy validation (offline)")
    print("=" * 60)

    contract = SUPPLY_CHAIN / "README.md"
    policy = PLATFORM / "policies" / "kyverno" / "image-provenance-placeholder.yaml"
    check(contract.exists(), "supply-chain contract exists")
    check(policy.exists(), "Kyverno provenance placeholder exists")

    text = deployable_text()
    latest = re.findall(
        r"(?i)(?:^|[\s\"'])[^\s\"']+:latest(?:$|[\s\"'])", text, re.MULTILINE
    )
    check(not latest, "no :latest image reference in platform files")

    secret_patterns = (
        r"soloempire2026",
        r"AKIA[0-9A-Z]{16}",
        r"ghp_[A-Za-z0-9]{20,}",
        r"sk-[A-Za-z0-9]{20,}",
        r"(?i)(?:password|secret|token|api[_-]?key)\s*[:=]\s*['\"][A-Za-z0-9/+=_-]{12,}['\"]",
    )
    check(
        not any(re.search(pattern, text) for pattern in secret_patterns),
        "no hardcoded secret-like values in platform files",
    )

    image_tags = re.findall(r"(?m)^\s*tag:\s*[\"']?([^\"'\s#]+)", text)
    allowed = [
        tag
        for tag in image_tags
        if tag == "git-pending" or re.fullmatch(r"git-[0-9a-f]{7,64}", tag)
    ]
    check(bool(image_tags), "platform image tag fields are discoverable")
    check(
        len(allowed) == len(image_tags),
        "all platform image tags are Git-SHA or explicit pending placeholders",
    )

    staging = GITOPS / "applications" / "values" / "staging" / "ai-doc-assistant.yaml"
    staging_text = staging.read_text(encoding="utf-8") if staging.exists() else ""
    check(
        "deploymentEnabled: false" in staging_text,
        "staging deployment remains disabled",
    )
    check(
        "dataContract: staging-durable-planned" in staging_text,
        "staging data contract is planned, not live",
    )

    policy_text = policy.read_text(encoding="utf-8") if policy.exists() else ""
    check(
        "disabled-placeholder" in policy_text,
        "signature enforcement is honestly marked placeholder",
    )
    check(
        "rules: []" in policy_text,
        "signature verification is not falsely enforced in Homelab",
    )

    print("=" * 60)
    print(f"Supply-chain policy: Passed={PASS} Failures={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
