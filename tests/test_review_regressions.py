"""Behavioral regressions for the six infrastructure release review findings."""
from contextlib import contextmanager
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import zipfile

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
import pytest

from shared_infra import bundle, delivery
from shared_infra.fixtures import Authority, AUDIENCE, ISSUER, service_database, validate_local_admin_dsn


def test_recovery_cli_redacts_actual_driver_dsn_parse_error(tmp_path):
    marker = 'synthetic-private-password'
    archive = tmp_path / 'fixture.dump'
    archive.write_bytes(b'fixture')
    environment = dict(os.environ, REVIEW_FIXTURE_DSN='postgresql://fixture:'+marker+'%ZZ@127.0.0.1/fixture')
    result = subprocess.run([sys.executable,'-m','shared_infra','restore','--dsn-env','REVIEW_FIXTURE_DSN',
        '--archive',str(archive),'--target','fixture_new_target','--confirm-new-database','fixture_new_target',
        '--pg-bin',str(tmp_path)],env=environment,capture_output=True,text=True)
    assert result.returncode == 1
    assert marker not in result.stdout + result.stderr
    assert result.stderr == ''
    assert json.loads(result.stdout) == {'status':'failed','error':'configuration_or_operation_failed'}


@pytest.mark.parametrize('variable',['PGHOSTADDR','PGSERVICE','PGPASSFILE','PGOPTIONS','PGAPPNAME','PGUSER'])
def test_local_fixture_rejects_ambient_pg_overrides(monkeypatch,variable):
    monkeypatch.setenv(variable,'synthetic-ambient-private')
    with pytest.raises(ValueError) as raised:
        validate_local_admin_dsn('host=127.0.0.1 dbname=fixture user=fixture')
    assert 'synthetic-ambient-private' not in str(raised.value)


def test_normalized_fixture_dsn_disables_default_passfile():
    result=validate_local_admin_dsn('host=127.0.0.1 dbname=fixture user=fixture passfile=/must-not-read')
    assert conninfo_to_dict(result)['passfile'] == os.devnull


def test_recovery_fixture_guards_before_resource_creation(monkeypatch):
    target=importlib.import_module('test_shared_infra')
    import platform_backend_core.testing as testing
    def forbidden(*args,**kwargs):
        pytest.fail('unguarded external DSN reached resource creation')
    monkeypatch.setattr(testing,'temporary_database',forbidden)
    monkeypatch.setenv('PLATFORM_TEST_DSN','host=example.invalid dbname=fixture user=fixture')
    with pytest.raises(ValueError):
        next(target.disposable.__wrapped__())


def _commit(path):
    subprocess.run(['git','-C',str(path),'add','-A'],check=True)
    subprocess.run(['git','-C',str(path),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                    'commit','-qm','fixture source'],check=True)
    return delivery.source_revision(path)


def test_bundle_builds_actual_wheel_from_commit_without_stale_ignored_modules(tmp_path,monkeypatch):
    source=tmp_path/'source';source.mkdir()
    subprocess.run(['git','init','-q',str(source)],check=True)
    (source/'.gitignore').write_text('build/\n*.egg-info/\n')
    (source/'pyproject.toml').write_text('[build-system]\nrequires=["setuptools"]\nbuild-backend="setuptools.build_meta"\n[project]\nname="platform-infra-kit"\nversion="0.1.0"\n[tool.setuptools.packages.find]\ninclude=["fixture_pkg*"]\n')
    package=source/'fixture_pkg';package.mkdir()
    (package/'__init__.py').write_text('VALUE="reviewed"\n')
    (package/'deleted_module.py').write_text('VALUE="removed"\n')
    docker=source/'shared-infra';docker.mkdir()
    (docker/'Dockerfile').write_text('# reviewed fixture Dockerfile\n')
    _commit(source)
    (package/'deleted_module.py').unlink()
    revision=_commit(source)
    stale=source/'build/lib/fixture_pkg';stale.mkdir(parents=True)
    (stale/'__init__.py').write_text('VALUE="stale-ignored"\n')
    (stale/'deleted_module.py').write_text('VALUE="ignored-deleted-module"\n')
    for file in stale.iterdir():os.utime(file,(time.time()+86400,time.time()+86400))
    original_run=subprocess.run
    def run(arguments,*args,**kwargs):
        if arguments[:4] == [sys.executable,'-m','pip','download']:
            return subprocess.CompletedProcess(arguments,0)
        return original_run(arguments,*args,**kwargs)
    monkeypatch.setattr(bundle,'REQUIRED',{'platform-infra-kit'})
    monkeypatch.setattr(subprocess,'run',run)
    output=tmp_path/'bundle'
    assert bundle.build_bundle({'platform-infra-kit':str(source)},output) == {'platform-infra-kit':revision}
    wheels=list((output/'wheels').glob('*.whl'))
    assert len(wheels) == 1
    with zipfile.ZipFile(wheels[0]) as wheel:
        assert wheel.read('fixture_pkg/__init__.py') == b'VALUE="reviewed"\n'
        assert 'fixture_pkg/deleted_module.py' not in wheel.namelist()
    assert (output/'Dockerfile').read_text() == '# reviewed fixture Dockerfile\n'


