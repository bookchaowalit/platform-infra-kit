#!/usr/bin/env python3
"""Cross-platform tests for checking tracked executable modes."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


INFRA_ROOT = Path(__file__).resolve().parents[2]
PLATFORM_ROOT = INFRA_ROOT / "platform"
import sys

sys.path.insert(0, str(PLATFORM_ROOT))

from git_file_mode import FileModeError, has_executable_bit  # noqa: E402


class GitFileModeTest(unittest.TestCase):
    @unittest.skipIf(
        os.name == "nt", "POSIX execute bits are not available in Windows worktrees"
    )
    def test_posix_checks_working_tree_execute_bit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "script.sh"
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            script.chmod(0o700)

            self.assertTrue(has_executable_bit(script, root, os_name="posix"))
            script.chmod(0o600)
            self.assertFalse(has_executable_bit(script, root, os_name="posix"))

    def test_windows_uses_git_index_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "infra" / "platform" / "script.sh"
            script.parent.mkdir(parents=True)
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            output = "100755 deadbeef 0\tinfra/platform/script.sh\n"
            with patch(
                "git_file_mode.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, output, ""),
            ) as run:
                self.assertTrue(has_executable_bit(script, root, os_name="nt"))

            run.assert_called_once()
            self.assertEqual(run.call_args.args[0][-1], "infra/platform/script.sh")

    def test_windows_rejects_non_executable_git_index_mode(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "script.sh"
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            output = "100644 deadbeef 0\tscript.sh\n"
            with patch(
                "git_file_mode.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, output, ""),
            ):
                self.assertFalse(has_executable_bit(script, root, os_name="nt"))

    def test_windows_surfaces_git_query_errors(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "script.sh"
            script.write_text("#!/bin/sh\n", encoding="utf-8")
            with patch(
                "git_file_mode.subprocess.run",
                return_value=subprocess.CompletedProcess([], 1, "", "git unavailable"),
            ):
                with self.assertRaises(FileModeError):
                    has_executable_bit(script, root, os_name="nt")


if __name__ == "__main__":
    unittest.main()
