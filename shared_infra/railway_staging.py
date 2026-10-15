"""A bounded synthetic Railway test. This module never invokes a provider API."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import importlib
import json
import logging
import os
from pathlib import Path
import signal
import socket
import statistics
import threading
import time
import warnings
from uuid import UUID, uuid5

import httpx
import jwt
import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo
from platform_backend_core import Database, MigrationRunner, TokenVerifier

PROJECT = '74e1dc2e-a00c-4ce7-931d-a8f15039a1a8'
ENVIRONMENT = 'd6178822-ac8b-4cb3-82f6-642c14163fa2'
SERVICES = ('workflow','data','developer','security')
URLS = {service:f'http://{service}.railway.internal:8080' for service in SERVICES}
PG_HOST = 'staging-postgres.railway.internal'
NAMESPACES = dict(workflow='workflow',data='data',developer='flags',security='security')
ROLE_KEYS = tuple(service+'_api' for service in SERVICES)+('workflow_worker',)
TABLE_GRANTS = {
    'workflow': {'workflow_jobs':'SELECT,INSERT,UPDATE','workflow_attempts':'SELECT,INSERT,UPDATE'},
    'data': {table:'SELECT,INSERT,UPDATE,DELETE' for table in ('data_cache','data_counters','data_documents',
             'data_quota_policies','data_quota_buckets','data_reservations','data_service_admissions')},
    'developer': {'feature_flags':'SELECT,INSERT,UPDATE,DELETE'},
    'security': {'secret_references':'SELECT,INSERT,UPDATE','security_audit':'SELECT,INSERT'},
}
SCOPES = 'jobs:read jobs:write jobs:work counters:write quotas:write quotas:reserve quotas:settle flags:read flags:write audit:read audit:write'
AUDIENCE = 'shared-infrastructure-staging'


def utc(value):
    moment = datetime.fromisoformat(value.replace('Z','+00:00'))
    if moment.utcoffset() != timedelta(0):
        raise ValueError('explicit UTC timestamp required')
    return moment


@dataclass(frozen=True)
class Config:
    run: UUID
    started: datetime
    deadline: datetime
    urls: dict

    @classmethod
    def from_env(cls, env):
        if any(name.startswith('PG') for name in env):
            raise ValueError('ambient PostgreSQL settings forbidden')
        if env.get('RAILWAY_PROJECT_ID') != PROJECT or env.get('RAILWAY_ENVIRONMENT_ID') != ENVIRONMENT:
            raise ValueError('unapproved staging context')
        started, deadline = utc(env['STAGING_STARTED_AT']),utc(env['STAGING_DEADLINE'])
        now = datetime.now(timezone.utc)
        if not started <= now < deadline <= started+timedelta(minutes=45):
            raise ValueError('invalid staging time budget')
        urls = json.loads(env['STAGING_API_URLS']) if 'STAGING_API_URLS' in env else dict(URLS)
        if urls != URLS:
            raise ValueError('private staging API allowlist required')
        return cls(UUID(env['STAGING_RUN_ID']),started,deadline,urls)

    @property
    def issuer(self):
        return 'https://railway-staging.invalid/'+str(self.run)

    def remaining(self):
        remaining = (self.deadline-datetime.now(timezone.utc)).total_seconds()
        if remaining <= 0:
            raise TimeoutError('staging deadline')
        return remaining

    def database(self, service):
        if service not in (*SERVICES,'restored'):
            raise ValueError('unknown database')
        return 'stg_'+self.run.hex+'_'+service

    def role(self, name):
        if name not in ROLE_KEYS:
            raise ValueError('unknown role')
        return 'stg_'+self.run.hex+'_'+name

    def workspace(self, suffix):
        return uuid5(self.run,'workspace-'+suffix)

    def dsn(self, value, *, admin=False, service=None, worker=False):
        self.remaining()
        fields = conninfo_to_dict(value)
        allowed = {'host','port','dbname','user','password','sslmode','connect_timeout','passfile'}
        if (set(fields)-allowed or fields.get('host') != PG_HOST
                or fields.get('port','5432') != '5432'
                or not fields.get('user') or not fields.get('dbname') or not fields.get('password')
                or fields.get('passfile',os.devnull) != os.devnull):
            raise ValueError('explicit private staging DSN required')
        if not admin:
            if service not in SERVICES:
                raise ValueError('unknown service')
            databases = {self.database(service)}
            if service == 'workflow':
                databases.add(self.database('restored'))
            if fields['dbname'] not in databases or fields['user'] != self.role('workflow_worker' if worker else service+'_api'):
                raise ValueError('runtime staging identity mismatch')
        return make_conninfo(value,passfile=os.devnull,connect_timeout=5)


def migrations(service):
    module = importlib.import_module('platform_'+service+'.migrations')
    return module.migrations() if service == 'workflow' else module.MIGRATIONS


def grant(conn, service, role, *, worker=False):
    identifier = sql.Identifier(role)
    conn.execute(sql.SQL('GRANT USAGE ON SCHEMA public TO {}').format(identifier))
    conn.execute(sql.SQL('GRANT SELECT ON platform_schema_migrations TO {}').format(identifier))
    for table, privileges in TABLE_GRANTS[service].items():
        if worker and table == 'workflow_jobs':
            privileges = 'SELECT,UPDATE'
        conn.execute(sql.SQL('GRANT {} ON {} TO {}').format(sql.SQL(privileges),sql.Identifier(table),identifier))


def provision(config, admin_dsn, passwords):
    """Explicit operator-only DDL. Refuse collisions before creating any resource.

    Internal callers may inject a disposable test DSN; CLI always validates host.
    No runtime calls this function and failures never delete existing resources.
    """
    config.remaining()
    if set(passwords) != set(ROLE_KEYS) or any(not isinstance(value,str) or not 24 <= len(value) <= 200
                                             or not value.isascii() or not value.isprintable() for value in passwords.values()):
        raise ValueError('explicit fresh role passwords required')
    with psycopg.connect(admin_dsn,autocommit=True,connect_timeout=5) as conn:
        conn.execute("SELECT pg_advisory_lock(hashtextextended(%s,0))",('railway-staging:'+str(config.run),))
        if conn.execute('SELECT 1 FROM pg_roles WHERE rolname=ANY(%s)',([config.role(name) for name in ROLE_KEYS],)).fetchone() or conn.execute(
                'SELECT 1 FROM pg_database WHERE datname=ANY(%s)',([config.database(service) for service in (*SERVICES,'restored')],)).fetchone():
            raise ValueError('staging resource exists')
        for name in ROLE_KEYS:
            config.remaining()
            conn.execute(sql.SQL('CREATE ROLE {} LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT {} PASSWORD {}').format(
                sql.Identifier(config.role(name)),sql.Literal(2 if name=='workflow_worker' else 4),sql.Literal(passwords[name])))
        for service in SERVICES:
            config.remaining()
            conn.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(config.database(service))))
            conn.execute(sql.SQL('REVOKE ALL ON DATABASE {} FROM PUBLIC').format(sql.Identifier(config.database(service))))
            names = [service+'_api']+(['workflow_worker'] if service=='workflow' else [])
            for name in names:
                conn.execute(sql.SQL('GRANT CONNECT ON DATABASE {} TO {}').format(sql.Identifier(config.database(service)),sql.Identifier(config.role(name))))
    for service in SERVICES:
        config.remaining()
        dsn = make_conninfo(admin_dsn,dbname=config.database(service))
        MigrationRunner(dsn,namespace=NAMESPACES[service]).apply(migrations(service))
        with psycopg.connect(dsn,connect_timeout=5) as conn:
            conn.execute('REVOKE ALL ON SCHEMA public FROM PUBLIC')
            grant(conn,service,config.role(service+'_api'))
            if service == 'workflow':
                grant(conn,service,config.role('workflow_worker'),worker=True)
    return dict(status='bootstrapped',databases={service:config.database(service) for service in SERVICES},
                roles={name:config.role(name) for name in ROLE_KEYS})


def quota_window(now,deadline):
    """Choose a supported epoch-aligned period covering the entire remaining run.

    Clock samples come from the data service's counter timestamp. Ten seconds
    of margin cover request transit; no fixed hour/day boundary is assumed.
    """
    if now.tzinfo is None or deadline.tzinfo is None or not now < deadline <= now+timedelta(minutes=45):
        raise ValueError('invalid quota preflight interval')
    start=int((now-timedelta(seconds=10)).timestamp())
    end=int((deadline+timedelta(seconds=10)).timestamp())
    for window in range(31536000,31536000-32*3600,-3600):
        if start//window==end//window:
            return window
    raise ValueError('no stable supported quota period')


class Probe:
    """HTTP only: supplied service URLs are actual replicas' load-balanced addresses."""
    def __init__(self, config, private_key):
        self.config,self.key = config,private_key
        if isinstance(private_key,(str,bytes)):
            from cryptography.hazmat.primitives.serialization import load_pem_private_key
            self.key=load_pem_private_key(private_key.encode() if isinstance(private_key,str) else private_key,password=None)
        self.client = httpx.Client(timeout=10,trust_env=False,follow_redirects=False)
        self.timings = []
        self.actor = uuid5(config.run,'operator-actor')

    def close(self):
        self.client.close()

    def request(self,service,method,path,*,tenant='a',expected=(200,),key=None,body=None):
        remaining = self.config.remaining()
        now = datetime.now(timezone.utc)
        token = jwt.encode(dict(sub=str(self.actor),ws=str(self.config.workspace(tenant)),scope=SCOPES,
            iss=self.config.issuer,aud=AUDIENCE,jti=str(uuid5(self.config.run,str(time.time_ns()))),iat=now,exp=min(self.config.deadline,now+timedelta(minutes=10))),self.key,algorithm='RS256')
        headers = {'Authorization':'Bearer '+token}
        if key:
            headers['Idempotency-Key'] = key
        start = time.monotonic()
        response = self.client.request(method,self.config.urls[service]+path,headers=headers,json=body,
                                       timeout=min(10,remaining))
        self.timings.append((time.monotonic()-start)*1000)
        if response.status_code not in expected:
            raise RuntimeError('unexpected staging HTTP status')
        return response

    def ready(self):
        for _ in range(3):
            for service in SERVICES:
                self.request(service,'GET','/readyz')
        return 12

    def enqueue(self,key,*,kind='health.noop',tenant='a',queue='staging'):
        return self.request('workflow','POST','/v1/jobs',tenant=tenant,expected=(201,),key=key,
            body=dict(queue=queue,job_type=kind,payload={'run':str(self.config.run)},max_attempts=3)).json()

    def wait(self, ids, *, timeout=120):
        end = time.monotonic()+min(timeout,self.config.remaining())
        pending = dict(ids)
        while pending:
            for job_id, tenant in list(pending.items()):
                job = self.request('workflow','GET','/v1/jobs/'+job_id,tenant=tenant).json()
                if job['status']=='succeeded':
                    del pending[job_id]
                elif job['status'] in {'cancelled','dead'}:
                    raise RuntimeError('synthetic job did not succeed')
            if pending:
                if time.monotonic() >= end:
                    raise TimeoutError('synthetic worker drain timed out')
                time.sleep(.2)

    def restart_seed(self):
        return self.enqueue('restart-'+str(self.config.run),kind='staging.restart')

    def seed(self):
        job = self.restart_seed()
        other = self.enqueue('restore-b-'+str(self.config.run),tenant='b')
        return dict(status='seeded',restart_job=job['id'],other_workspace_job=other['id'])

    def verify_restart(self, restart_id, other_id, *, restored=False):
        # Verification is read-only: missing restored rows must never be re-created.
        restart_id, other_id = str(UUID(restart_id)),str(UUID(other_id))
        job = self.request('workflow','GET','/v1/jobs/'+restart_id).json()
        other = self.request('workflow','GET','/v1/jobs/'+other_id,tenant='b').json()
        self.wait({job['id']:'a',other['id']:'b'})
        job = self.request('workflow','GET','/v1/jobs/'+job['id']).json()
        if job['attempts'] != 2:
            raise AssertionError('restart must recover second attempt')
        for row, foreign in ((job,'b'),(other,'a')):
            self.request('workflow','GET','/v1/jobs/'+row['id'],tenant=foreign,expected=(404,))
        return dict(status='restored-verified' if restored else 'restart-verified',attempts=2,workspaces=2,
                    post_traffic_readiness=self.ready())

    def fencing(self, phase):
        job=self.enqueue('fence-'+str(self.config.run)+'-'+phase,queue='staging-fence')
        claim=dict(owner='staging-probe',queues=['staging-fence'],lease_seconds=1)
        first=self.request('workflow','POST','/v1/worker/claim',body=claim).json()
        if not first or first['id']!=job['id']:
            raise AssertionError('first fencing claim missing')
        time.sleep(min(1.2,self.config.remaining()))
        claim['lease_seconds']=30
        second=self.request('workflow','POST','/v1/worker/claim',body=claim).json()
        if not second or second['id']!=job['id'] or second['attempts']!=2:
            raise AssertionError('expired lease not recovered')
        path='/v1/worker/jobs/'+job['id']+'/complete'
        self.request('workflow','POST',path,expected=(409,),body=dict(lease_token=first['lease_token'],result={'ok':True}))
        self.request('workflow','POST',path,body=dict(lease_token=second['lease_token'],result={'ok':True}))
        self.request('workflow','POST',path,body=dict(lease_token=second['lease_token'],result={'ok':True}))
        return 409

    def run(self, phase):
        if phase not in {'baseline','scaled'}:
            raise ValueError('explicit baseline or scaled phase required')
        count = 100 if phase=='baseline' else 1000
        prefix = str(self.config.run)+'-'+phase
        self.timings=[]
        started = time.monotonic()
        self.ready()
        with ThreadPoolExecutor(max_workers=8) as pool:
            jobs = list(pool.map(lambda index:self.enqueue(prefix+'-'+str(index),tenant='a' if index%2==0 else 'b'),range(count)))
            # Concurrent duplicate admission must return exactly one durable ID.
            duplicates = list(pool.map(lambda _:self.enqueue(prefix+'-duplicate'),range(8)))
        if len({job['id'] for job in duplicates}) != 1 or len({job['id'] for job in jobs}) != count:
            raise AssertionError('durable admission mismatch')
        self.request('workflow','GET','/v1/jobs/'+jobs[0]['id'],tenant='b',expected=(404,))
        self.request('workflow','POST','/v1/jobs',expected=(409,),key=prefix+'-duplicate',
                     body=dict(queue='staging',job_type='health.noop',payload={'changed':True}))
        ids = {job['id']:('a' if index%2==0 else 'b') for index,job in enumerate(jobs)}
        ids[duplicates[0]['id']]='a'
        self.wait(ids)
        fenced=self.fencing(phase)
        counter = 'staging-'+phase+'-'+self.config.run.hex
        policy = counter+'-cap'
        clock=self.request('data','POST','/v1/counters/'+counter+'-clock/increment',body=dict(amount=1,window_seconds=3600)).json()
        sample=datetime.fromisoformat(clock['expires_at'].replace('Z','+00:00'))
        if sample.tzinfo is None:
            raise RuntimeError('database clock must include timezone')
        database_now=sample.astimezone(timezone.utc)-timedelta(seconds=clock['window_seconds'])
        window=quota_window(database_now,database_now+timedelta(seconds=self.config.remaining()))
        self.request('data','PUT','/v1/quotas/'+policy,body=dict(limit=7,window_seconds=window))
        def increment(_):
            return self.request('data','POST','/v1/counters/'+counter+'/increment',body=dict(amount=1,window_seconds=3600)).json()['value']
        def reserve(index):
            return self.request('data','POST','/v1/reservations',expected=(200,429),body=dict(policy=policy,units=1,
                idempotency_key=counter+'-'+str(index),ttl_seconds=120))
        with ThreadPoolExecutor(max_workers=8) as pool:
            counters = list(pool.map(increment,range(count)))
            reservations = list(pool.map(reserve,range(32)))
        admitted = [response for response in reservations if response.status_code==200]
        if len(admitted)!=7 or max(counters)!=count or len(set(counters))!=count:
            raise AssertionError('shared state overshoot or lost increment')
        foreign_counter=self.request('data','POST','/v1/counters/'+counter+'/increment',tenant='b',body=dict(amount=1,window_seconds=3600)).json()
        if foreign_counter['value']!=1:
            raise AssertionError('counter crossed workspace')
        self.request('data','POST','/v1/reservations/'+admitted[0].json()['id']+'/release',tenant='b',expected=(404,),body={})
        flag = 'staging-'+self.config.run.hex+'-'+phase
        self.request('developer','PUT','/v1/flags/'+flag,body=dict(enabled=True,rollout=10000,subjects=[]))
        evaluated=self.request('developer','POST','/v1/flags/'+flag+'/evaluate',body=dict(subject='synthetic')).json()
        if evaluated['enabled'] is not True:
            raise AssertionError('flag evaluation failed')
        self.request('developer','GET','/v1/flags/'+flag,tenant='b',expected=(404,))
        audit = dict(action='staging.test',target=flag)
        self.request('security','POST','/v1/audit',key=flag,body=audit,expected=(200,201))
        self.request('security','POST','/v1/audit',key=flag,body=audit,expected=(200,201))
        own=self.request('security','GET','/v1/audit').json()
        if sum(row['target']==flag for row in own)!=1:
            raise AssertionError('audit idempotency failed')
        foreign = self.request('security','GET','/v1/audit',tenant='b').json()
        if foreign:
            raise AssertionError('audit crossed workspace')
        ready = self.ready()
        elapsed = time.monotonic()-started
        values = sorted(self.timings)
        return dict(status='probe-passed',phase=phase,jobs=count,duplicate_jobs=1,stale_ack_status=fenced,admitted=7,overshoot=0,
                    counter=count,workspaces=2,post_traffic_readiness=ready,
                    measurements=dict(count=len(values),errors=0,p50_ms=round(statistics.median(values),3),
                                      p95_ms=round(values[min(len(values)-1,int(len(values)*.95))],3),
                                      throughput_per_second=round(len(values)/elapsed,3)),
                    capacity_scope='this bounded staging run only')


