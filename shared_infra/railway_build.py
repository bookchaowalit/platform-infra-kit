"""Public hosted builder: exact GitHub source archives, hash-locked binary dependencies."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


def extract_source(stream, destination):
    destination=Path(destination)
    destination.mkdir(mode=0o700,parents=True,exist_ok=False)
    with tarfile.open(fileobj=stream,mode='r:gz') as archive:
        members=archive.getmembers()
        roots=set()
        if len(members)>20000 or sum(member.size for member in members)>100_000_000:
            raise ValueError('source archive bound exceeded')
        for member in members:
            path=PurePosixPath(member.name)
            if (path.is_absolute() or '..' in path.parts or '\\' in member.name or not path.parts
                    or '.gitmodules' in path.parts or '.git' in path.parts
                    or not (member.isfile() or member.isdir())):
                raise ValueError('unsupported source archive entry')
            roots.add(path.parts[0])
        if len(roots)!=1:
            raise ValueError('single source archive root required')
        for member in members:
            path=PurePosixPath(member.name)
            if len(path.parts)==1:
                if not member.isdir(): raise ValueError('source root must be a directory')
                continue
            target=destination.joinpath(*path.parts[1:])
            if member.isdir():
                target.mkdir(mode=0o700,parents=True,exist_ok=True)
            else:
                target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                with archive.extractfile(member) as source,target.open('xb') as output:
                    shutil.copyfileobj(source,output)
                target.chmod(0o700 if member.mode & 0o111 else 0o600)


def requirements(wheels):
    lines=[]
    for filename,digest in sorted(wheels.items()):
        parts=filename.split('-')
        if len(parts)<5 or not filename.endswith('.whl') or not re.fullmatch('[a-f0-9]{64}',digest):
            raise ValueError('invalid dependency lock')
        lines.append(parts[0].replace('_','-')+'=='+parts[1]+' --hash=sha256:'+digest)
    return '\n'.join(lines)+'\n'


def pip(*args):
    env={key:value for key,value in os.environ.items() if not key.startswith('PIP_')}
    env.update(PIP_CONFIG_FILE=os.devnull,PIP_INDEX_URL='https://pypi.org/simple',PIP_NO_CACHE_DIR='1',SOURCE_DATE_EPOCH='315532800')
    subprocess.run([sys.executable,'-m','pip','--disable-pip-version-check',*map(str,args)],check=True,env=env)


def build(config_path,infra_sha,output):
    if not re.fullmatch('[a-f0-9]{40}',infra_sha):
        raise ValueError('exact INFRA_SOURCE_SHA required')
    if sys.version_info[:2] != (3,12):
        raise ValueError('hosted artifact build requires Python 3.12')
    config=json.loads(Path(config_path).read_text())
    sources=dict(config['sources']); sources['platform-infra-kit']=infra_sha
    if len(sources)!=10 or any(not re.fullmatch('platform-[a-z-]+',name) or not re.fullmatch('[a-f0-9]{40}',sha) for name,sha in sources.items()):
        raise ValueError('ten exact public source revisions required')
    output=Path(output); output.mkdir(mode=0o700,parents=True,exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='railway-build-') as directory:
        root=Path(directory)
        tools=root/'tools.txt'; tools.write_text(requirements(config['build_tools']))
        pip('install','--only-binary=:all:','--require-hashes','--no-deps','-r',tools)
        lock=root/'requirements.txt'; lock.write_text(requirements(config['dependencies']))
        pip('download','--only-binary=:all:','--require-hashes','--no-deps','--dest',output,'-r',lock)
        downloaded={path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in output.iterdir()}
        if downloaded != config['dependencies']:
            raise ValueError('downloaded artifact set differs from reviewed lock')
        paths=[]
        for name,sha in sorted(sources.items()):
            owner='bookchaowalit' if name=='platform-infra-kit' else 'bookchaowalit-backend'
            url=f'https://codeload.github.com/{owner}/{name}/tar.gz/{sha}'
            with urllib.request.urlopen(url,timeout=60) as response:
                content=response.read(100_000_001)
            if len(content)>100_000_000:
                raise ValueError('source download bound exceeded')
            path=root/name
            extract_source(io.BytesIO(content),path)
            paths.append(path)
        pip('wheel','--no-deps','--no-build-isolation','--no-index','--wheel-dir',output,*paths)
    entries=list(output.iterdir())
    if len(entries)!=len(config['dependencies'])+10 or any(path.is_symlink() or not path.is_file() or path.suffix!='.whl' for path in entries):
        raise ValueError('exact regular wheel set required')
    manifest=dict(version=1,sources=sources,wheels={path.name:hashlib.sha256(path.read_bytes()).hexdigest() for path in entries})
    (output.parent/'wheel-manifest.json').write_text(json.dumps(manifest,sort_keys=True))
    return manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,required=True)
    parser.add_argument('--infra-sha',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    try:
        manifest=build(args.config,args.infra_sha,args.output)
        print(json.dumps(dict(status='built',sources=manifest['sources'],wheels=len(manifest['wheels']))))
    except Exception:
        raise SystemExit('public pinned build failed') from None


if __name__=='__main__': main()
