#!/usr/bin/env python3
"""Emit shell-exportable env vars for deploy-app.sh from a PilotApp definition."""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
ONBOARDING = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

from lib_yaml import load_pilot_app  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("name", help="App name (slug)")
    args = parser.parse_args()

    path = ONBOARDING / "apps" / f"{args.name}.yaml"
    if not path.exists():
        print(f"ERROR: missing app definition {path}", file=sys.stderr)
        return 1

    app = load_pilot_app(path)
    name = app["name"]
    spec = app["spec"]
    if name != args.name:
        print(
            f"ERROR: metadata.name={name!r} does not match filename {args.name!r}",
            file=sys.stderr,
        )
        return 1

    env = {
        "APP_NAME": name,
        "APP_TEAM": str(spec.get("team", "product")),
        "APP_COMPONENT": str(spec.get("component", "web")),
        "APP_MODE": str(spec.get("mode", "web")),
        "APP_SOURCE_PATH": str(spec.get("source_path", "")),
        "APP_IMAGE_NAME": str(spec.get("image_name", f"solo-empire/{name}")),
        "APP_DATA_CONTRACT": str(spec.get("data_contract", "")),
        "APP_TARGET_PORT": str(spec.get("target_port", 8080)),
        "APP_INGRESS_HOSTNAME": str(
            spec.get("ingress_hostname", f"{name}.dev.local")
        ),
        "APP_NS": f"apps-{name}-dev",
        "APP_ARGO": f"{name}-dev",
        "APP_RUNBOOK": str(spec.get("runbook", "")),
        "APP_RUN_AS_USER": str(spec.get("run_as_user", "")),
        "APP_LIVENESS": str((spec.get("probes") or {}).get("liveness", "/healthz")),
        "APP_READINESS": str((spec.get("probes") or {}).get("readiness", "/readyz")),
    }
    for k, v in env.items():
        print(f"export {k}={shlex.quote(v)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