def worker(config, dsn, stop, authorizations, verifier):
    """Only trusted synthetic handlers; polling is restricted to two explicit workspaces."""
    from platform_workflow.store import JobStore
    if set(authorizations)!={'a','b'}:
        raise ValueError('explicit two-workspace worker authorization required')
    for tenant in ('a','b'):
        principal=verifier.verify(authorizations[tenant])
        if principal.workspace!=config.workspace(tenant) or principal.scopes!=frozenset({'jobs:work'}):
            raise ValueError('worker JWT workspace or scope mismatch')
    database = Database(dsn,max_size=2)
    store = JobStore(database)
    try:
        with database.transaction(config.workspace('a')) as conn:
            safe=conn.execute('SELECT session_user=current_user AND rolcanlogin AND NOT rolsuper AND NOT rolbypassrls AND NOT rolcreatedb AND NOT rolcreaterole AND rolconnlimit BETWEEN 1 AND 2 FROM pg_roles WHERE rolname=current_user').fetchone()
            if safe!=(True,):
                raise ValueError('bounded actual worker LOGIN required')
        while not stop.is_set():
            config.remaining()
            found = False
            for tenant in ('a','b'):
                principal = verifier.verify(authorizations[tenant])
                if principal.workspace != config.workspace(tenant) or principal.scopes != frozenset({'jobs:work'}):
                    raise ValueError('worker JWT workspace or scope mismatch')
                job = store.claim(principal,owner='staging-'+str(os.getpid()),queues=['staging'],lease_seconds=10)
                if not job:
                    continue
                found = True
                if job['payload'] != {'run':str(config.run)} or job['job_type'] not in {'health.noop','staging.restart'}:
                    store.fail(principal,job['id'],lease_token=job['lease_token'],error_code='unsupported_staging_job')
                    continue
                if job['job_type']=='staging.restart' and job['attempts']==1:
                    checkpoint(config,dict(status='restart-held',job_id=str(job['id']),attempts=1))
                    while not stop.wait(.2):
                        config.remaining()
                    return  # Deliberately leave the attempt unacknowledged for actual process restart.
                store.complete(principal,job['id'],lease_token=job['lease_token'],result={'ok':True})
            if not found:
                stop.wait(.1)
    finally:
        database.close()


