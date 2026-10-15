"""Hosted builds consume exact public source commits and hash-locked wheels."""
import importlib
import io
import json
from pathlib import Path
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
