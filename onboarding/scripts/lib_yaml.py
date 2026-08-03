"""Minimal YAML load/dump helpers for onboarding scripts (stdlib + PyYAML if present)."""

from __future__ import annotations

from pathlib import Path
from typing import Any


def load_yaml(path: Path) -> Any:
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        return yaml.safe_load(text)
    except ImportError:
        pass
    # Fallback: only support our small PilotApp shape via a tiny parser is risky;
    # require PyYAML or use json-compatible subset. Prefer pyyaml from infra env.
    raise SystemExit(
        f"PyYAML is required to parse {path}. "
        "Install with: python3 -m pip install pyyaml  (or use infra venv)"
    )


def dump_yaml(data: Any) -> str:
    try:
        import yaml  # type: ignore

        return yaml.safe_dump(data, sort_keys=False, default_flow_style=False)
    except ImportError:
        raise SystemExit("PyYAML is required to dump YAML")


def load_pilot_app(path: Path) -> dict[str, Any]:
    data = load_yaml(path)
    if not isinstance(data, dict):
        raise SystemExit(f"Invalid pilot app file: {path}")
    name = (data.get("metadata") or {}).get("name")
    spec = data.get("spec") or {}
    if not name or not isinstance(spec, dict):
        raise SystemExit(f"Pilot app missing metadata.name/spec: {path}")
    return {"name": name, "spec": spec, "raw": data, "path": path}
