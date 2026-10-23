#!/usr/bin/env python3
"""Offline tests for the onboarding helpers: lib_yaml.load_pilot_app and app_env.py.

app_env.py feeds `eval` in deploy-app.sh, so its output must be valid, quoted shell and it
must refuse app files whose metadata.name does not match the requested name.
"""

from __future__ import annotations

import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

INFRA_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = INFRA_ROOT / "platform" / "onboarding" / "scripts"
sys.path.insert(0, str(SCRIPTS))

from lib_yaml import load_pilot_app  # noqa: E402

APP_ENV = SCRIPTS / "app_env.py"


def run_app_env(name: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(APP_ENV), name],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )


def parse_exports(stdout: str) -> dict[str, str]:
    env: dict[str, str] = {}
    for line in stdout.splitlines():
        words = shlex.split(line)
        assert words[0] == "export" and len(words) == 2, line
        key, _, value = words[1].partition("=")
        env[key] = value
    return env


class LoadPilotAppTest(unittest.TestCase):
    def write(self, text: str) -> Path:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = Path(tmp.name) / "app.yaml"
        path.write_text(text, encoding="utf-8")
        return path

    def test_valid_app(self) -> None:
        path = self.write("metadata:\n  name: demo\nspec:\n  team: data\n")
        app = load_pilot_app(path)
        self.assertEqual(app["name"], "demo")
        self.assertEqual(app["spec"], {"team": "data"})
        self.assertEqual(app["path"], path)

    def test_rejects_missing_name_bad_spec_and_non_mapping(self) -> None:
        for text in (
            "spec:\n  team: data\n",
            "metadata:\n  name: demo\nspec: [1, 2]\n",
            "- just\n- a list\n",
        ):
            with self.subTest(text=text), self.assertRaises(SystemExit):
                load_pilot_app(self.write(text))


class AppEnvTest(unittest.TestCase):
    def test_real_pilot_app_exports(self) -> None:
        result = run_app_env("booknbook")
        self.assertEqual(result.returncode, 0, result.stderr)
        env = parse_exports(result.stdout)
        self.assertEqual(env["APP_NAME"], "booknbook")
        self.assertEqual(env["APP_NS"], "apps-booknbook-dev")
        self.assertEqual(env["APP_ARGO"], "booknbook-dev")
        self.assertEqual(env["APP_TARGET_PORT"], "3000")
        self.assertEqual(env["APP_LIVENESS"], "/healthz")
        self.assertEqual(env["APP_READINESS"], "/readyz")

    def test_every_tracked_app_definition_exports(self) -> None:
        apps = sorted((SCRIPTS.parent / "apps").glob("*.yaml"))
        self.assertTrue(apps)
        for path in apps:
            with self.subTest(app=path.stem):
                result = run_app_env(path.stem)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(parse_exports(result.stdout)["APP_NAME"], path.stem)

    def test_unknown_app_fails_without_output(self) -> None:
        result = run_app_env("no-such-app")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("missing app definition", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
