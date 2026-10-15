"""Repeatable local multi-process HTTP, lease recovery and restore acceptance."""
import argparse
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import json
import importlib.metadata
import math
import multiprocessing
import os
from pathlib import Path
import platform
import statistics
import tempfile
import threading
import time
from uuid import UUID, uuid4

import httpx
import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
from platform_backend_core import Database
from platform_backend_core.testing import TemporaryDatabase
from .fixtures import (SERVICES, Authority, LocalDeliveryAdapter, api_process,
                       grant_runtime, service_database, validate_local_admin_dsn, verifier)
from .recovery import create_backup, restore_backup


class Measurements:
    def __init__(self):
        self.rows = defaultdict(list)
        self.lock = threading.Lock()

    def add(self,label,started,ended,error=False):
        with self.lock:
            self.rows[label].append((started,ended,bool(error)))

    def summaries(self):
        result = {}
        for label,rows in self.rows.items():
            durations = sorted((end-start)*1000 for start,end,_ in rows)
            elapsed = max(end for _,end,_ in rows)-min(start for start,_,_ in rows)
            result[label] = {'count':len(rows),'errors':sum(error for _,_,error in rows),
                'p50_ms':round(statistics.median(durations),3),
                'p95_ms':round(durations[max(0,math.ceil(len(rows)*.95)-1)],3),
                'throughput_per_second':round(len(rows)/max(elapsed,.000001),3),
                'error_rate':round(sum(error for _,_,error in rows)/len(rows),6),
                'elapsed_seconds':round(elapsed,4)}
        return result


class Requests:
    def __init__(self):
        self.measurements = Measurements()
        self.client = httpx.Client(timeout=10,trust_env=False,
            limits=httpx.Limits(max_connections=16,max_keepalive_connections=12))

    def request(self,label,method,url, *, expected=(200,),**kwargs):
        started = time.monotonic()
        error = True
        try:
            response = self.client.request(method,url,**kwargs)
            error = response.status_code not in expected
            if error:
                raise AssertionError(label+' unexpected HTTP status '+str(response.status_code))
            return response
        finally:
            self.measurements.add(label,started,time.monotonic(),error)

    def close(self):
        self.client.close()


def _workflow_worker(dsn,public_key,authorization,action,start,out):
    database = None
    try:
        from platform_workflow import JobStore
        from platform_workflow.worker import Worker
        principal = verifier(public_key).verify(authorization)
        database = Database(dsn,max_size=2)
        store = JobStore(database)
        if not start.wait(10):
            raise RuntimeError('worker barrier timed out')
        if action == 'crash':
            job = store.claim(principal,owner='crash-fixture',lease_seconds=1)
            if job is None:
                raise AssertionError('crash fixture has no job')
            out.put({'id':str(job['id']),'lease_token':str(job['lease_token'])})
            # Parent deliberately terminates this process after the durable claim.
            threading.Event().wait(30)
        elif action == 'claim':
            job = store.claim(principal,owner='claim-fixture',lease_seconds=10)
            if job is None:
                raise AssertionError('claim fixture has no job')
            store.complete(principal,job['id'],lease_token=job['lease_token'],result={'ok':True})
            out.put({'id':str(job['id'])})
        else:
            worker = Worker(store,principal,{'echo':lambda payload:{'ok':True}},owner='drain-fixture',lease_seconds=10)
            count = 0
            while worker.run_once():
                count += 1
            out.put({'count':count})
    except Exception as exc:
        out.put({'error':type(exc).__name__})
        raise SystemExit(2) from None
    finally:
        if database is not None:
            database.close()