def backup_restore(config,admin_dsn,pg_bin):
    from tempfile import TemporaryDirectory
    from .recovery import create_backup,restore_backup
    config.remaining()
    source = make_conninfo(admin_dsn,dbname=config.database('workflow'))
    with TemporaryDirectory(prefix='staging-backup-') as directory:
        backup = create_backup(source,Path(directory)/'workflow.dump',pg_bin=pg_bin)
        config.remaining()
        restored = restore_backup(admin_dsn,backup,target_database=config.database('restored'),pg_bin=pg_bin)
    with psycopg.connect(admin_dsn,autocommit=True) as conn:
        conn.execute(sql.SQL('REVOKE ALL ON DATABASE {} FROM PUBLIC').format(sql.Identifier(config.database('restored'))))
        conn.execute(sql.SQL('GRANT CONNECT ON DATABASE {} TO {}').format(sql.Identifier(config.database('restored')),sql.Identifier(config.role('workflow_api'))))
    with psycopg.connect(restored) as conn:
        conn.execute('REVOKE ALL ON SCHEMA public FROM PUBLIC')
        grant(conn,'workflow',config.role('workflow_api'))
    return dict(status='backup-restored',database=config.database('restored'),requires='drain-and-repoint-workflow-api')


def authority(config,env):
    if env.get('JWT_ISSUER') != config.issuer or env.get('JWT_AUDIENCE') != AUDIENCE or env.get('JWT_JWKS_URL') or not env.get('JWT_PUBLIC_KEY'):
        raise ValueError('explicit staging public-key authority required')
    return TokenVerifier(issuer=config.issuer,audience=AUDIENCE,public_key=env['JWT_PUBLIC_KEY'])


