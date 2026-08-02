#!/usr/bin/env python3
"""
Offline validation for Solo Empire application data contracts.

Design/validation only — no cluster, no cloud apply, no secret values.

Checks:
  - Required data_contract fields on inventory + staging gates for ai-doc-assistant
  - Staging values reject emptyDir for durable chroma/uploads
  - Staging requires ExternalSecret refs and vector/object-storage intent
  - No hardcoded credentials in platform data-related paths
  - solo-app chart does not create DB/vector/object-storage sidecars
  - Backup retention and restore documentation exist
  - Homelab remains DEMO_ONLY (ephemeral contract markers)
  - No :latest image tags; deploymentEnabled false by default on staging
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
GITOPS = PLATFORM / "gitops" / "applications"
VALUES_STAGING = GITOPS / "values" / "staging"
HELM = PLATFORM / "helm" / "solo-app"
DOCS_OPS = ROOT / "docs" / "operations"
INVENTORY = PLATFORM / "APP-INVENTORY.yaml"
DATA_CONTRACT_DOC = PLATFORM / "DATA-CONTRACT.md"
HOMELAB_VALUES = HELM / "homelab" / "ai-doc-assistant.yaml"
STAGING_AI = VALUES_STAGING / "ai-doc-assistant.yaml"

SECRET_PATTERNS = [
    re.compile(r"soloempire2026", re.I),
    re.compile(r"AKIA[0-9A-Z]{16}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"sk-[A-Za-z0-9]{20,}"),
    re.compile(
        r"(api[_-]?key|secret[_-]?key|password|token)\s*[:=]\s*['\"][A-Za-z0-9/+=_\-]{12,}['\"]",
        re.I,
    ),
    re.compile(r"postgres(?:ql)?://[^:]+:[^@]+@", re.I),
]

LATEST_TAG = re.compile(r'(?m)^\s*tag:\s*["\']?latest["\']?\s*$')

# Chart templates must not introduce data plane sidecars
FORBIDDEN_CHART_SUBSTRINGS = (
    "kind: StatefulSet",
    "bitnami/postgresql",
    "bitnami/redis",
    "qdrant/qdrant",
    "minio/minio",
    "chromadb/chroma",
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


def validate_docs(c: Checker) -> None:
    print("\n[data-contract] Required documentation")
    required = {
        "DATA-CONTRACT.md": DATA_CONTRACT_DOC,
        "AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md": DOCS_OPS / "AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md",
        "STAGING-DATA-BACKUP-RESTORE.md": DOCS_OPS / "STAGING-DATA-BACKUP-RESTORE.md",
        "AI-DOC-ASSISTANT-DATA-READINESS.md": DOCS_OPS / "AI-DOC-ASSISTANT-DATA-READINESS.md",
        "PRODUCTION-GAPS.md": DOCS_OPS / "PRODUCTION-GAPS.md",
    }
    for label, path in required.items():
        if path.exists():
            c.ok(f"present: {label}")
        else:
            c.fail(f"missing: {label}")

    restore = _read(DOCS_OPS / "STAGING-DATA-BACKUP-RESTORE.md")
    for needle, label in (
        ("180", "backups lifecycle / retention mention"),
        ("7 days", "PITR retention 7 days"),
        ("30 days", "restore drill cadence"),
        ("pgBackRest", "backup tool named"),
        ("RTO", "RTO documented"),
        ("RPO", "RPO documented"),
        ("MinIO", "MinIO lab-only note"),
        ("object storage", "object storage section"),
        ("vector", "vector restore section"),
    ):
        if needle.lower() in restore.lower():
            c.ok(f"restore doc has {label}")
        else:
            c.fail(f"restore doc missing {label} ({needle!r})")

    plan = _read(DOCS_OPS / "AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md")
    for needle in (
        "DEMO_ONLY",
        "PostgreSQL",
        "Qdrant",
        "pgvector",
        "object storage",
        "MinIO",
        "External Secrets",
        "deploymentEnabled",
        "emptyDir",
        "solo-app",
    ):
        if needle.lower() in plan.lower():
            c.ok(f"durable plan mentions {needle}")
        else:
            c.fail(f"durable plan missing {needle}")


def validate_inventory_data_contract(c: Checker) -> None:
    print("\n[data-contract] Inventory data_contract fields")
    text = _read(INVENTORY)
    if not text:
        c.fail("APP-INVENTORY.yaml missing")
        return
    # Approved pilots must declare data_contract
    for app in ("ai-doc-assistant", "booknbook"):
        # crude but stable: block for id then data_contract nearby
        m = re.search(
            rf"(?ms)^  - id: {re.escape(app)}\n.*?(?=^  - id:|\Z)",
            text,
        )
        if not m:
            c.fail(f"inventory missing app {app}")
            continue
        block = m.group(0)
        if re.search(r"(?m)^\s*data_contract:\s*\S+", block):
            dc = re.search(r"(?m)^\s*data_contract:\s*(\S+)", block)
            val = dc.group(1) if dc else ""
            if val.lower() in {"", "pending", "tbd", "null", "none"} and app in (
                "ai-doc-assistant",
                "booknbook",
            ):
                c.fail(f"inventory {app}: data_contract not explicit ({val!r})")
            else:
                c.ok(f"inventory {app}: data_contract={val}")
        else:
            c.fail(f"inventory {app}: data_contract field required")


def validate_homelab_demo_only(c: Checker) -> None:
    print("\n[data-contract] Homelab DEMO_ONLY markers")
    text = _read(HOMELAB_VALUES)
    if not text:
        c.fail("homelab ai-doc-assistant values missing")
        return
    for needle in (
        "SOLO_DATA_CONTRACT: demo-ephemeral",
        "SOLO_DATA_DURABILITY: ephemeral",
        "SOLO_VECTOR_STORE: chroma-emptyDir",
        "SOLO_OBJECT_STORAGE: none",
    ):
        if needle in text:
            c.ok(f"homelab has {needle}")
        else:
            c.fail(f"homelab missing {needle}")
    if re.search(r"(?m)^\s*-\s*name:\s*chroma\s*$", text) and "emptyDir" in text:
        c.ok("homelab still declares chroma emptyDir (demo honesty)")
    else:
        c.fail("homelab must keep chroma emptyDir for DEMO_ONLY")
    if "persistentVolumeClaim" in text:
        c.fail("homelab must not claim PVC durability")
    else:
        c.ok("homelab has no PVC claims")


def validate_staging_ai_doc(c: Checker) -> None:
    print("\n[data-contract] Staging ai-doc-assistant gates")
    text = _read(STAGING_AI)
    if not text:
        c.fail("staging values for ai-doc-assistant missing")
        return

    if re.search(r"(?m)^\s*deploymentEnabled:\s*false\s*$", text):
        c.ok("staging deploymentEnabled=false")
    else:
        c.fail("staging must keep deploymentEnabled: false by default")

    if re.search(r"(?m)^\s*dataContract:\s*staging-durable-planned\s*$", text):
        c.ok("staging dataContract=staging-durable-planned")
    else:
        c.fail("staging dataContract must be staging-durable-planned")

    if re.search(r"(?m)^\s*chromaEmptyDirAllowed:\s*false\s*$", text):
        c.ok("staging chromaEmptyDirAllowed=false")
    else:
        c.fail("staging must set chromaEmptyDirAllowed: false")

    if re.search(r"(?m)^\s*uploadsEmptyDirAllowed:\s*false\s*$", text):
        c.ok("staging uploadsEmptyDirAllowed=false")
    else:
        c.fail("staging must set uploadsEmptyDirAllowed: false")

    if re.search(r"(?m)^\s*minioInClusterAllowed:\s*false\s*$", text):
        c.ok("staging minioInClusterAllowed=false")
    else:
        c.fail("staging must set minioInClusterAllowed: false")

    # Vector + object + postgresql intent
    for key in ("postgresql:", "vectorStore:", "objectStorage:"):
        if key in text:
            c.ok(f"staging declares {key.rstrip(':')}")
        else:
            c.fail(f"staging missing soloEmpire.data.{key.rstrip(':')}")

    # Reject emptyDir for durable volume names
    # Allow only tmp emptyDir
    vol_blocks = re.findall(
        r"(?ms)^\s*-\s*name:\s*(\S+)\s*\n(?:^\s+.+\n)*?",
        text,
    )
    # Simpler: forbid chroma emptyDir and uploads emptyDir patterns
    if re.search(r"(?ms)name:\s*chroma.*?emptyDir:", text):
        c.fail("staging must not define chroma emptyDir volume")
    else:
        c.ok("staging has no chroma emptyDir volume")

    if re.search(r"(?ms)name:\s*uploads.*?emptyDir:", text):
        c.fail("staging must not define uploads emptyDir volume")
    else:
        c.ok("staging has no uploads emptyDir volume")

    if re.search(r"(?m)^\s*-\s*name:\s*tmp\s*$", text) and "emptyDir" in text:
        c.ok("staging allows tmp emptyDir only (disposable)")
    else:
        c.fail("staging should keep disposable tmp emptyDir")

    # External secrets required
    if re.search(r"(?m)^\s*externalSecrets:\s*\n\s+enabled:\s*true", text):
        c.ok("staging externalSecrets.enabled=true")
    else:
        c.fail("staging must enable externalSecrets")

    for prop in (
        "database-url",
        "vector-store-url",
        "s3-bucket",
        "openai-api-key",
    ):
        if prop in text:
            c.ok(f"staging ESO ref property present: {prop}")
        else:
            c.fail(f"staging missing ESO remoteRef property {prop}")

    if LATEST_TAG.search(text):
        c.fail("staging image tag must not be :latest")
    else:
        c.ok("staging image tag is not :latest")

    for pat in SECRET_PATTERNS:
        if pat.search(text):
            c.fail(f"staging values possible secret pattern: {pat.pattern[:40]}")
            return
    c.ok("staging values: no hardcoded secret patterns")


def validate_solo_app_chart_boundary(c: Checker) -> None:
    print("\n[data-contract] solo-app chart has no data-plane sidecars")
    chart_yaml = _read(HELM / "Chart.yaml")
    if re.search(r"(?m)^dependencies:", chart_yaml):
        c.fail("solo-app Chart.yaml must not declare chart dependencies")
    else:
        c.ok("solo-app has no Helm dependencies block")

    templates = HELM / "templates"
    if not templates.is_dir():
        c.fail("solo-app templates missing")
        return

    joined = []
    for path in sorted(templates.rglob("*")):
        if path.is_file() and path.suffix in {".yaml", ".yml", ".tpl", ".txt"}:
            joined.append(_read(path))
    blob = "\n".join(joined)

    for bad in FORBIDDEN_CHART_SUBSTRINGS:
        if bad.lower() in blob.lower():
            c.fail(f"solo-app templates contain forbidden data-plane marker: {bad}")
        else:
            c.ok(f"solo-app free of {bad}")

    # No second container that looks like a DB sidecar (heuristic)
    if re.search(r"(?i)image:.*(?:postgres|redis|qdrant|minio|chroma)", blob):
        c.fail("solo-app templates reference data-plane container images")
    else:
        c.ok("solo-app templates do not reference DB/vector/object images")


def validate_platform_secret_scan(c: Checker) -> None:
    print("\n[data-contract] Secret scan (platform data-related paths)")
    roots = [
        PLATFORM / "gitops" / "applications" / "values" / "staging",
        PLATFORM / "helm" / "solo-app" / "homelab",
        PLATFORM / "DATA-CONTRACT.md",
        DOCS_OPS / "AI-DOC-ASSISTANT-DURABLE-DATA-PLAN.md",
        DOCS_OPS / "STAGING-DATA-BACKUP-RESTORE.md",
    ]
    hits: list[str] = []
    for root in roots:
        if root.is_file():
            paths = [root]
        elif root.is_dir():
            paths = [p for p in root.rglob("*") if p.is_file() and p.suffix in {".yaml", ".yml", ".md"}]
        else:
            continue
        for path in paths:
            text = _read(path)
            for pat in SECRET_PATTERNS:
                if pat.search(text):
                    hits.append(f"{path.relative_to(ROOT)}: {pat.pattern[:40]}")
    if hits:
        for h in hits[:10]:
            c.fail(f"possible secret: {h}")
    else:
        c.ok("no secret patterns in staging values / data docs / homelab values")


def validate_data_contract_doc_fields(c: Checker) -> None:
    print("\n[data-contract] DATA-CONTRACT.md required topics")
    text = _read(DATA_CONTRACT_DOC)
    for topic in (
        "DEMO_ONLY",
        "staging-durable-planned",
        "emptyDir",
        "External Secrets",
        "solo-app",
        "MinIO",
        "PostgreSQL",
        "vector",
        "object storage",
    ):
        if topic.lower() in text.lower():
            c.ok(f"DATA-CONTRACT covers {topic}")
        else:
            c.fail(f"DATA-CONTRACT missing topic {topic}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    c = Checker()
    print("Solo Empire data-contract validation (offline)")
    print("=" * 60)
    validate_docs(c)
    validate_data_contract_doc_fields(c)
    validate_inventory_data_contract(c)
    validate_homelab_demo_only(c)
    validate_staging_ai_doc(c)
    validate_solo_app_chart_boundary(c)
    validate_platform_secret_scan(c)
    print("=" * 60)
    print(f"Data-contract: Passed={c.passed}  Failures={len(c.failures)}")
    if c.failures:
        print("FAILURES:")
        for f in c.failures:
            print(f"  - {f}")
        return 1
    print("All data-contract validation checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
