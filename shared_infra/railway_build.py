"""Public hosted builder: exact GitHub source archives, hash-locked binary dependencies."""
import argparse
import hashlib
import gzip
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


MAX_SOURCE_ENTRIES=20000
MAX_SOURCE_DECLARED_BYTES=100_000_000
MAX_SOURCE_EXPANDED_BYTES=100_000_000
MAX_SOURCE_METADATA_BYTES=1_000_000
MAX_SOURCE_PAX_KEYS=128
MAX_SOURCE_PAX_CHARS=65536


def extract_source(stream, destination):
    """Bound gzip expansion and tar parsing before accepting each source entry."""
    destination=Path(destination)
    destination.mkdir(mode=0o700,parents=True,exist_ok=False)
    headers=declared=expanded=0
    root=None

    def check_pax(fields):
        if (len(fields)>MAX_SOURCE_PAX_KEYS
                or sum(len(key)+len(value) for key,value in fields.items())>MAX_SOURCE_PAX_CHARS):
            raise ValueError('source effective metadata bound exceeded')

    class BoundedTarInfo(tarfile.TarInfo):
        def _apply_pax_info(self,fields,encoding,errors):
            # Check local overrides too, before tarfile copies the effective dict.
            check_pax(fields)
            return super()._apply_pax_info(fields,encoding,errors)

        def _proc_member(self,archive):
            # This hook runs before Python parses PAX/GNU payloads on both
            # supported interpreters (whose frombuf paths differ).
            nonlocal headers
            headers+=1
            # Global headers update this dict before recursing to the next raw
            # header. Bound accumulation before any inherited dictionary copy.
            check_pax(archive.pax_headers)
            metadata={tarfile.XHDTYPE,tarfile.XGLTYPE,tarfile.GNUTYPE_LONGNAME,tarfile.GNUTYPE_LONGLINK}
            if headers>MAX_SOURCE_ENTRIES or self.size<0:
                raise ValueError('source archive entry bound exceeded')
            if self.type not in metadata|{tarfile.REGTYPE,tarfile.AREGTYPE,tarfile.DIRTYPE}:
                raise ValueError('unsupported source header type')
            if self.type in metadata:
                if self.size>MAX_SOURCE_METADATA_BYTES:
                    raise ValueError('source extended header bound exceeded')
                depth=getattr(archive,'_bounded_metadata_depth',0)
                if depth>=32:
                    raise ValueError('source extended header nesting bound exceeded')
                archive._bounded_metadata_depth=depth+1
                try:
                    return super()._proc_member(archive)
                finally:
                    archive._bounded_metadata_depth=depth
            return super()._proc_member(archive)

    with gzip.GzipFile(fileobj=stream,mode='rb') as compressed:
        class ExpandedReader:
            def read(self,size=-1):
                nonlocal expanded
                allowance=MAX_SOURCE_EXPANDED_BYTES-expanded+1
                value=compressed.read(min(size,allowance) if size>=0 else allowance)
                expanded+=len(value)
                if expanded>MAX_SOURCE_EXPANDED_BYTES:
                    raise ValueError('source archive expanded-byte bound exceeded')
                return value
        with tarfile.open(fileobj=ExpandedReader(),mode='r|',tarinfo=BoundedTarInfo) as archive:
            while (member:=archive.next()) is not None:
                # r| still caches TarInfo objects on Python 3.12 and 3.14.
                # next() avoids iterator cache indexes; discard before every
                # branch (including repeated root-directory entries).
                archive.members.clear()
                declared+=member.size
                if declared>MAX_SOURCE_DECLARED_BYTES:
                    raise ValueError('source archive declared-size bound exceeded')
                path=PurePosixPath(member.name)
                if (path.is_absolute() or '..' in path.parts or '\\' in member.name or not path.parts
                        or '.gitmodules' in path.parts or '.git' in path.parts
                        or member.sparse is not None or not (member.isfile() or member.isdir())):
                    raise ValueError('unsupported source archive entry')
                if root is None:
                    root=path.parts[0]
                elif root!=path.parts[0]:
                    raise ValueError('single source archive root required')
                if len(path.parts)==1:
                    if not member.isdir():
                        raise ValueError('source root must be a directory')
                    continue
                target=destination.joinpath(*path.parts[1:])
                if member.isdir():
                    target.mkdir(mode=0o700,parents=True,exist_ok=True)
                else:
                    target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
                    with archive.extractfile(member) as source,target.open('xb') as output:
                        shutil.copyfileobj(source,output)
                    target.chmod(0o700 if member.mode & 0o111 else 0o600)
    if root is None:
        raise ValueError('source archive is empty')


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