def dual_stack_listener(port):
    if not 1 <= port <= 65535:
        raise ValueError('invalid port')
    listener=socket.socket(socket.AF_INET6,socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0)
        listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        listener.bind(('::',port))
        listener.listen(128)
        listener.setblocking(False)
        return listener
    except BaseException:
        listener.close()
        raise


def serve(config, env):
    import uvicorn
    from .runtime import app_factory
    service = env['PLATFORM_SERVICE']
    if service not in SERVICES or env.get('DATABASE_POOL_MAX')!='2' or env.get('DATABASE_CONNECTION_CEILING')!='4':
        raise ValueError('bounded capability runtime required')
    os.environ['DATABASE_URL'] = config.dsn(env['DATABASE_URL'],service=service)
    authority(config,env)
    if not env.get('JWT_PUBLIC_KEY') or env.get('OTEL_TRACES_ENDPOINT'):
        raise ValueError('public-key staging runtime required')
    # Generic launcher retains service schema/RLS and actual LOGIN role-cap checks.
    server = uvicorn.Server(uvicorn.Config(app_factory(),host='0.0.0.0',port=int(env.get('PORT','8080')),
        access_log=False,log_level='critical',proxy_headers=False,limit_concurrency=32,timeout_graceful_shutdown=2))
    expired=threading.Event()
    def expire():
        expired.set()
        server.should_exit = True
    listener=dual_stack_listener(int(env.get('PORT','8080')))
    timer = threading.Timer(max(.01,config.remaining()-3),expire)
    timer.daemon = True
    timer.start()
    try:
        server.run(sockets=[listener])
        if expired.is_set():
            raise StagingDeadline()
    finally:
        timer.cancel()
        listener.close()


