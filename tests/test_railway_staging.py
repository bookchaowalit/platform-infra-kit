"""Bounded hosted staging: no provider access and no production escape hatch."""
from datetime import datetime, timedelta, timezone
import importlib
import json
import os
import subprocess
import sys
from uuid import uuid4

import pytest


def runner():
    return importlib.import_module('shared_infra.railway_staging')


def environment():
    now = datetime.now(timezone.utc)
    return dict(RAILWAY_PROJECT_ID='74e1dc2e-a00c-4ce7-931d-a8f15039a1a8',
                RAILWAY_ENVIRONMENT_ID='d6178822-ac8b-4cb3-82f6-642c14163fa2',
                STAGING_RUN_ID=str(uuid4()), STAGING_STARTED_AT=now.isoformat(),
                STAGING_DEADLINE=(now+timedelta(minutes=20)).isoformat())


def test_guard_accepts_only_explicit_bounded_staging():
    config = runner().Config.from_env(environment())
    assert config.remaining() <= 1200
    assert set(config.urls) == {'workflow','data','developer','security'}


@pytest.mark.parametrize('key,value', [
    ('RAILWAY_PROJECT_ID','wrong'),('RAILWAY_ENVIRONMENT_ID','wrong'),
    ('STAGING_RUN_ID','not-uuid'),('STAGING_DEADLINE','2099-01-01T00:00:00+00:00'),
    ('STAGING_STARTED_AT','2026-10-15T10:00:00'),
    ('STAGING_API_URLS',json.dumps(dict(workflow='http://127.0.0.1:8080'))),
    ('PGHOSTADDR','127.0.0.1'),('PGSERVICE','synthetic-secret'),
])
def test_guard_denies_wrong_context_host_deadline_and_ambient_pg(key,value):
    env = environment(); env[key] = value
    with pytest.raises(ValueError):
        runner().Config.from_env(env)


def test_dsn_rejects_indirection_and_other_resources():
    config = runner().Config.from_env(environment())
    for dsn in ('host=example.com dbname=postgres user=fixture password=synthetic-secret',
                'host=staging-postgres.railway.internal hostaddr=127.0.0.1 dbname=postgres user=fixture',
                'host=staging-postgres.railway.internal dbname=postgres user=fixture service=secret'):
        with pytest.raises(ValueError):
            config.dsn(dsn,admin=True)
    safe = config.dsn('host=staging-postgres.railway.internal port=5432 dbname=railway user=postgres password=synthetic-secret',admin=True)
    assert 'passfile=/dev/null' in safe


def test_cli_driver_errors_never_echo_secret():
    env = dict(os.environ,**environment(),STAGING_ADMIN_DSN='password=synthetic-secret invalid',
               STAGING_ROLE_PASSWORDS='{}')
    result = subprocess.run([sys.executable,'-m','shared_infra.railway_staging','bootstrap'],env=env,
                            capture_output=True,text=True)
    assert result.returncode == 1
    assert 'synthetic-secret' not in result.stdout+result.stderr
    assert json.loads(result.stdout)['status']=='failed'
    assert 'Traceback' not in result.stderr


def test_bootstrap_real_login_roles_and_fail_closed_existing():
    from psycopg import connect,sql
    from psycopg.conninfo import make_conninfo
    module = runner()
    config = module.Config.from_env(environment())
    admin = os.environ['PLATFORM_TEST_DSN']
    passwords = {name:'fixture-only-password-'+uuid4().hex for name in module.ROLE_KEYS}
    try:
        result = module.provision(config,admin,passwords)
        assert result['status']=='bootstrapped'
        for service in module.SERVICES:
            role = config.role(service+'_api')
            with connect(make_conninfo(admin,dbname=config.database(service),user=role,password=passwords[service+'_api'])) as conn:
                assert conn.execute('SELECT session_user=current_user').fetchone()==(True,)
                assert conn.execute('SELECT rolcanlogin,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolconnlimit FROM pg_roles WHERE rolname=current_user').fetchone()==(True,False,False,False,False,4)
                assert conn.execute("SELECT has_schema_privilege('public','CREATE')").fetchone()==(False,)
                assert conn.execute('SELECT namespace FROM platform_schema_migrations').fetchone()[0]==module.NAMESPACES[service]
                if service=='workflow':
                    from contextlib import ExitStack
                    import psycopg
                    with ExitStack() as connections:
                        for _ in range(3):
                            connections.enter_context(connect(make_conninfo(admin,dbname=config.database(service),user=role,password=passwords[service+'_api'])))
                        with pytest.raises(psycopg.OperationalError):
                            connect(make_conninfo(admin,dbname=config.database(service),user=role,password=passwords[service+'_api']))
        with pytest.raises(ValueError):
            module.provision(config,admin,passwords)
        with connect(make_conninfo(admin,dbname=config.database('workflow'),user=config.role('workflow_worker'),password=passwords['workflow_worker'])) as conn:
            assert conn.execute('SELECT rolconnlimit FROM pg_roles WHERE rolname=current_user').fetchone()==(2,)
            assert conn.execute("SELECT has_table_privilege('workflow_jobs','INSERT')").fetchone()==(False,)
    finally:
        # Fixture cleanup is explicit and only names generated by this test's UUID.
        with connect(admin,autocommit=True) as conn:
            for service in module.SERVICES:
                conn.execute(sql.SQL('DROP DATABASE IF EXISTS {} WITH (FORCE)').format(sql.Identifier(config.database(service))))
            for name in module.ROLE_KEYS:
                conn.execute(sql.SQL('DROP ROLE IF EXISTS {}').format(sql.Identifier(config.role(name))))