def _workers(dsn,public_key,authorization,action, *, count=2):
    context = multiprocessing.get_context('spawn')
    start,out = context.Event(),context.Queue()
    processes = [context.Process(target=_workflow_worker,args=(dsn,public_key,authorization,action,start,out)) for _ in range(count)]
    try:
        for process in processes:
            process.start()
        start.set()
        results = [out.get(timeout=30) for _ in processes]
        if any('error' in result for result in results):
            raise AssertionError('fixture worker failed')
        if action != 'crash':
            for process in processes:
                process.join(15)
                if process.exitcode != 0:
                    raise AssertionError('fixture worker did not exit successfully')
        return results
    finally:
        for process in processes:
            if process.is_alive():
                process.terminate()
            process.join(5)
            if process.is_alive():
                process.kill()
                process.join(5)
        out.close()
        out.join_thread()


def _counter_client(urls,authorization,count,start,out):
    rows=[]
    try:
        if not start.wait(10):
            raise RuntimeError('client barrier timed out')
        with httpx.Client(timeout=10,trust_env=False) as client:
            for index in range(count):
                began=time.monotonic()
                response=client.post(urls[index%len(urls)]+'/v1/counters/fixture-counter/increment',
                    headers={'Authorization':authorization},json={'amount':1,'window_seconds':3600})
                ended=time.monotonic()
                if response.status_code != 200:
                    raise AssertionError('counter request failed')
                rows.append((began,ended,response.json()['value']))
        out.put({'rows':rows})
    except Exception as exc:
        out.put({'error':type(exc).__name__})
        raise SystemExit(2) from None