def checkpoint(config, data):
    print(json.dumps(dict(schema='solo-empire.railway-staging.v1',run=str(config.run),**data),separators=(',',':')),flush=True)


class StagingDeadline(BaseException):
    """Unwind supported subprocess.run contexts so they kill and reap the tool."""


class DirectChildDeadline:
    """Linux CLI guard independent of Popen construction and main-thread signals.

    Only children owned by this process can be signalled/reaped. Pidfds bind the
    kernel process identity; procfs candidates alone never authorize a signal.
    Existing children are pinned and excluded, including across numeric PID reuse.
    """
    def __init__(self,config):
        self.deadline=config.deadline
        self.expired=threading.Event()
        self.baseline={}
        children=self.preflight()
        for pid in children:
            fd=self._owned_child(pid)
            if fd is not None:
                self.baseline[pid]=fd  # Held through process exit; CLOEXEC pidfds.

    @classmethod
    def preflight(cls):
        """Side-effect-free capability check: no watchdog, children or DB work."""
        children=cls._direct_children()
        fd=os.pidfd_open(os.getpid())
        try:
            if cls._pidfd_pid(fd)!=os.getpid():
                raise RuntimeError('matching procfs PID namespace required')
            signal.pidfd_send_signal(fd,0,None,0)
            try:
                os.waitid(os.P_PIDFD,fd,os.WEXITED|os.WNOHANG|os.WNOWAIT)
            except ChildProcessError:
                pass
            else:
                raise RuntimeError('pidfd ownership check unavailable')
        finally:
            os.close(fd)
        return children

    @staticmethod
    def _direct_children():
        children=set()
        tasks=tuple(Path('/proc/self/task').iterdir())
        read=False
        for task in tasks:
            try:
                value=(task/'children').read_text()
            except FileNotFoundError:  # A pool thread can finish during enumeration.
                continue
            read=True
            children.update(int(pid) for pid in value.split())
        if not read:
            raise RuntimeError('direct-child discovery unavailable')
        return children

    @staticmethod
    def _pidfd_pid(fd):
        fields=dict(line.split(':',1) for line in Path('/proc/self/fdinfo/'+str(fd)).read_text().splitlines() if ':' in line)
        return int(fields['Pid'])

    @staticmethod
    def _owned_child(pid):
        try:
            fd=os.pidfd_open(pid)
        except ProcessLookupError:
            return None
        try:
            # A stale/reused procfs PID naming a parent/sibling is not our child.
            # WNOWAIT verifies ownership without reaping or releasing identity.
            os.waitid(os.P_PIDFD,fd,os.WEXITED|os.WNOHANG|os.WNOWAIT)
        except (ChildProcessError,ProcessLookupError):
            os.close(fd)
            return None
        except BaseException:
            os.close(fd)
            raise
        return fd

    def reap_started_children(self):
        for pid in self._direct_children():
            baseline=self.baseline.get(pid)
            if baseline is not None and self._pidfd_pid(baseline)==pid:
                continue
            fd=self._owned_child(pid)
            if fd is None:
                continue
            try:
                signal.pidfd_send_signal(fd,signal.SIGKILL,None,0)
                os.waitid(os.P_PIDFD,fd,os.WEXITED)
            except (ChildProcessError,ProcessLookupError):
                pass  # The other guard thread or normal Popen cleanup won.
            finally:
                os.close(fd)

    def start(self,hard_exit):
        def watch():
            try:
                while not self.expired.is_set():
                    remaining=(self.deadline-datetime.now(timezone.utc)).total_seconds()
                    if remaining<=1:
                        break
                    self.expired.wait(min(.1,remaining-1))
                self.expired.set()
                while True:
                    self.reap_started_children()
                    remaining=(self.deadline-datetime.now(timezone.utc)).total_seconds()
                    if remaining<=0:
                        hard_exit(None,None)
                    time.sleep(min(.01,remaining))
            except BaseException:
                # Never expose constructor/driver/environment diagnostics.
                print(json.dumps(dict(schema='solo-empire.railway-staging.v1',status='failed',error='deadline_guard_failed')),flush=True)
                os._exit(1)
        threading.Thread(target=watch,name='staging-deadline',daemon=True).start()


