#!/usr/bin/env python3
"""
Offline validation for Homelab multi-node readiness audit assets.

Ensures docs/scripts stay read-only (no join/install/apply) and topology
is not falsely marked multi-node live.
"""

from __future__ import annotations

import argparse
import re
import stat
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DOCS = ROOT / "operations" / "platform"
BOOT = ROOT / "infra" / "platform" / "bootstrap" / "homelab"

DOC = DOCS / "HOMELAB-MULTINODE-READINESS.md"
INVENTORY = DOCS / "HOMELAB-INVENTORY.md"
K3S_RUNBOOK = DOCS / "HOMELAB-K3S-RUNBOOK.md"
STATUS = DOCS / "PLATFORM-STATUS.md"
SCRIPT = BOOT / "audit-multinode-readiness.sh"

# Match executable-looking usage, not prose ("K3s agent workloads").
FORBIDDEN_EXEC = re.compile(
    r"(?i)(^|[;&|`$(\s])("
    r"k3s\s+(agent|server)(\s|$)|"
    r"k3sup\s+install|"
    r"kubectl\s+(apply|delete|scale|patch|replace|drain|cordon)\b|"
    r"helm\s+(install|upgrade|uninstall)\b|"
    r"tofu\s+apply|terraform\s+apply|"
    r"qm\s+(create|destroy|stop|start)\b|"
    r"pct\s+(create|destroy)\b|"
    r"docker\s+system\s+prune|"
    r"reboot(\s|$)|"
    r"shutdown\s+-|"
    r"iptables\s+-[AI]|"
    r"nft\s+add\b"
    r")"
)

SECRET_PAT = re.compile(
    r"(?i)(password|api[_-]?key|secret[_-]?key|private[_-]?key)\s*[:=]\s*['\"][^$'\"]{8,}|"
    r"sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|"
    r"BEGIN (RSA |OPENSSH )?PRIVATE KEY"
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
    print("\n[multinode] Required documentation")
    for path, label in (
        (DOC, "HOMELAB-MULTINODE-READINESS.md"),
        (INVENTORY, "HOMELAB-INVENTORY.md"),
        (K3S_RUNBOOK, "HOMELAB-K3S-RUNBOOK.md"),
        (STATUS, "PLATFORM-STATUS.md"),
        (SCRIPT, "audit-multinode-readiness.sh"),
    ):
        if path.exists():
            c.ok(f"present: {label}")
        else:
            c.fail(f"missing: {label}")

    text = _read(DOC)
    for term in (
        "192.168.152.114",
        "192.168.152.12",
        "control-plane",
        "registry",
        "worker",
        "Proxmox",
        "6443",
        "10250",
        "8472",
        "5000",
        "single-node",
        "readiness audit",
        "no node has joined",
        "Proxmox cluster quorum",
        "K3s cluster quorum",
        "application worker capacity",
        "decision gate",
        "rollback",
        "Flannel",
    ):
        if term.lower() in text.lower():
            c.ok(f"readiness doc mentions {term}")
        else:
            c.fail(f"readiness doc missing {term}")

    # No public registry requirement
    if re.search(r"(?i)public registry required|must expose registry to internet", text):
        c.fail("doc must not require public registry")
    else:
        c.ok("no public registry requirement")

    if re.search(r"(?i)multi-node\s+is\s+live|workers?\s+joined|HA\s+cluster\s+is\s+live", text):
        c.fail("doc falsely marks multi-node/HA as live")
    else:
        c.ok("doc does not claim multi-node live / HA live")

    if re.search(r"(?i)single-node", text):
        c.ok("current topology marked single-node")
    else:
        c.fail("doc must mark current topology single-node")


def validate_script(c: Checker) -> None:
    print("\n[multinode] Audit script safety")
    if not SCRIPT.exists():
        c.fail("audit script missing")
        return
    mode = SCRIPT.stat().st_mode
    if mode & stat.S_IXUSR:
        c.ok("audit script executable")
    else:
        c.fail("audit script not executable")

    text = _read(SCRIPT)
    if "READ-ONLY" in text or "read-only" in text.lower():
        c.ok("script documents read-only")
    else:
        c.fail("script must say read-only")

    for needle in (
        "K3S_HOST",
        "K3S_USER",
        "FEDORA_HOST",
        "PROXMOX_HOSTS",
        "SSH_CONNECT_TIMEOUT",
        "PASS",
        "WARN",
        "BLOCKED",
        "SKIP",
    ):
        if needle in text:
            c.ok(f"script supports/emits {needle}")
        else:
            c.fail(f"script missing {needle}")

    # Forbidden mutating/join commands in executable lines (not comments)
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # allow strings in log messages that mention forbidden words as "no X"
        if re.search(r"(?i)(no |never |not |must not |do not ).*(k3s agent|kubectl apply|tofu apply)", stripped):
            continue
        if FORBIDDEN_EXEC.search(stripped):
            # allow kubectl get / top only — pattern excludes get
            c.fail(f"forbidden command pattern in script L{i}: {stripped[:100]}")
            return
    c.ok("no k3s agent/server install, k3sup, apply, tofu apply, or destructive cmds")

    if SECRET_PAT.search(text):
        c.fail("possible secret material in audit script")
    else:
        c.ok("no secret patterns in audit script")


def validate_doc_secrets_and_updates(c: Checker) -> None:
    print("\n[multinode] Secrets + inventory/status alignment")
    for path in (DOC, INVENTORY, K3S_RUNBOOK, STATUS, SCRIPT):
        text = _read(path)
        if not text:
            continue
        if SECRET_PAT.search(text):
            c.fail(f"possible secret in {path.relative_to(ROOT)}")
        else:
            c.ok(f"no secret patterns: {path.name}")

    inv = _read(INVENTORY)
    status = _read(STATUS)
    k3s = _read(K3S_RUNBOOK)
    for blob, name in ((inv, "INVENTORY"), (status, "PLATFORM-STATUS"), (k3s, "K3S-RUNBOOK")):
        if re.search(r"(?i)multi-node|readiness.audit|single-node", blob):
            c.ok(f"{name} references multi-node readiness or single-node state")
        else:
            c.fail(f"{name} should mention multi-node readiness audit or single-node")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    c = Checker()
    print("Solo Empire multi-node readiness validation (offline)")
    print("=" * 60)
    validate_docs(c)
    validate_script(c)
    validate_doc_secrets_and_updates(c)
    print("=" * 60)
    print(f"Multinode: Passed={c.passed}  Failures={len(c.failures)}")
    if c.failures:
        print("FAILURES:")
        for f in c.failures:
            print(f"  - {f}")
        return 1
    print("All multi-node readiness validation checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
