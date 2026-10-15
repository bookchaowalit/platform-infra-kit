"""Hosted builds consume exact public source commits and hash-locked wheels."""
import importlib
import io
import json
from pathlib import Path
import sys
import tarfile

import pytest

ROOT=Path(__file__).parents[1]


def test_public_sources_and_image_digests_are_frozen():
    config=json.loads((ROOT/'shared-infra/railway/sources.json').read_text())
    assert len(config['sources'])==10
    assert config['sources']['platform-workflow']=='c17164f0daa9bdbeb073ead9d7620dfb0c7d4f0b'
    assert config['sources']['platform-data']=='21f2ed6702f5804aed271932288403999aebdd6b'
    assert all(len(sha)==40 for sha in config['sources'].values())
    docker=(ROOT/'shared-infra/railway/Dockerfile').read_text()
    assert 'python:3.12-slim-bookworm@sha256:' in docker
    assert 'postgres:16-bookworm@sha256:' in docker
    assert 'ARG INFRA_SOURCE_SHA' in docker
    assert '--only-binary=:all:' in docker
    assert not any('FROM ' in line and '@sha256:' not in line for line in docker.splitlines())
    assert len(config['dependencies'])>=40
    assert all(len(value)==64 for value in config['dependencies'].values())


@pytest.mark.parametrize('kind,name', [('symlink','root/link'),('file','../escape'),('file','/absolute'),('file','root/.gitmodules'),('file','root/back\\slash')])
def test_source_export_rejects_unsupported_archive_entries(tmp_path,kind,name):
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as archive:
        item=tarfile.TarInfo(name)
        if kind=='symlink': item.type=tarfile.SYMTYPE; item.linkname='/etc/passwd'
        archive.addfile(item,io.BytesIO())
    stream.seek(0)
    with pytest.raises(ValueError): module.extract_source(stream,tmp_path/'source')


def test_regular_archive_exact_export_and_hash_locked_dependencies(tmp_path):
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as archive:
        item=tarfile.TarInfo('source-commit/module.py'); item.size=4
        archive.addfile(item,io.BytesIO(b'x=1\n'))
    stream.seek(0)
    module.extract_source(stream,tmp_path/'source')
    assert (tmp_path/'source/module.py').read_text()=='x=1\n'
    requirements=module.requirements({'example_package-1.2.3-py3-none-any.whl':'a'*64})
    assert requirements=='example-package==1.2.3 --hash=sha256:'+'a'*64+'\n'


def test_build_rejects_unpinned_infra_source_before_download(tmp_path):
    module=importlib.import_module('shared_infra.railway_build')
    with pytest.raises(ValueError):
        module.build(ROOT/'shared-infra/railway/sources.json','main',tmp_path/'wheels')


def test_archive_rejects_at_entry_limit_without_parsing_remaining_headers(tmp_path,monkeypatch):
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as archive:
        for index in range(40000): archive.addfile(tarfile.TarInfo('root/file'+str(index)))
    parsed=0
    original=tarfile.TarInfo._proc_member
    def counted(self,*args,**kwargs):
        nonlocal parsed
        parsed+=1
        return original(self,*args,**kwargs)
    monkeypatch.setattr(tarfile.TarInfo,'_proc_member',counted)
    stream.seek(0)
    with pytest.raises(ValueError): module.extract_source(stream,tmp_path/'source')
    assert parsed<=20001,'headers after the entry limit were still parsed'


@pytest.mark.parametrize('kind',[tarfile.XHDTYPE,tarfile.GNUTYPE_LONGNAME])
def test_oversized_extended_header_rejected_before_payload_inflation(tmp_path,monkeypatch,kind):
    import gzip
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as archive:
        item=tarfile.TarInfo('root/metadata'); item.type=kind; item.size=2000000
        archive.addfile(item,io.BytesIO(b'x'*item.size))
    expanded=0
    original=gzip.GzipFile.read
    def counted(self,*args,**kwargs):
        nonlocal expanded
        value=original(self,*args,**kwargs); expanded+=len(value); return value
    monkeypatch.setattr(gzip.GzipFile,'read',counted)
    stream.seek(0)
    with pytest.raises((ValueError,tarfile.TarError)):
        module.extract_source(stream,tmp_path/'source')
    assert expanded<=65536,'extended header inflated before size rejection'


def test_actual_expanded_bytes_include_tar_headers_and_padding(tmp_path,monkeypatch):
    module=importlib.import_module('shared_infra.railway_build')
    monkeypatch.setattr(module,'MAX_SOURCE_EXPANDED_BYTES',4096,raising=False)
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as archive:
        item=tarfile.TarInfo('root/payload'); item.size=3000
        archive.addfile(item,io.BytesIO(b'x'*3000))
    stream.seek(0)
    with pytest.raises(ValueError): module.extract_source(stream,tmp_path/'source')


