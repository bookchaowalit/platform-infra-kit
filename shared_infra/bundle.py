"""Build an offline, hashed CPython 3.12/Linux x86_64 wheel bundle."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

from .delivery import source_revision, write_wheel_manifest, verify_wheel_manifest
from .runtime import SERVICES

REQUIRED = {'platform-backend-core', 'platform-observability', 'platform-infra-kit'} | {'platform-' + s for s in SERVICES}


def build_bundle(sources, output):
    if not isinstance(sources, dict) or set(sources) != REQUIRED:
        raise ValueError('explicit mapping of all ten source repositories required')
    paths = {name: Path(path).resolve(strict=True) for name, path in sources.items()}
    revisions = {name: source_revision(path) for name, path in paths.items()}
    output = Path(output)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    wheels = output / 'wheels'
    wheels.mkdir()
    # Build from reviewed clean source. No dependencies are fetched during this
    # stage; setuptools is supplied by the operator's isolated build environment.
    subprocess.run([sys.executable, '-m', 'pip', 'wheel', '--no-deps', '--no-build-isolation',
                    '--wheel-dir', str(wheels), *[str(paths[name]) for name in sorted(paths)]], check=True)
    if any(source_revision(paths[name]) != revision for name, revision in revisions.items()):
        raise ValueError('source changed while packaging')
    # Target tags are explicit; host Python's native wheels cannot accidentally
    # enter a Python3.12 deployment. Network access is package download only.
    subprocess.run([sys.executable, '-m', 'pip', 'download', '--only-binary=:all:',
                    '--python-version', '312', '--implementation', 'cp', '--abi', 'cp312',
                    '--platform', 'manylinux2014_x86_64', '--dest', str(wheels), '--find-links', str(wheels),
                    *[name + '==0.1.0' for name in sorted(REQUIRED)]], check=True)
    write_wheel_manifest(output, sources=revisions)
    shutil.copyfile(paths['platform-infra-kit'] / 'shared-infra' / 'Dockerfile', output / 'Dockerfile')
    if verify_wheel_manifest(output):
        raise ValueError('bundle verification failed')
    return revisions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', required=True, type=Path, help='JSON mapping repository name to explicit checkout path')
    parser.add_argument('--output', required=True, type=Path, help='new output directory')
    args = parser.parse_args()
    try:
        revisions = build_bundle(json.loads(args.sources.read_text()), args.output)
        print(json.dumps({'status': 'built', 'sources': revisions}))
    except Exception:
        raise SystemExit('bundle failed; inspect build output and clean source revisions') from None


if __name__ == '__main__':
    main()
