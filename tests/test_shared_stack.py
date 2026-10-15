"""Full local acceptance: no external providers and no skipped database evidence."""
import importlib.util
import json
import os
from pathlib import Path


def test_acceptance_entrypoint_is_available():
    assert importlib.util.find_spec('shared_infra.acceptance') is not None, 'real HTTP acceptance harness is missing'


def test_real_multi_process_stack_and_restore(tmp_path):
    from shared_infra.acceptance import run_acceptance
    result = run_acceptance(os.environ['PLATFORM_TEST_DSN'], pg_bin=Path(os.environ['PLATFORM_PG_BIN']), operations=24, concurrency=6)
    assert result['status'] == 'passed'
    assert result['stage'] == 'implemented-local'
    assert result['external_provider_calls'] == 0
    assert result['runtime_roles_non_bypassrls'] == 7
    assert result['api_processes'] >= 9
    assert result['post_traffic_readiness']=={'services':7,'replicas':9,'passes':27}
    assert result['workflow']['workers'] == 2
    assert result['workflow']['distinct_claims'] == 2
    assert result['workflow']['duplicate_jobs'] == 1
    assert result['workflow']['stale_ack_status'] == 409
    assert result['workflow']['restart_recovered'] is True
    assert result['workflow']['drained'] == 24
    assert result['data']['admitted'] == result['data']['limit'] == 7
    assert result['data']['overshoot'] == 0
    assert result['data']['counter_final'] == 24
    assert result['recovery']['restored_workspaces'] == 2
    assert result['recovery']['rows_reopened_over_http'] >= 2
    assert result['telemetry']['authenticated'] is True
    assert result['telemetry']['templates_only'] is True
    assert set(result['capabilities']) == {'developer','security','communication','media','payment'}
    assert all(value['passed'] for value in result['capabilities'].values())
    for summary in result['measurements'].values():
        assert summary['count'] > 0
        assert summary['errors'] == 0
        assert 0 <= summary['p50_ms'] <= summary['p95_ms']
        assert summary['throughput_per_second'] > 0
    serialized = json.dumps(result)
    assert 'Bearer ' not in serialized
    assert 'PRIVATE KEY' not in serialized
    assert 'dbname=' not in serialized


def test_acceptance_rejects_external_admin_before_connecting():
    from shared_infra.fixtures import validate_local_admin_dsn
    import pytest
    with pytest.raises(ValueError):
        validate_local_admin_dsn('host=example.com dbname=production user=fixture')


def test_acceptance_rejects_multi_host_and_service_indirection():
    from shared_infra.fixtures import validate_local_admin_dsn
    import pytest
    for dsn in ('host=/tmp,example.com dbname=postgres user=fixture',
                'host=/tmp dbname=postgres user=fixture service=external'):
        with pytest.raises(ValueError):
            validate_local_admin_dsn(dsn)
