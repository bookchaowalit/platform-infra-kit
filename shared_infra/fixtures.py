"""Explicit disposable local fixtures. No credentials or live providers are discovered."""
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import importlib
import ipaddress
import multiprocessing
import os
import secrets
import socket
import time
from uuid import uuid4

import httpx
import jwt
import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from platform_backend_core import Database, MigrationRunner, TokenVerifier
from platform_backend_core.testing import temporary_database

SERVICES = ('workflow','data','developer','security','communication','media','payment')
SCOPES = ('jobs:read','jobs:write','jobs:work','cache:read','cache:write','counters:write',
          'documents:read','documents:write','quotas:write','quotas:reserve','quotas:settle',
          'flags:read','flags:write','references:read','references:write','audit:read','audit:write',
          'messages:read','messages:write','files:read','files:write','payments:read','payments:write')
ISSUER = 'https://issuer.acceptance.invalid'
AUDIENCE = 'shared-infrastructure-acceptance'


def validate_local_admin_dsn(dsn):
    # Reject by variable name without inspecting or echoing any ambient values.
    if any(name.startswith('PG') for name in os.environ):
        raise ValueError('ambient PostgreSQL settings are forbidden for local fixtures')
    if not isinstance(dsn,str) or not dsn:
        raise ValueError('explicit local fixture admin DSN required')
    fields = conninfo_to_dict(dsn)
    if 'service' in fields or 'servicefile' in fields:
        raise ValueError('fixture DSN must not resolve an external service definition')
    host = fields.get('host','')
    if fields.get('hostaddr'):
        hosts = (host,fields['hostaddr'])
    else:
        hosts = (host,)
    for candidate in hosts:
        if ',' in candidate:
            raise ValueError('fixture DSN must select exactly one local host')
        if candidate.startswith('/'):
            continue
        try:
            local = ipaddress.ip_address(candidate).is_loopback
        except ValueError:
            local = False
        if not local:
            raise ValueError('only explicit Unix socket or loopback fixture databases are allowed')
    if not fields.get('dbname') or not fields.get('user'):
        raise ValueError('explicit fixture database and admin role required')
    return make_conninfo(dsn,passfile=os.devnull)


@dataclass
class Authority:
    private_key: object
    public_key: str

    @classmethod
    def generate(cls):
        key = rsa.generate_private_key(public_exponent=65537,key_size=2048)
        public = key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
        return cls(key,public)

    def authorization(self,workspace, *, actor=None, scopes=SCOPES):
        now = datetime.now(timezone.utc)
        token = jwt.encode({'sub':str(actor or uuid4()),'ws':str(workspace),'scope':' '.join(scopes),
            'iss':ISSUER,'aud':AUDIENCE,'iat':now,'exp':now+timedelta(minutes=30),'jti':str(uuid4())},
            self.private_key,algorithm='RS256')
        return 'Bearer '+token


def verifier(public_key):
    return TokenVerifier(issuer=ISSUER,audience=AUDIENCE,public_key=public_key)


def service_migrations(service):
    module = importlib.import_module('platform_'+service+'.migrations')
    return module.migrations() if service == 'workflow' else module.MIGRATIONS


def migration_namespace(service):
    if service == 'developer':
        return 'flags'
    return 'platform_'+service if service in {'media','payment'} else service


def grant_runtime(database,service):
    database.grant_schema()
    if service == 'security':
        with psycopg.connect(database.admin_dsn) as conn:
            conn.execute(sql.SQL('REVOKE UPDATE,DELETE,TRUNCATE ON security_audit FROM {}').format(sql.Identifier(database.runtime_role)))