@pytest.mark.parametrize('entry',['unhashed.tar.gz','unhashed.zip','directory','symlink'])
def test_exact_wheel_set_rejects_every_non_regular_wheel(tmp_path,entry):
    wheels=tmp_path/'wheels';wheels.mkdir()
    (wheels/'fixture-0.1-py3-none-any.whl').write_bytes(b'fixture')
    delivery.write_wheel_manifest(tmp_path,sources={'fixture':'a'*40})
    extra=wheels/entry
    if entry=='directory':extra.mkdir()
    elif entry=='symlink':extra.symlink_to(wheels/'fixture-0.1-py3-none-any.whl')
    else:extra.write_bytes(b'unhashed source')
    assert delivery.verify_wheel_manifest(tmp_path)
    with pytest.raises(ValueError):
        (tmp_path/'wheel-manifest.json').unlink()
        delivery.write_wheel_manifest(tmp_path,sources={'fixture':'a'*40})


def test_dockerfile_verifier_rejects_unhashed_source_and_installs_binary_only(tmp_path):
    docker=Path('shared-infra/Dockerfile').read_text()
    assert '--only-binary=:all:' in docker
    line=next(line for line in docker.splitlines() if line.startswith('RUN python -c '))
    import shlex
    command=shlex.split(line.removesuffix(' \\'))
    wheels=tmp_path/'wheels';wheels.mkdir()
    (wheels/'fixture.whl').write_bytes(b'fixture')
    delivery.write_wheel_manifest(tmp_path,sources={})
    code=command[3].replace('"/wheels"',repr(str(wheels))).replace('"/wheel-manifest.json"',repr(str(tmp_path/'wheel-manifest.json')))
    assert subprocess.run([sys.executable,'-c',code],capture_output=True).returncode == 0
    (wheels/'unhashed.tar.gz').write_bytes(b'fixture source')
    assert subprocess.run([sys.executable,'-c',code],capture_output=True).returncode != 0


def test_renderer_supplies_database_role_connection_ceiling():
    from test_shared_delivery import release
    documents=delivery.render_kubernetes(release(),namespace='fixture')
    deployment=next(item for item in documents if item['kind']=='Deployment')
    environment={item['name']:item['value'] for item in deployment['spec']['template']['spec']['containers'][0]['env']}
    assert environment['DATABASE_CONNECTION_CEILING'] == '32'


def test_generic_runtime_requires_explicit_connection_ceiling(monkeypatch):
    from shared_infra.runtime import app_factory
    authority=Authority.generate()
    for name,value in {'PLATFORM_SERVICE':'data','DATABASE_POOL_MAX':'1',
        'DATABASE_URL':'host=/nonexistent-fixture dbname=fixture user=fixture',
        'JWT_ISSUER':ISSUER,'JWT_AUDIENCE':AUDIENCE,'JWT_PUBLIC_KEY':authority.public_key}.items():
        monkeypatch.setenv(name,value)
    monkeypatch.delenv('DATABASE_CONNECTION_CEILING',raising=False)
    app=None
    try:
        with pytest.raises(ValueError,match='bound|ceiling'):
            app=app_factory()
    finally:
        if app is not None:
            app.state.database.close()
            app.state.platform_observation.close()