def _fixture_serve(service,dsn,config,public_key,listener):
    """Internal test seam only; CLI cannot supply these loopback URL overrides."""
    import uvicorn
    from shared_infra.runtime import app_factory
    os.environ.update(PLATFORM_SERVICE=service,DATABASE_URL=dsn,DATABASE_POOL_MAX='2',
                      DATABASE_CONNECTION_CEILING='4',JWT_ISSUER=config.issuer,
                      JWT_AUDIENCE=runner().AUDIENCE,JWT_PUBLIC_KEY=public_key)
    app=app_factory()
    uvicorn.Server(uvicorn.Config(app,log_level='critical',access_log=False,timeout_graceful_shutdown=1)).run(sockets=[listener])


def _fixture_worker(config,dsn,stop,authorizations,public_key):
    from platform_backend_core import TokenVerifier
    runner().worker(config,dsn,stop,authorizations,TokenVerifier(issuer=config.issuer,audience=runner().AUDIENCE,public_key=public_key))


def test_real_http_probe_restart_and_restored_rows(tmp_path):
    from dataclasses import replace
    import multiprocessing
    import socket
    import time
    import httpx
    from psycopg import connect,sql
    from psycopg.conninfo import make_conninfo
    from shared_infra.fixtures import Authority
    module = runner()
    config = module.Config.from_env(environment())
    admin = os.environ['PLATFORM_TEST_DSN']
    authority = Authority.generate()
    passwords = {name:'fixture-only-'+uuid4().hex for name in module.ROLE_KEYS}
    processes=[]; listeners=[]; stop=None; probe=None
    context = multiprocessing.get_context('spawn')
    try:
        module.provision(config,admin,passwords)
        def runtime(service,worker=False):
            name = 'workflow_worker' if worker else service+'_api'
            return make_conninfo(admin,dbname=config.database(service),user=config.role(name),password=passwords[name])
        urls={}
        for service in module.SERVICES:
            listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(128)
            listeners.append(listener)
            urls[service]='http://127.0.0.1:'+str(listener.getsockname()[1])
        # Config.from_env never accepts these; only this internal function fixture does.
        config=replace(config,urls=urls)
        for service,listener in zip(module.SERVICES,listeners):
            process=context.Process(target=_fixture_serve,args=(service,runtime(service),config,authority.public_key,listener))
            process.start(); processes.append(process)
        with httpx.Client(trust_env=False,timeout=.5) as client:
            end=time.monotonic()+20
            for service in module.SERVICES:
                while True:
                    try:
                        if client.get(urls[service]+'/readyz').status_code==200: break
                    except httpx.TransportError: pass
                    assert time.monotonic()<end
                    time.sleep(.05)
        import jwt
        auth={tenant:'Bearer '+jwt.encode(dict(sub=str(uuid4()),ws=str(config.workspace(tenant)),scope='jobs:work',iss=config.issuer,aud=module.AUDIENCE,iat=datetime.now(timezone.utc),exp=config.deadline,jti=str(uuid4())),authority.private_key,algorithm='RS256') for tenant in ('a','b')}
        probe=module.Probe(config,authority.private_key)
        seeded=probe.seed()
        stop=context.Event()
        process=context.Process(target=_fixture_worker,args=(config,runtime('workflow',True),stop,auth,authority.public_key))
        process.start(); processes.append(process)
        end=time.monotonic()+15
        while probe.request('workflow','GET','/v1/jobs/'+seeded['restart_job']).json()['status']!='running':
            assert time.monotonic()<end; time.sleep(.05)
        stop.set(); process.join(5); assert process.exitcode==0
        stop=context.Event()
        process=context.Process(target=_fixture_worker,args=(config,runtime('workflow',True),stop,auth,authority.public_key))
        process.start(); processes.append(process)
        result=probe.verify_restart(seeded['restart_job'],seeded['other_workspace_job'])
        assert result['attempts']==2 and result['post_traffic_readiness']==12
        result=probe.run('baseline')
        assert result['jobs']==100 and result['admitted']==7 and result['overshoot']==0
        assert result['counter']==100 and result['post_traffic_readiness']==12
        assert result['stale_ack_status']==409
        scaled=probe.run('scaled')
        assert scaled['jobs']==1000 and scaled['counter']==1000 and scaled['admitted']==7
        assert scaled['stale_ack_status']==409 and scaled['post_traffic_readiness']==12
        stop.set(); process.join(5); assert process.exitcode==0
        restored=module.backup_restore(config,admin,__import__('pathlib').Path(os.environ['PLATFORM_PG_BIN']))
        assert restored['database']==config.database('restored')
        # Reopen the restored database through a newly started actual HTTP service.
        listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(128); listeners.append(listener)
        restored_dsn=make_conninfo(runtime('workflow'),dbname=config.database('restored'))
        process=context.Process(target=_fixture_serve,args=('workflow',restored_dsn,config,authority.public_key,listener))
        process.start(); processes.append(process)
        restored_url='http://127.0.0.1:'+str(listener.getsockname()[1])
        with httpx.Client(trust_env=False,timeout=.5) as client:
            end=time.monotonic()+15
            while True:
                try:
                    if client.get(restored_url+'/readyz').status_code==200: break
                except httpx.TransportError: pass
                assert time.monotonic()<end; time.sleep(.05)
        probe.close(); probe=module.Probe(replace(config,urls={**urls,'workflow':restored_url}),authority.private_key)
        assert probe.verify_restart(seeded['restart_job'],seeded['other_workspace_job'],restored=True)['status']=='restored-verified'
        # Read-only verification must reject a missing checkpoint rather than enqueue it.
        with pytest.raises(RuntimeError):
            probe.verify_restart(str(uuid4()),seeded['other_workspace_job'],restored=True)
    finally:
        if stop is not None: stop.set()
        if probe: probe.close()
        for process in reversed(processes):
            if process.is_alive(): process.terminate()
            process.join(5)
            if process.is_alive(): process.kill(); process.join(5)
        for listener in listeners: listener.close()
        with connect(admin,autocommit=True) as conn:
            for service in (*module.SERVICES,'restored'):
                conn.execute(sql.SQL('DROP DATABASE IF EXISTS {} WITH (FORCE)').format(sql.Identifier(config.database(service))))
            for name in module.ROLE_KEYS:
                conn.execute(sql.SQL('DROP ROLE IF EXISTS {}').format(sql.Identifier(config.role(name))))