@contextmanager
def service_database(admin_dsn,service):
    if service not in SERVICES:
        raise ValueError('unknown fixture service')
    admin_dsn = validate_local_admin_dsn(admin_dsn)
    with temporary_database(admin_dsn,prefix='accept_'+service[:8]+'_') as database:
        MigrationRunner(database.admin_dsn,namespace=migration_namespace(service)).apply(service_migrations(service))
        grant_runtime(database,service)
        with psycopg.connect(database.runtime_dsn) as conn:
            row = conn.execute('SELECT rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user').fetchone()
            if row != (False,False):
                raise AssertionError('fixture runtime role bypasses tenant security')
        yield database


class LocalObjectStore:
    """Synthetic object metadata fixture, never a real object upload/provider."""
    def __init__(self):
        self.objects = {}

    def presign_put(self,key,content_type,size,checksum,expires):
        self.objects[key] = {'size':size,'content_type':content_type,'checksum_sha256':checksum}
        return {'url':'https://object.acceptance.invalid/fixture','headers':{}}

    def head(self,key):
        return self.objects.get(key)

    def presign_get(self,key,expires):
        return 'https://object.acceptance.invalid/fixture'

    def delete(self,key):
        self.objects.pop(key,None)


class LocalPaymentProvider:
    name = 'acceptance'

    def create(self,*,amount,currency,reference,idempotency_key,checkout):
        return {'id':'fixture_'+reference,'status':'pending','checkout_url':None}

    def verify_event(self,payload,signature):
        raise ValueError('fixture webhook delivery is disabled')


class LocalDeliveryAdapter:
    configured = True

    def send(self,message):
        return 'fixture_'+str(message['id'])


def build_app(service,dsn,public_key,metrics_token):
    database = Database(dsn,max_size=4)
    verify = verifier(public_key)
    module = importlib.import_module('platform_'+service+'.app')
    if service == 'workflow':
        app = module.create_workflow_app(database,verify)
    elif service == 'communication':
        app = module.create_app(database,verify,adapters={'email':LocalDeliveryAdapter()})
    elif service == 'media':
        app = module.create_app(database,verify,object_store=LocalObjectStore())
    elif service == 'payment':
        app = module.create_app(database,verify,provider=LocalPaymentProvider(),plan_catalog={})
    else:
        app = module.create_app(database,verify)
    from platform_observability import instrument
    return instrument(app,service_name='acceptance-'+service,metrics_token=metrics_token)


def _serve(service,dsn,public_key,metrics_token,listener):
    # Never print provider payloads, connection strings, authorization or startup exceptions.
    try:
        import uvicorn
        app = build_app(service,dsn,public_key,metrics_token)
        config = uvicorn.Config(app,log_level='critical',access_log=False,timeout_graceful_shutdown=5)
        uvicorn.Server(config).run(sockets=[listener])
    except Exception:
        raise SystemExit(2) from None


@dataclass
class ApiProcess:
    service: str
    url: str
    process: object
    metrics_token: str


@contextmanager
def api_process(service,dsn,public_key, *, metrics_token=None):
    context = multiprocessing.get_context('spawn')
    listener = socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    listener.bind(('127.0.0.1',0))
    listener.listen(128)
    port = listener.getsockname()[1]
    token = metrics_token or secrets.token_urlsafe(24)
    process = context.Process(target=_serve,args=(service,dsn,public_key,token,listener))
    process.start()
    url = f'http://127.0.0.1:{port}'
    try:
        deadline = time.monotonic()+20
        with httpx.Client(timeout=.5,trust_env=False) as client:
            while True:
                if not process.is_alive():
                    raise RuntimeError('fixture API failed to start: '+service)
                try:
                    if client.get(url+'/readyz').status_code == 200:
                        break
                except httpx.TransportError:
                    pass
                if time.monotonic() >= deadline:
                    raise RuntimeError('fixture API readiness timed out: '+service)
                time.sleep(.05)
        listener.close()
        yield ApiProcess(service,url,process,token)
    finally:
        listener.close()
        if process.is_alive():
            process.terminate()
        process.join(10)
        if process.is_alive():
            process.kill()
            process.join(5)
