"""Explicit bounded launcher for installed service wheels, without startup DDL."""
import argparse
import importlib
import math
import os
from uuid import UUID

SERVICES = ('workflow', 'data', 'developer', 'security', 'communication', 'media', 'payment')


def _service():
    service = os.environ.get('PLATFORM_SERVICE')
    if service not in SERVICES:
        raise ValueError('explicit supported PLATFORM_SERVICE required')
    return service


def _bounded(name, default, minimum, maximum):
    value = int(os.environ.get(name, str(default)))
    if not minimum <= value <= maximum:
        raise ValueError('resource bound outside permitted range')
    return value


def app_factory():
    from platform_backend_core import Database, TokenVerifier
    from platform_observability import instrument
    service = _service()
    maximum = _bounded('DATABASE_POOL_MAX', 8, 1, 64)
    timeout = float(os.environ.get('REQUEST_TIMEOUT_SECONDS', '30'))
    if not math.isfinite(timeout) or not 0 < timeout <= 300:
        raise ValueError('invalid request timeout')
    verifier = TokenVerifier(issuer=os.environ['JWT_ISSUER'], audience=os.environ['JWT_AUDIENCE'],
                             public_key=os.environ.get('JWT_PUBLIC_KEY'), jwks_url=os.environ.get('JWT_JWKS_URL'))
    database = Database(os.environ['DATABASE_URL'], max_size=maximum,
                        timeout=_bounded('DATABASE_POOL_TIMEOUT_SECONDS', 5, 1, 30),
                        statement_timeout_ms=_bounded('DATABASE_STATEMENT_TIMEOUT_MS', 10000, 100, 60000))
    try:
        if service == 'workflow':
            from platform_workflow.app import create_workflow_app
            app = create_workflow_app(database, verifier)
        else:
            module = importlib.import_module('platform_' + service + '.app')
            kwargs = {}
            if service == 'data':
                system = os.environ.get('PLATFORM_SYSTEM_WORKSPACE_ID')
                kwargs['system_workspace'] = UUID(system) if system else None
            app = module.create_app(database, verifier, **kwargs)
        # Core installs the deadline middleware at factory time; set its
        # constructor argument before the ASGI stack is first built.
        guards = 0
        for middleware in app.user_middleware:
            if middleware.cls.__module__ == 'platform_backend_core.http' and 'request_timeout' in middleware.kwargs:
                middleware.kwargs['request_timeout'] = timeout
                guards += 1
        if guards != 1:
            raise ValueError('unsupported core HTTP boundary version')
        return instrument(app, service_name=service, metrics_token=os.environ.get('METRICS_TOKEN'),
                          endpoint=os.environ.get('OTEL_TRACES_ENDPOINT'))
    except BaseException:
        database.close()
        raise


def migrate():
    from platform_backend_core import MigrationRunner
    service = _service()
    module = importlib.import_module('platform_' + service + '.migrations')
    migrations = module.migrations() if service == 'workflow' else module.MIGRATIONS
    namespace = ('platform_' + service if service in {'media', 'payment'}
                 else 'flags' if service == 'developer' else service)
    applied = MigrationRunner(os.environ['DATABASE_MIGRATION_DSN'], namespace=namespace).apply(migrations)
    print(f'applied {len(applied)} migration(s)')


def main():
    parser = argparse.ArgumentParser(description='Shared service runtime')
    parser.add_argument('command', choices=['serve', 'migrate'])
    args = parser.parse_args()
    try:
        if args.command == 'migrate':
            migrate()
            return
        import uvicorn
        uvicorn.run(app_factory(), host='0.0.0.0', port=_bounded('PORT', 8080, 1, 65535),
                    access_log=False, proxy_headers=False, limit_concurrency=64,
                    timeout_keep_alive=5, timeout_graceful_shutdown=30)
    except Exception:
        raise SystemExit('shared service configuration or dependency unavailable') from None


if __name__ == '__main__':
    main()