@pytest.mark.parametrize('kind',['root','directory','file'])
def test_processed_members_do_not_retain_inherited_metadata(tmp_path,monkeypatch,kind):
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    # A small accepted global dictionary multiplied by many entries must not
    # remain resident after streaming extraction.
    fields={f'field{index}':'x'*100 for index in range(100)}
    with tarfile.open(fileobj=stream,mode='w:gz',pax_headers=fields) as archive:
        for index in range(200):
            name='root/' if kind=='root' else f'root/{kind}{index}'
            item=tarfile.TarInfo(name)
            if kind!='file': item.type=tarfile.DIRTYPE
            else: item.size=4
            archive.addfile(item,io.BytesIO(b'x=1\n'))
    opened=[]
    original=tarfile.open
    def capture(*args,**kwargs):
        archive=original(*args,**kwargs)
        opened.append(archive)
        return archive
    monkeypatch.setattr(tarfile,'open',capture)
    peak_members=0
    original_next=tarfile.TarFile.next
    def track_next(self):
        nonlocal peak_members
        member=original_next(self)
        peak_members=max(peak_members,len(self.members))
        return member
    monkeypatch.setattr(tarfile.TarFile,'next',track_next)
    stream.seek(0)
    module.extract_source(stream,tmp_path/'source')
    retained=sum(sys.getsizeof(member.pax_headers) for member in opened[0].members)
    assert retained==0, f'{len(opened[0].members)} processed members retained {retained} metadata-dictionary bytes'
    assert peak_members<=1,'processed members accumulated during extraction'
    if kind=='directory': assert (tmp_path/'source/directory199').is_dir()
    if kind=='file': assert (tmp_path/'source/file199').read_bytes()==b'x=1\n'


@pytest.mark.parametrize('fields',[
    {f'unknown{index:05}':'x' for index in range(10000)},
    {'comment':'x'*65537},
])
def test_inherited_metadata_rejected_before_member_copies(tmp_path,monkeypatch,fields):
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz',pax_headers=fields) as archive:
        for _ in range(200):
            item=tarfile.TarInfo('root/'); item.type=tarfile.DIRTYPE
            archive.addfile(item)
    copied=0
    original=tarfile.TarInfo._apply_pax_info
    def counted(self,*args,**kwargs):
        nonlocal copied
        copied+=1
        return original(self,*args,**kwargs)
    monkeypatch.setattr(tarfile.TarInfo,'_apply_pax_info',counted)
    stream.seek(0)
    with pytest.raises(ValueError,match='metadata'):
        module.extract_source(stream,tmp_path/'source')
    assert copied==0,'oversized inherited metadata was copied into a member'


def test_successive_global_headers_cannot_accumulate_unbounded_metadata(tmp_path):
    import gzip
    module=importlib.import_module('shared_infra.railway_build')
    item=tarfile.TarInfo('root/'); item.type=tarfile.DIRTYPE
    first={f'first{index}':'x' for index in range(80)}
    second={f'second{index}':'x' for index in range(80)}
    raw=(tarfile.TarInfo.create_pax_global_header(first)+item.tobuf()
         +tarfile.TarInfo.create_pax_global_header(second)+item.tobuf()+b'\0'*1024)
    with pytest.raises(ValueError,match='metadata'):
        module.extract_source(io.BytesIO(gzip.compress(raw)),tmp_path/'source')


def test_local_metadata_cannot_bypass_effective_metadata_bound(tmp_path):
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    with tarfile.open(fileobj=stream,mode='w:gz') as archive:
        item=tarfile.TarInfo('root/module.py')
        item.pax_headers={f'unknown{index}':'x' for index in range(200)}
        archive.addfile(item)
    stream.seek(0)
    with pytest.raises(ValueError,match='metadata'):
        module.extract_source(stream,tmp_path/'source')


def test_codeload_global_comment_and_local_long_path_are_preserved(tmp_path):
    module=importlib.import_module('shared_infra.railway_build')
    stream=io.BytesIO()
    relative='package/'+'long_module_'*12+'.py'
    with tarfile.open(fileobj=stream,mode='w:gz',pax_headers={'comment':'a'*40}) as archive:
        item=tarfile.TarInfo('source-'+'a'*40+'/'+relative); item.size=4
        item.pax_headers={'mtime':'1700000000.123'}
        archive.addfile(item,io.BytesIO(b'x=1\n'))
    stream.seek(0)
    module.extract_source(stream,tmp_path/'source')
    assert (tmp_path/'source'/relative).read_bytes()==b'x=1\n'
