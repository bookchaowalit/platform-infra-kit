from copy import deepcopy
import importlib
import json
from pathlib import Path
import subprocess

import pytest


def api():
    try:
        return importlib.import_module('shared_infra.delivery')
    except ModuleNotFoundError:
        pytest.fail('portable shared-service delivery is missing')


def release():
    return {'version': 1, 'stage': 'staged', 'database_connection_budget': 48,
            'services': [{'name': 'data', 'image': 'registry.example/data@sha256:' + 'a' * 64,
                          'replicas': 2, 'max_replicas': 4, 'pool_max': 8,
                          'workers': 0, 'worker_pool_max': 2, 'memory_mb': 256,
                          'request_timeout_seconds': 30,
                          'required_env': ['DATABASE_URL', 'JWT_ISSUER', 'JWT_AUDIENCE', 'JWT_PUBLIC_KEY']}]}


def test_generated_workloads_bound_hpa_and_use_only_runtime_secret_names():
    documents = api().render_kubernetes(release(), namespace='shared-staging')
    deployment = next(d for d in documents if d['kind'] == 'Deployment')
    pod = deployment['spec']['template']['spec']
    assert pod['automountServiceAccountToken'] is False
    assert pod['securityContext']['runAsNonRoot'] is True
    container = pod['containers'][0]
    assert container['securityContext']['readOnlyRootFilesystem'] is True
    assert container['readinessProbe']['httpGet']['path'] == '/readyz'
    assert container['livenessProbe']['httpGet']['path'] == '/healthz'
    assert container['resources']['limits']['memory'] == '256Mi'
    assert container['image'].endswith('@sha256:' + 'a' * 64)
    assert container['envFrom'] == [{'secretRef': {'name': 'data-runtime'}}]
    assert 'MIGRATION' not in json.dumps(documents)
    hpa = next(d for d in documents if d['kind'] == 'HorizontalPodAutoscaler')
    assert hpa['spec']['maxReplicas'] == 4
    assert next(d for d in documents if d['kind'] == 'PodDisruptionBudget')['spec']['minAvailable'] == 1


def test_autoscaling_allocation_is_checked_at_max_replicas():
    plan = release()
    plan['database_connection_budget'] = 16
    with pytest.raises(ValueError, match='connection budget'):
        api().render_kubernetes(plan, namespace='shared-staging')


def test_delivery_rejects_runtime_secrets_and_unbuilt_images():
    for change in [{'image': 'repo/data:latest'}, {'required_env': ['DATABASE_MIGRATION_DSN']},
                   {'max_replicas': 1}]:
        plan = release()
        plan['services'][0].update(change)
        with pytest.raises(ValueError):
            api().render_kubernetes(plan, namespace='shared-staging')


def test_bundle_manifest_detects_replaced_or_extra_wheels(tmp_path):
    wheels = tmp_path / 'wheels'
    wheels.mkdir()
    (wheels / 'synthetic-0.1-py3-none-any.whl').write_bytes(b'synthetic wheel')
    api().write_wheel_manifest(tmp_path, sources={'platform-data': 'a' * 40})
    assert api().verify_wheel_manifest(tmp_path) == []
    (wheels / 'synthetic-0.1-py3-none-any.whl').write_bytes(b'replaced wheel')
    assert api().verify_wheel_manifest(tmp_path)
    (wheels / 'extra-0.1-py3-none-any.whl').write_bytes(b'unreviewed wheel')
    assert api().verify_wheel_manifest(tmp_path)


def test_bundle_source_revision_refuses_dirty_checkout(tmp_path):
    subprocess.run(['git', 'init', '-q', str(tmp_path)], check=True)
    subprocess.run(['git', '-C', str(tmp_path), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.test',
                    'commit', '--allow-empty', '-qm', 'synthetic fixture'], check=True)
    assert len(api().source_revision(tmp_path)) == 40
    (tmp_path / 'unreviewed.py').write_text('unreviewed')
    with pytest.raises(ValueError, match='clean'):
        api().source_revision(tmp_path)


def test_runtime_requires_explicit_known_service_and_bounds(monkeypatch):
    try:
        runtime = importlib.import_module('shared_infra.runtime')
    except ModuleNotFoundError:
        pytest.fail('bounded shared-service launcher is missing')
    monkeypatch.setenv('PLATFORM_SERVICE', 'data')
    monkeypatch.setenv('DATABASE_POOL_MAX', '0')
    with pytest.raises(ValueError):
        runtime.app_factory()


def test_valid_runtime_constructs_instrumented_app_with_configured_deadline(monkeypatch):
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.hazmat.primitives import serialization
    runtime = importlib.import_module('shared_infra.runtime')
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.public_key().public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    for name, value in {'PLATFORM_SERVICE': 'data', 'DATABASE_POOL_MAX': '2', 'REQUEST_TIMEOUT_SECONDS': '7',
                        'DATABASE_URL': 'host=/nonexistent-shared-fixture dbname=fixture user=fixture',
                        'JWT_ISSUER': 'synthetic-test', 'JWT_AUDIENCE': 'platform-api', 'JWT_PUBLIC_KEY': pem}.items():
        monkeypatch.setenv(name, value)
    app = runtime.app_factory()
    assert app.state.platform_observation.service == 'data'
    guards = [m for m in app.user_middleware if 'request_timeout' in m.kwargs]
    assert len(guards) == 1 and guards[0].kwargs['request_timeout'] == 7
    app.state.database.close()
    app.state.platform_observation.close()
    monkeypatch.setenv('PLATFORM_SERVICE', '../../arbitrary')
    with pytest.raises(ValueError):
        runtime.app_factory()