def test_worker_refuses_forged_or_wrong_workspace_jwt_before_claim():
    from platform_backend_core import TokenVerifier
    from shared_infra.fixtures import Authority
    from threading import Event
    import jwt
    config=runner().Config.from_env(environment())
    authority=Authority.generate()
    verifier=TokenVerifier(issuer=config.issuer,audience=runner().AUDIENCE,public_key=authority.public_key)
    # A valid signature for a foreign workspace must not authorize this poll.
    now=datetime.now(timezone.utc)
    auth={tenant:'Bearer '+jwt.encode(dict(sub=str(uuid4()),ws=str(uuid4()),scope='jobs:work',
         iss=config.issuer,aud=runner().AUDIENCE,iat=now,exp=config.deadline,jti=str(uuid4())),authority.private_key,algorithm='RS256') for tenant in ('a','b')}
    with pytest.raises(ValueError):
        runner().worker(config,os.environ['PLATFORM_TEST_DSN'],Event(),auth,verifier)


def test_shared_deadline_terminates_blocked_operator_without_secret_output():
    env=dict(os.environ,**environment())
    env['STAGING_DEADLINE']=(datetime.now(timezone.utc)+timedelta(seconds=1)).isoformat()
    env['STAGING_JWT_PRIVATE_KEY']='synthetic-secret'
    code="from shared_infra import railway_staging as r; import time; r.Probe=lambda *a: None; r.provision=lambda *a: time.sleep(30); r.Config.dsn=lambda *a,**k: 'redacted'; raise SystemExit(r.main(['bootstrap']))"
    env['STAGING_ADMIN_DSN']='synthetic-secret'; env['STAGING_ROLE_PASSWORDS']='{}'
    result=subprocess.run([sys.executable,'-c',code],env=env,capture_output=True,text=True,timeout=5)
    assert result.returncode==0
    assert json.loads(result.stdout)['status']=='deadline-reached'
    assert 'synthetic-secret' not in result.stdout+result.stderr


def test_dual_stack_listener_accepts_private_ipv6_and_ipv4():
    import socket
    # Reserve a free port, then exercise the same production listener implementation.
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
    listener=runner().dual_stack_listener(port)
    try:
        assert listener.getsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY)==0
        for address in ('127.0.0.1','::1'):
            with socket.create_connection((address,port),timeout=1): pass
    finally: listener.close()


def test_unknown_cli_argument_is_redacted():
    result=subprocess.run([sys.executable,'-m','shared_infra.railway_staging','synthetic-secret'],
                          capture_output=True,text=True)
    assert result.returncode==1
    assert json.loads(result.stdout)['status']=='failed'
    assert 'synthetic-secret' not in result.stdout+result.stderr