class RedactedParser(argparse.ArgumentParser):
    def error(self,message):
        raise ValueError('invalid command')


def main(argv=None):
    # Pool/HTTP/startup diagnostics may contain connection details; checkpoints
    # are the only emitted runtime logs. Metrics remain available via the app.
    logging.disable(logging.CRITICAL)
    warnings.filterwarnings('ignore')
    parser = RedactedParser(description=__doc__)
    parser.add_argument('mode',choices=('bootstrap','probe','seed-restart','verify-restart','backup-restore','verify-restored','serve','worker'))
    config = None
    deadline_guard=None
    interrupted=False
    try:
        args = parser.parse_args(argv)
        env = os.environ
        config = Config.from_env(env)
        deadline_guard=DirectChildDeadline(config)
        def hard_deadline(_signum,_frame):
            deadline_guard.expired.set()
            deadline_guard.reap_started_children()
            checkpoint(config,dict(status='deadline-reached'))
            os._exit(124)
        def arm_hard_deadline():
            signal.signal(signal.SIGALRM,hard_deadline)
            remaining=(config.deadline-datetime.now(timezone.utc)).total_seconds()
            if remaining<=0:
                hard_deadline(None,None)
            signal.setitimer(signal.ITIMER_REAL,remaining)
        def interrupt(_signum,_frame):
            nonlocal interrupted
            interrupted=True
            deadline_guard.expired.set()
            arm_hard_deadline()
            deadline_guard.reap_started_children()
            raise StagingDeadline()
        # The pidfd watchdog covers launch/cleanup gaps, including masked alarms.
        # Normal BaseException unwinding remains a fast path for subprocess.run.
        signal.signal(signal.SIGALRM,interrupt)
        signal.setitimer(signal.ITIMER_REAL,max(.001,config.remaining()-1))
        deadline_guard.start(hard_deadline)
        if args.mode in {'serve','worker'}:
            if any(name in env for name in ('STAGING_ADMIN_DSN','STAGING_ROLE_PASSWORDS','STAGING_JWT_PRIVATE_KEY')):
                raise ValueError('operator authority forbidden in runtime')
            if args.mode=='serve':
                serve(config,env)
            else:
                stop = threading.Event()
                signal.signal(signal.SIGTERM,lambda *_:stop.set())
                signal.signal(signal.SIGINT,lambda *_:stop.set())
                worker(config,config.dsn(env['DATABASE_URL'],service='workflow',worker=True),stop,
                       json.loads(env['WORKFLOW_WORKER_AUTHORIZATION']),authority(config,env))
            result = dict(status='stopped')
        elif args.mode=='bootstrap':
            result = provision(config,config.dsn(env['STAGING_ADMIN_DSN'],admin=True),json.loads(env['STAGING_ROLE_PASSWORDS']))
        elif args.mode=='backup-restore':
            result = backup_restore(config,config.dsn(env['STAGING_ADMIN_DSN'],admin=True),Path('/usr/lib/postgresql/16/bin'))
        else:
            if 'STAGING_ADMIN_DSN' in env or 'STAGING_ROLE_PASSWORDS' in env or 'DATABASE_URL' in env:
                raise ValueError('HTTP probe must not receive database credentials')
            probe = Probe(config,env['STAGING_JWT_PRIVATE_KEY'])
            try:
                if args.mode=='probe':
                    result = probe.run(env['STAGING_PHASE'])
                elif args.mode=='seed-restart':
                    result = probe.seed()
                else:
                    result = probe.verify_restart(env['STAGING_RESTART_JOB_ID'],env['STAGING_OTHER_JOB_ID'],restored=args.mode=='verify-restored')
            finally:
                probe.close()
        if interrupted or deadline_guard.expired.is_set():
            raise StagingDeadline()
        checkpoint(config,result)
        return 0
    except StagingDeadline:
        checkpoint(config,dict(status='deadline-reached'))
        return 124
    except Exception:
        if interrupted or (deadline_guard is not None and deadline_guard.expired.is_set()):
            checkpoint(config,dict(status='deadline-reached'))
            return 124
        # Deliberately fixed error class: driver/HTTP errors can embed DSNs and bodies.
        print(json.dumps(dict(schema='solo-empire.railway-staging.v1',status='failed',error='staging_operation_failed')),flush=True)
        return 1
    finally:
        if deadline_guard is not None:
            deadline_guard.reap_started_children()
        if config is not None and 'arm_hard_deadline' in locals():
            # Keep the hard deadline armed through interpreter/thread shutdown.
            arm_hard_deadline()


if __name__=='__main__':
    raise SystemExit(main())