def _counter_processes(urls,authorization,operations,measurements):
    context=multiprocessing.get_context('spawn')
    start,out=context.Event(),context.Queue()
    counts=(operations//2,operations-operations//2)
    processes=[context.Process(target=_counter_client,args=(urls,authorization,count,start,out)) for count in counts]
    try:
        for process in processes:process.start()
        start.set()
        results=[out.get(timeout=30) for _ in processes]
        values=[]
        for result in results:
            if 'error' in result:raise AssertionError('counter client process failed')
            for began,ended,value in result['rows']:
                measurements.add('data.counter',began,ended)
                values.append(value)
        for process in processes:
            process.join(15)
            if process.exitcode != 0:raise AssertionError('counter client did not exit successfully')
        if sorted(values) != list(range(1,operations+1)):
            raise AssertionError('shared counter lost or duplicated an increment')
        return max(values)
    finally:
        for process in processes:
            if process.is_alive():process.terminate()
            process.join(5)
            if process.is_alive():process.kill();process.join(5)
        out.close();out.join_thread()


def _deliver_message(dsn,public_key,authorization,out):
    database=None
    try:
        from platform_communication.store import OutboxStore
        from platform_communication.worker import DeliveryWorker
        principal=verifier(public_key).verify(authorization)
        if 'messages:write' not in principal.scopes:raise AssertionError('fixture authorization denied')
        database=Database(dsn,max_size=2)
        worker=DeliveryWorker(OutboxStore(database),{'email':LocalDeliveryAdapter()})
        out.put({'delivered':worker.run_one(principal.workspace)})
    except Exception as exc:
        out.put({'error':type(exc).__name__})
        raise SystemExit(2) from None
    finally:
        if database is not None:database.close()


def _check_capabilities(requests,apis,databases,authority,workspace,other,auth):
    headers={'Authorization':auth}
    other_headers={'Authorization':authority.authorization(other)}
    result={}
    url=apis['developer'][0].url
    requests.request('flags.write','PUT',url+'/v1/flags/fixture-feature',headers=headers,json={'enabled':True,'rollout':5000})
    decisions=[requests.request('flags.evaluate','POST',url+'/v1/flags/fixture-feature/evaluate',headers=headers,json={'subject':'fixture-subject'}).json() for _ in range(2)]
    assert decisions[0] == decisions[1]
    requests.request('flags.isolation','GET',url+'/v1/flags/fixture-feature',headers=other_headers,expected=(404,))
    result['developer']={'passed':True,'stable_evaluation':True,'cross_workspace_denied':True}

    url=apis['security'][0].url
    requests.request('security.reference','PUT',url+'/v1/secret-references/fixture-reference',headers=headers,
                     json={'provider':'env','reference':'ACCEPTANCE_REFERENCE','purpose':'Fixture metadata'})
    refs=requests.request('security.isolation','GET',url+'/v1/secret-references',headers=other_headers).json()
    assert refs == []
    audit=[requests.request('security.audit','POST',url+'/v1/audit',headers=headers|{'Idempotency-Key':'fixture-audit'},
                           json={'action':'fixture.created','target':'fixture-reference'}).json() for _ in range(2)]
    assert audit[0]['id'] == audit[1]['id']
    result['security']={'passed':True,'reference_values_absent':True,'audit_deduplicated':True}

    url=apis['communication'][0].url
    body={'channel':'email','recipient':'fixture@example.invalid','body':'Synthetic acceptance fixture','max_attempts':2}
    messages=[requests.request('messages.enqueue','POST',url+'/v1/messages',headers=headers|{'Idempotency-Key':'fixture-message'},json=body,expected=(202,)).json() for _ in range(2)]
    assert messages[0]['id'] == messages[1]['id']
    requests.request('messages.isolation','GET',url+'/v1/messages/'+messages[0]['id'],headers=other_headers,expected=(404,))
    context=multiprocessing.get_context('spawn');out=context.Queue()
    process=context.Process(target=_deliver_message,args=(databases['communication'].runtime_dsn,authority.public_key,auth,out))
    process.start()
    try:
        delivered=out.get(timeout=20);process.join(10)
        assert delivered.get('delivered') is True and process.exitcode == 0
    finally:
        if process.is_alive():process.terminate();process.join(5)
        out.close();out.join_thread()
    state=requests.request('messages.read','GET',url+'/v1/messages/'+messages[0]['id'],headers=headers).json()
    assert state['status'] == 'delivered'
    result['communication']={'passed':True,'durable_outbox_delivered':True,'adapter':'local-no-network'}

    import base64,hashlib
    url=apis['media'][0].url
    upload={'filename':'fixture.txt','content_type':'text/plain','size':7,
            'checksum_sha256':base64.b64encode(hashlib.sha256(b'fixture').digest()).decode()}
    uploads=[requests.request('media.intent','POST',url+'/v1/uploads',headers=headers|{'Idempotency-Key':'fixture-upload'},json=upload,expected=(200,201)).json() for _ in range(2)]
    assert uploads[0]['id'] == uploads[1]['id']
    file_id=uploads[0]['id']
    requests.request('media.isolation','POST',url+'/v1/uploads/'+file_id+'/complete',headers=other_headers,expected=(404,))
    completed=requests.request('media.complete','POST',url+'/v1/uploads/'+file_id+'/complete',headers=headers).json()
    assert completed['status'] == 'ready'
    requests.request('media.isolation','GET',url+'/v1/files/'+file_id,headers=other_headers,expected=(404,))
    result['media']={'passed':True,'intent_deduplicated':True,'adapter':'synthetic-object-metadata','real_object_storage_tested':False}

    url=apis['payment'][0].url
    payments=[requests.request('payment.intent','POST',url+'/v1/payment-intents',headers=headers|{'Idempotency-Key':'fixture-payment'},json={'amount':123,'currency':'thb'},expected=(200,201)).json() for _ in range(2)]
    assert payments[0]['id'] == payments[1]['id']
    requests.request('payment.conflict','POST',url+'/v1/payment-intents',headers=headers|{'Idempotency-Key':'fixture-payment'},json={'amount':124,'currency':'thb'},expected=(409,))
    requests.request('payment.isolation','GET',url+'/v1/payment-intents/'+payments[0]['id'],headers=other_headers,expected=(404,))
    assert payments[0]['status'] == 'pending'
    result['payment']={'passed':True,'intent_deduplicated':True,'adapter':'local-no-network','actual_charges':0}
    return result


def run_acceptance(admin_dsn, *, pg_bin, operations=24, concurrency=6):
    validate_local_admin_dsn(admin_dsn)
    pg_bin=Path(pg_bin)
    if not all((pg_bin/name).is_file() for name in ('pg_dump','pg_restore')):
        raise ValueError('explicit PostgreSQL client directory required')
    if type(operations) is not int or not 8<=operations<=1000:
        raise ValueError('operations must be 8..1000')
    if type(concurrency) is not int or not 2<=concurrency<=16:
        raise ValueError('concurrency must be 2..16')
    started=time.monotonic()
    authority=Authority.generate()
    workspace,other=uuid4(),uuid4()
    auth=authority.authorization(workspace)
    headers={'Authorization':auth}
    other_headers={'Authorization':authority.authorization(other)}
    requests=Requests()
    try:
        with ExitStack() as stack:
            databases={service:stack.enter_context(service_database(admin_dsn,service)) for service in SERVICES}
            apis={service:[stack.enter_context(api_process(service,databases[service].runtime_dsn,authority.public_key))
                           for _ in range(2 if service in {'workflow','data'} else 1)] for service in SERVICES}
            urls=[api.url for api in apis['workflow']]
            body={'queue':'default','job_type':'echo','payload':{'fixture':True}}
            with ThreadPoolExecutor(max_workers=concurrency) as pool:
                duplicates=list(pool.map(lambda index:requests.request('workflow.duplicate','POST',urls[index%2]+'/v1/jobs',
                    headers=headers|{'Idempotency-Key':'fixture-duplicate'},json=body,expected=(201,)).json(),range(concurrency)))
            assert len({job['id'] for job in duplicates}) == 1
            requests.request('workflow.isolation','GET',urls[1]+'/v1/jobs/'+duplicates[0]['id'],headers=other_headers,expected=(404,))
            requests.request('workflow.changed-key','POST',urls[0]+'/v1/jobs',headers=headers|{'Idempotency-Key':'fixture-duplicate'},
                json=body|{'payload':{'fixture':False}},expected=(409,))
            requests.request('workflow.enqueue','POST',urls[0]+'/v1/jobs',headers=headers|{'Idempotency-Key':'fixture-second'},json=body,expected=(201,))
            claims=_workers(databases['workflow'].runtime_dsn,authority.public_key,auth,'claim')
            assert len({job['id'] for job in claims}) == 2
            requests.request('workflow.enqueue','POST',urls[1]+'/v1/jobs',headers=headers|{'Idempotency-Key':'fixture-crash'},json=body,expected=(201,))
            crash=_workers(databases['workflow'].runtime_dsn,authority.public_key,auth,'crash',count=1)[0]
            # Actual clock expiry after abrupt process death, no privileged lease rewrite.
            deadline=time.monotonic()+5
            replacement=None
            while replacement is None:
                replacement=requests.request('workflow.reclaim','POST',urls[0]+'/v1/worker/claim',headers=headers,
                    json={'owner':'replacement','lease_seconds':10}).json()
                if replacement is None:
                    if time.monotonic()>deadline:raise AssertionError('expired job did not recover')
                    time.sleep(.1)
            assert replacement['id'] == crash['id'] and replacement['attempts'] == 2
            stale=requests.request('workflow.stale-ack','POST',urls[1]+'/v1/worker/jobs/'+crash['id']+'/complete',headers=headers,
                json={'lease_token':crash['lease_token'],'result':{'ok':True}},expected=(409,))
            requests.request('workflow.complete','POST',urls[0]+'/v1/worker/jobs/'+crash['id']+'/complete',headers=headers,
                json={'lease_token':replacement['lease_token'],'result':{'ok':True}})
            with ThreadPoolExecutor(max_workers=concurrency) as pool:
                load_jobs=list(pool.map(lambda index:requests.request('workflow.enqueue-load','POST',urls[index%2]+'/v1/jobs',
                    headers=headers|{'Idempotency-Key':'fixture-drain-'+str(index)},json=body,expected=(201,)).json(),range(operations)))
            drained=sum(row['count'] for row in _workers(databases['workflow'].runtime_dsn,authority.public_key,auth,'drain'))
            assert drained == operations
            for job in load_jobs:
                stored=requests.request('workflow.verify-drain','GET',urls[0]+'/v1/jobs/'+job['id'],headers=headers).json()
                assert stored['status'] == 'succeeded' and stored['result'] == {'ok':True}
            # A second durable workspace must survive the backup too.
            other_job=requests.request('workflow.other-workspace','POST',urls[1]+'/v1/jobs',
                headers=other_headers|{'Idempotency-Key':'fixture-other'},json=body,expected=(201,)).json()
            workflow={'workers':2,'distinct_claims':2,'duplicate_jobs':1,'stale_ack_status':stale.status_code,
                      'restart_recovered':True,'drained':drained}

            data_urls=[api.url for api in apis['data']]
            counter=_counter_processes(data_urls,auth,operations,requests.measurements)
            requests.request('data.cache-write','PUT',data_urls[0]+'/v1/cache/fixture-cache',headers=headers,
                json={'value':{'fixture':True},'ttl_seconds':300})
            cached=requests.request('data.cache-replica','GET',data_urls[1]+'/v1/cache/fixture-cache',headers=headers).json()
            assert cached['value'] == {'fixture':True}
            requests.request('data.cache-isolation','GET',data_urls[1]+'/v1/cache/fixture-cache',headers=other_headers,expected=(404,))
            requests.request('data.document','PUT',data_urls[0]+'/v1/documents/fixture-document',headers=headers,
                json={'text':'Synthetic fixture search evidence','metadata':{'fixture':True}})
            found=requests.request('data.search-replica','GET',data_urls[1]+'/v1/documents',headers=headers,params={'q':'evidence'}).json()
            assert len(found['items']) == 1
            isolated=requests.request('data.search-isolation','GET',data_urls[0]+'/v1/documents',headers=other_headers,params={'q':'evidence'}).json()
            assert isolated['items'] == []
            requests.request('data.policy','PUT',data_urls[0]+'/v1/quotas/fixture-quota',headers=headers,json={'limit':7,'window_seconds':3600})
            with ThreadPoolExecutor(max_workers=concurrency) as pool:
                reservations=list(pool.map(lambda index:requests.request('data.reservation','POST',data_urls[index%2]+'/v1/reservations',
                    headers=headers,json={'policy':'fixture-quota','units':1,'idempotency_key':'fixture-'+str(index)},expected=(200,429)),range(operations)))
            admitted=[response.json() for response in reservations if response.status_code == 200]
            assert len(admitted) == 7
            requests.request('data.isolation','POST',data_urls[1]+'/v1/reservations/'+admitted[0]['id']+'/release',headers=other_headers,json={},expected=(404,))
            requests.request('data.other-policy','PUT',data_urls[1]+'/v1/quotas/fixture-quota',headers=other_headers,json={'limit':7,'window_seconds':3600})
            requests.request('data.other-reservation','POST',data_urls[1]+'/v1/reservations',headers=other_headers,
                json={'policy':'fixture-quota','units':7,'idempotency_key':'fixture-other'})
            data={'api_replicas':2,'client_processes':2,'limit':7,'admitted':len(admitted),'overshoot':max(0,len(admitted)-7),'counter_final':counter}

            capabilities=_check_capabilities(requests,apis,databases,authority,workspace,other,auth)
            metrics_api=apis['workflow'][0]
            requests.request('telemetry.unauthenticated','GET',metrics_api.url+'/metrics',expected=(401,))
            metrics=requests.request('telemetry.authenticated','GET',metrics_api.url+'/metrics',
                headers={'Authorization':'Bearer '+metrics_api.metrics_token}).text
            assert 'route="/v1/jobs/{job_id}"' in metrics or 'route="/v1/worker/jobs/{job_id}/complete"' in metrics
            for private in (str(workspace),str(other),duplicates[0]['id'],auth,metrics_api.metrics_token):
                assert private not in metrics
            telemetry={'authenticated':True,'templates_only':True,'external_exporter_configured':False}

            target='accept_restore_'+uuid4().hex
            restored=None
            try:
                with tempfile.TemporaryDirectory(prefix='shared-infra-acceptance-') as directory:
                    backup=create_backup(databases['workflow'].admin_dsn,Path(directory)/'workflow.dump',pg_bin=pg_bin)
                    restored=restore_backup(admin_dsn,backup,target_database=target,pg_bin=pg_bin)
                    original=databases['workflow']
                    runtime=make_conninfo(restored,options='-c role='+original.runtime_role)
                    restored_database=TemporaryDatabase(restored,runtime,original.runtime_role)
                    grant_runtime(restored_database,'workflow')
                    with api_process('workflow',runtime,authority.public_key) as restored_api:
                        first=requests.request('recovery.workspace-one','GET',restored_api.url+'/v1/jobs/'+duplicates[0]['id'],headers=headers).json()
                        second=requests.request('recovery.workspace-two','GET',restored_api.url+'/v1/jobs/'+other_job['id'],headers=other_headers).json()
                        assert first['id'] == duplicates[0]['id'] and first['status'] == 'succeeded'
                        assert second['id'] == other_job['id'] and second['status'] == 'queued'
                        requests.request('recovery.isolation','GET',restored_api.url+'/v1/jobs/'+other_job['id'],headers=headers,expected=(404,))
            finally:
                # Remove only the uniquely generated restore target created by this run.
                if restored is not None:
                    with psycopg.connect(admin_dsn,autocommit=True) as conn:
                        conn.execute(sql.SQL('DROP DATABASE {} WITH (FORCE)').format(sql.Identifier(target)))
            with psycopg.connect(admin_dsn) as conn:
                postgres=conn.execute('SHOW server_version').fetchone()[0]
            summaries=requests.measurements.summaries()
            assert all(summary['errors'] == 0 for summary in summaries.values())
            return {'status':'passed','stage':'implemented-local','correlation':'SHARED-INFRA-2026-10-15',
                'scope':'local functional concurrency and measured fixture capacity; no production SLA',
                'runtime':{'python':platform.python_version(),'postgresql':postgres,
                    'packages':{name:importlib.metadata.version(name) for name in (
                        'platform-backend-core','platform-workflow','platform-data','platform-developer',
                        'platform-security','platform-communication','platform-media','platform-payment',
                        'platform-observability','fastapi','psycopg','uvicorn')}},'api_processes':9,
                'runtime_roles_non_bypassrls':7,'external_provider_calls':0,'workflow':workflow,'data':data,
                'capabilities':capabilities,'telemetry':telemetry,
                'recovery':{'fresh_database':True,'restored_workspaces':2,'rows_reopened_over_http':2},
                'load':{'operations':operations,'concurrency':concurrency},'measurements':summaries,
                'elapsed_seconds':round(time.monotonic()-started,3),'skipped_checks':[]}
    finally:
        requests.close()


def main():
    parser=argparse.ArgumentParser(description='Local shared infrastructure acceptance; no deployment or live providers')
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--operations',type=int,default=24)
    parser.add_argument('--concurrency',type=int,default=6)
    args=parser.parse_args()
    if args.output.exists():
        parser.error('evidence output already exists; choose a new path')
    try:
        dsn=os.environ['PLATFORM_TEST_DSN']
        pg_bin=Path(os.environ['PLATFORM_PG_BIN'])
        result=run_acceptance(dsn,pg_bin=pg_bin,operations=args.operations,concurrency=args.concurrency)
    except Exception as exc:
        # Exception text can include libpq or response payloads. Emit its class only.
        result={'status':'failed','stage':'implemented-local','error_kind':type(exc).__name__}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    # Exclusive evidence output avoids replacing another run's result.
    with args.output.open('x',encoding='utf-8') as output:
        json.dump(result,output,indent=2,sort_keys=True)
        output.write('\n')
    print(json.dumps({'status':result['status'],'output':str(args.output)}))
    return 0 if result['status']=='passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
