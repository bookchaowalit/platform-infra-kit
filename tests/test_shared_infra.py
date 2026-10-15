import importlib
import os
from pathlib import Path
import tempfile
from uuid import uuid4

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
import pytest


def module(name):
    try:
        return importlib.import_module('shared_infra.' + name)
    except ModuleNotFoundError:
        pytest.fail('shared infrastructure release/recovery implementation is missing')


def plan():
    return {'version': 1, 'stage': 'staged', 'database_connection_budget': 40,
            'services': [{'name': 'workflow', 'image': 'registry.example/workflow@sha256:' + 'a' * 64,
                          'replicas': 2, 'pool_max': 8, 'workers': 1, 'worker_pool_max': 4,
                          'memory_mb': 256, 'request_timeout_seconds': 30}]}


def test_release_accepts_a_pinned_bounded_service():
    assert module('release').validate_plan(plan()) == []


def test_release_rejects_unpinned_images():
    p = plan()
    p['services'][0]['image'] = 'registry.example/workflow:latest'
    assert any('digest' in error for error in module('release').validate_plan(p))


def test_release_connection_budget_includes_api_and_worker_replicas():
    p = plan()
    p['services'][0].update(replicas=4, workers=3)
    assert any('connection budget' in error for error in module('release').validate_plan(p))


@pytest.mark.parametrize('field,value', [('replicas', 0), ('pool_max', 0), ('memory_mb', 0),
                                         ('request_timeout_seconds', float('inf'))])
def test_release_refuses_unbounded_or_invalid_resources(field, value):
    p = plan()
    p['services'][0][field] = value
    assert module('release').validate_plan(p)


def test_release_refuses_duplicate_service_names():
    p = plan()
    p['services'].append(dict(p['services'][0]))
    assert any('duplicate' in error for error in module('release').validate_plan(p))


@pytest.fixture
def disposable():
    from platform_backend_core.testing import temporary_database
    dsn = os.environ.get('PLATFORM_TEST_DSN')
    if not dsn:
        pytest.skip('PLATFORM_TEST_DSN required for real backup/restore drill')
    from shared_infra.fixtures import validate_local_admin_dsn
    dsn = validate_local_admin_dsn(dsn)
    with temporary_database(dsn, prefix='infra_test_') as database:
        yield database


def pg_bin():
    value = os.environ.get('PLATFORM_PG_BIN')
    if not value:
        pytest.skip('PLATFORM_PG_BIN required for real pg_dump/pg_restore')
    return Path(value)


def test_backup_restore_creates_fresh_database_and_preserves_data(disposable, tmp_path):
    api = module('recovery')
    workspace = uuid4()
    with psycopg.connect(disposable.admin_dsn) as conn:
        conn.execute('CREATE TABLE recovery_probe (workspace_id uuid NOT NULL, value text NOT NULL)')
        conn.execute('INSERT INTO recovery_probe VALUES (%s,%s)', (workspace, 'synthetic-recovery-evidence'))
    backup = tmp_path / 'evidence.dump'
    api.create_backup(disposable.admin_dsn, backup, pg_bin=pg_bin())
    assert backup.stat().st_mode & 0o777 == 0o600
    target = 'restore_' + uuid4().hex
    try:
        restored = api.restore_backup(disposable.admin_dsn, backup, target_database=target, pg_bin=pg_bin())
        with psycopg.connect(restored) as conn:
            assert conn.execute('SELECT workspace_id,value FROM recovery_probe').fetchone() == (workspace, 'synthetic-recovery-evidence')
    finally:
        with psycopg.connect(disposable.admin_dsn, autocommit=True) as conn:
            conn.execute(sql.SQL('DROP DATABASE IF EXISTS {} WITH (FORCE)').format(sql.Identifier(target)))


def test_restore_never_overwrites_existing_database(disposable, tmp_path):
    api = module('recovery')
    backup = tmp_path / 'evidence.dump'
    api.create_backup(disposable.admin_dsn, backup, pg_bin=pg_bin())
    existing = psycopg.conninfo.conninfo_to_dict(disposable.admin_dsn)['dbname']
    with pytest.raises(ValueError, match='already exists'):
        api.restore_backup(disposable.admin_dsn, backup, target_database=existing, pg_bin=pg_bin())
    with psycopg.connect(disposable.admin_dsn) as conn:
        assert conn.execute('SELECT 1').fetchone() == (1,)


def test_backup_never_overwrites_a_previous_backup(disposable, tmp_path):
    api = module('recovery')
    backup = tmp_path / 'evidence.dump'
    backup.write_bytes(b'existing backup')
    with pytest.raises(FileExistsError):
        api.create_backup(disposable.admin_dsn, backup, pg_bin=pg_bin())
    assert backup.read_bytes() == b'existing backup'
