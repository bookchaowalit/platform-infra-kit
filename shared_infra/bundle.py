"""Build an offline, hashed CPython 3.12/Linux x86_64 wheel bundle."""
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile

from .delivery import source_revision, write_wheel_manifest, verify_wheel_manifest
from .runtime import SERVICES

REQUIRED = {'platform-backend-core', 'platform-observability', 'platform-infra-kit'} | {'platform-' + s for s in SERVICES}


def export_source(path, revision, destination):
    """Export an exact Git commit, accepting regular files/directories only."""
    path, destination = Path(path), Path(destination)
    # git archive omits submodule contents, so reject them explicitly rather
    # than silently packaging an incomplete source tree. Links are unsupported.
    tree = subprocess.run(['git','-C',str(path),'ls-tree','-rz',revision],
                          check=True,capture_output=True).stdout
    for entry in tree.split(b'\0'):
        if entry and entry.split(b' ',1)[0] not in {b'100644',b'100755'}:
            raise ValueError('source links and submodules are unsupported')
    destination.mkdir(mode=0o700,exist_ok=False)
    with tempfile.TemporaryFile() as archive:
        subprocess.run(['git','-C',str(path),'archive','--format=tar',revision],
                       stdout=archive,check=True)
        archive.seek(0)
        with tarfile.open(fileobj=archive,mode='r:') as source:
            members = source.getmembers()
            for member in members:
                relative = PurePosixPath(member.name)
                if (relative.is_absolute() or '..' in relative.parts or '\\' in member.name
                        or not relative.parts or not (member.isdir() or member.isfile())):
                    raise ValueError('unsafe source archive entry')
            for member in members:
                target = destination.joinpath(*PurePosixPath(member.name).parts)
                if member.isdir():
                    target.mkdir(mode=0o700,parents=True,exist_ok=True)
                    continue
                target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                with source.extractfile(member) as stream, target.open('xb') as output:
                    shutil.copyfileobj(stream,output)
                target.chmod(0o700 if member.mode & 0o111 else 0o600)
    return destination


def build_bundle(sources, output):
    if not isinstance(sources, dict) or set(sources) != REQUIRED:
        raise ValueError('explicit mapping of all ten source repositories required')
    paths = {name: Path(path).resolve(strict=True) for name, path in sources.items()}
    revisions = {name: source_revision(path) for name, path in paths.items()}
    output = Path(output)
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    wheels = output / 'wheels'
    wheels.mkdir()
    # Build only fresh commit exports. Ignored/untracked build output never
    # enters a source tree, even when setuptools would otherwise reuse it.
    with tempfile.TemporaryDirectory(prefix='shared-infra-build-') as directory:
        exported = {name: export_source(paths[name],revisions[name],Path(directory)/name)
                    for name in sorted(paths)}
        subprocess.run([sys.executable, '-m', 'pip', 'wheel', '--no-deps', '--no-build-isolation', '--no-index',
                        '--wheel-dir', str(wheels.resolve()), *[str(exported[name]) for name in sorted(exported)]], check=True)
        shutil.copyfile(exported['platform-infra-kit'] / 'shared-infra' / 'Dockerfile', output / 'Dockerfile')
    if any(source_revision(paths[name]) != revision for name, revision in revisions.items()):
        raise ValueError('source changed while packaging')
    # Target tags are explicit; host Python's native wheels cannot accidentally
    # enter a Python3.12 deployment. Network access is package download only.
    subprocess.run([sys.executable, '-m', 'pip', 'download', '--only-binary=:all:',
                    '--python-version', '312', '--implementation', 'cp', '--abi', 'cp312',
                    '--platform', 'manylinux2014_x86_64', '--dest', str(wheels), '--find-links', str(wheels),
                    *[name + '==0.1.0' for name in sorted(REQUIRED)]], check=True)
    write_wheel_manifest(output, sources=revisions)
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