@pytest.mark.parametrize('service',['data','workflow'])
def test_actual_login_role_cap_is_required_and_enforced(monkeypatch,service):
    from fastapi.testclient import TestClient
    from shared_infra.runtime import app_factory
    authority=Authority.generate()
    admin=validate_local_admin_dsn(os.environ['PLATFORM_TEST_DSN'])
    with service_database(admin,service) as database:
        with psycopg.connect(database.admin_dsn) as conn:
            conn.execute(sql.SQL('ALTER ROLE {} LOGIN CONNECTION LIMIT 2').format(sql.Identifier(database.runtime_role)))
        login=make_conninfo(database.admin_dsn,user=database.runtime_role,options='')
        for name,value in {'PLATFORM_SERVICE':service,'DATABASE_URL':login,'DATABASE_POOL_MAX':'1',
            'DATABASE_CONNECTION_CEILING':'2','JWT_ISSUER':ISSUER,'JWT_AUDIENCE':AUDIENCE,
            'JWT_PUBLIC_KEY':authority.public_key}.items():monkeypatch.setenv(name,value)
        with TestClient(app_factory()) as client:
            assert client.get('/readyz').status_code == 200
            for limit in (-1,0,3):
                with psycopg.connect(database.admin_dsn) as conn:
                    conn.execute(sql.SQL('ALTER ROLE {} CONNECTION LIMIT {}').format(sql.Identifier(database.runtime_role),sql.Literal(limit)))
                assert client.get('/readyz').status_code == 503
            with psycopg.connect(database.admin_dsn) as conn:
                conn.execute(sql.SQL('ALTER ROLE {} CONNECTION LIMIT 2').format(sql.Identifier(database.runtime_role)))
            assert client.get('/readyz').status_code == 200
            with psycopg.connect(login) as held:
                assert held.execute('SELECT session_user=current_user').fetchone() == (True,)
                with pytest.raises(psycopg.OperationalError):
                    psycopg.connect(login,connect_timeout=1)
        # Admin-authenticated SET ROLE connections do not consume the role's cap.
        monkeypatch.setenv('DATABASE_URL',database.runtime_dsn)
        with TestClient(app_factory()) as client:
            assert client.get('/readyz').status_code == 503


@pytest.mark.parametrize('kind',['symlink','submodule'])
def test_source_export_rejects_tracked_links_and_submodules(tmp_path,kind):
    source=tmp_path/'source';source.mkdir()
    subprocess.run(['git','init','-q',str(source)],check=True)
    (source/'reviewed.py').write_text('VALUE=True\n')
    revision=_commit(source)
    if kind=='symlink':
        (source/'linked.py').symlink_to('/outside-fixture')
        revision=_commit(source)
    else:
        subprocess.run(['git','-C',str(source),'update-index','--add','--cacheinfo','160000,'+revision+',vendor'],check=True)
        subprocess.run(['git','-C',str(source),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                        'commit','-qm','fixture submodule'],check=True)
        revision=subprocess.run(['git','-C',str(source),'rev-parse','HEAD'],check=True,capture_output=True,text=True).stdout.strip()
    with pytest.raises(ValueError):
        bundle.export_source(source,revision,tmp_path/'export')
    assert not (tmp_path/'export').exists()


def test_source_export_rejects_traversal_before_extracting_any_file(tmp_path,monkeypatch):
    import tarfile
    import io
    def archive_command(arguments,**kwargs):
        if 'ls-tree' in arguments:return subprocess.CompletedProcess(arguments,0,stdout=b'')
        with tarfile.open(fileobj=kwargs['stdout'],mode='w') as archive:
            for name in ('safe.py','../outside.py'):
                member=tarfile.TarInfo(name);member.size=1
                archive.addfile(member,io.BytesIO(b'x'))
        return subprocess.CompletedProcess(arguments,0)
    monkeypatch.setattr(subprocess,'run',archive_command)
    with pytest.raises(ValueError):
        bundle.export_source(tmp_path,'a'*40,tmp_path/'export')
    assert not (tmp_path/'outside.py').exists()
    assert not (tmp_path/'export'/'safe.py').exists()
