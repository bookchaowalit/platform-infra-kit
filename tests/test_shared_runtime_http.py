import os

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo

from fastapi.testclient import TestClient

from shared_infra.fixtures import Authority, AUDIENCE, ISSUER, service_database
from shared_infra.runtime import app_factory
from uuid import uuid4


def test_release_launcher_serves_verified_isolated_data_and_authenticated_metrics(monkeypatch):
    authority = Authority.generate()
    with service_database(os.environ['PLATFORM_TEST_DSN'], 'data') as database:
        with psycopg.connect(database.admin_dsn) as connection:
            connection.execute(sql.SQL('ALTER ROLE {} LOGIN CONNECTION LIMIT 2').format(sql.Identifier(database.runtime_role)))
        login_dsn = make_conninfo(database.admin_dsn,user=database.runtime_role,options='')
        for name, value in {'PLATFORM_SERVICE': 'data', 'DATABASE_URL': login_dsn,
                            'DATABASE_CONNECTION_CEILING': '2',
                            'DATABASE_POOL_MAX': '2', 'REQUEST_TIMEOUT_SECONDS': '2.5',
                            'JWT_ISSUER': ISSUER, 'JWT_AUDIENCE': AUDIENCE,
                            'JWT_PUBLIC_KEY': authority.public_key,
                            'METRICS_TOKEN': 'synthetic-metrics-token'}.items():
            monkeypatch.setenv(name, value)
        app = app_factory()
        with TestClient(app) as client:
            assert client.get('/readyz').status_code == 200
            headers = {'Authorization': authority.authorization(uuid4())}
            assert client.put('/v1/cache/release-probe', headers=headers,
                              json={'value': {'synthetic': True}, 'ttl_seconds': 60}).status_code == 200
            assert client.get('/v1/cache/release-probe', headers=headers).json()['value'] == {'synthetic': True}
            foreign = {'Authorization': authority.authorization(uuid4())}
            assert client.get('/v1/cache/release-probe', headers=foreign).status_code == 404
            assert client.get('/metrics').status_code == 401
            metrics = client.get('/metrics', headers={'Authorization': 'Bearer synthetic-metrics-token'})
            assert metrics.status_code == 200 and '/v1/cache/{key}' in metrics.text
