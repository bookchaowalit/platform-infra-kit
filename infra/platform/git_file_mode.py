"""Read executable mode consistently across POSIX and Windows worktrees."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path


class FileModeError(RuntimeError):
    """Raised when the repository's executable mode cannot be determined."""


def has_executable_bit(
    path: Path,
    repository_root: Path,
    *,
    os_name: str | None = None,
) -> bool:
    if (os_name or os.name) != "nt":
        try:
            return bool(path.stat().st_mode & stat.S_IXUSR)
        except OSError as exc:
            raise FileModeError("filesystem_mode_unavailable") from exc

    root = repository_root.resolve()
    try:
        relative_path = path.resolve().relative_to(root).as_posix()
    except ValueError as exc:
        raise FileModeError("path_outside_repository") from exc

    try:
        result = subprocess.run(
            ["git", "ls-files", "--stage", "--", relative_path],
            cwd=root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise FileModeError("git_file_mode_unavailable") from exc
    if result.returncode != 0:
        raise FileModeError("git_file_mode_query_failed")

    for line in result.stdout.splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) == 4 and fields[2] == "0" and fields[3] == relative_path:
            return fields[0] == "100755"
    return False
