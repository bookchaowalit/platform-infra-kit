"""Generate reviewable immutable deployments; never apply them or read secrets."""
import hashlib
import json
from pathlib import Path
import re
import subprocess

from .release import validate_plan
from .runtime import SERVICES


def source_revision(path):
    path = Path(path)
    dirty = subprocess.run(['git', '-C', str(path), 'status', '--porcelain'],
                           check=True, capture_output=True, text=True).stdout
    if dirty.strip():
        raise ValueError('source checkout must be clean before packaging')
    revision = subprocess.run(['git', '-C', str(path), 'rev-parse', 'HEAD'],
                              check=True, capture_output=True, text=True).stdout.strip()
    if not re.fullmatch(r'[0-9a-f]{40,64}', revision):
        raise ValueError('source revision missing')
    return revision


def write_wheel_manifest(bundle, *, sources):
    bundle = Path(bundle)
    wheels = sorted((bundle / 'wheels').glob('*.whl'))
    if not wheels or any(p.is_symlink() for p in wheels):
        raise ValueError('regular wheel artifacts required')
    manifest = {'version': 1, 'sources': sources, 'wheels': {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in wheels}}
    with (bundle / 'wheel-manifest.json').open('x') as stream:
        json.dump(manifest, stream, sort_keys=True, indent=2)
        stream.write('\n')


def verify_wheel_manifest(bundle):
    bundle = Path(bundle)
    try:
        manifest = json.loads((bundle / 'wheel-manifest.json').read_text())
        expected = manifest['wheels']
        actual = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in (bundle / 'wheels').glob('*.whl') if not p.is_symlink()}
        if manifest.get('version') != 1 or not expected or expected != actual:
            return ['wheel artifact set or digest mismatch']
        if any(p.is_symlink() for p in (bundle / 'wheels').iterdir()):
            return ['wheel symlink refused']
        return []
    except (OSError, ValueError, KeyError, TypeError):
        return ['invalid wheel manifest']


def render_kubernetes(plan, *, namespace):
    errors = validate_plan(plan)
    if errors:
        raise ValueError('; '.join(errors))
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,62}', namespace):
        raise ValueError('invalid namespace')
    documents = []
    for service in plan['services']:
        name = service['name']
        if name not in SERVICES or service['workers']:
            raise ValueError('API generator requires supported services and separately deployed workspace workers')
        labels = {'app.kubernetes.io/name': name, 'app.kubernetes.io/part-of': 'shared-infra'}
        metadata = {'name': name, 'namespace': namespace, 'labels': labels}
        container = {'name': name, 'image': service['image'], 'imagePullPolicy': 'IfNotPresent',
                     'command': ['python', '-m', 'shared_infra.runtime', 'serve'],
                     'ports': [{'name': 'http', 'containerPort': 8080}],
                     'env': [{'name': 'PLATFORM_SERVICE', 'value': name},
                             {'name': 'DATABASE_POOL_MAX', 'value': str(service['pool_max'])},
                             {'name': 'REQUEST_TIMEOUT_SECONDS', 'value': str(service['request_timeout_seconds'])}],
                     'envFrom': [{'secretRef': {'name': name + '-runtime'}}],
                     'resources': {'requests': {'cpu': '100m', 'memory': str(service['memory_mb']) + 'Mi'},
                                   'limits': {'cpu': '1000m', 'memory': str(service['memory_mb']) + 'Mi'}},
                     'securityContext': {'allowPrivilegeEscalation': False, 'readOnlyRootFilesystem': True,
                                         'capabilities': {'drop': ['ALL']}},
                     'readinessProbe': {'httpGet': {'path': '/readyz', 'port': 'http'}, 'periodSeconds': 5, 'timeoutSeconds': 3},
                     'livenessProbe': {'httpGet': {'path': '/healthz', 'port': 'http'}, 'periodSeconds': 10, 'timeoutSeconds': 3},
                     'startupProbe': {'httpGet': {'path': '/healthz', 'port': 'http'}, 'periodSeconds': 2, 'failureThreshold': 30},
                     'volumeMounts': [{'name': 'tmp', 'mountPath': '/tmp'}]}
        deployment = {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'metadata': metadata,
                      'spec': {'replicas': service['replicas'], 'revisionHistoryLimit': 3,
                               'strategy': {'type': 'RollingUpdate', 'rollingUpdate': {'maxSurge': 0, 'maxUnavailable': 1}},
                               'selector': {'matchLabels': labels},
                               'template': {'metadata': {'labels': labels}, 'spec': {
                                   'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 40,
                                   'securityContext': {'runAsNonRoot': True, 'runAsUser': 10001, 'runAsGroup': 10001,
                                                       'seccompProfile': {'type': 'RuntimeDefault'}},
                                   'containers': [container], 'volumes': [{'name': 'tmp', 'emptyDir': {'sizeLimit': '64Mi'}}],
                                   'topologySpreadConstraints': [{'maxSkew': 1, 'topologyKey': 'kubernetes.io/hostname',
                                        'whenUnsatisfiable': 'ScheduleAnyway', 'labelSelector': {'matchLabels': labels}}]}}}}
        documents += [deployment,
            {'apiVersion': 'v1', 'kind': 'Service', 'metadata': metadata,
             'spec': {'selector': labels, 'ports': [{'name': 'http', 'port': 8080, 'targetPort': 'http'}]}},
            {'apiVersion': 'policy/v1', 'kind': 'PodDisruptionBudget', 'metadata': metadata,
             'spec': {'minAvailable': max(0, service['replicas'] - 1), 'selector': {'matchLabels': labels}}}]
        maximum = service.get('max_replicas', service['replicas'])
        if maximum > service['replicas']:
            documents.append({'apiVersion': 'autoscaling/v2', 'kind': 'HorizontalPodAutoscaler', 'metadata': metadata,
                'spec': {'scaleTargetRef': {'apiVersion': 'apps/v1', 'kind': 'Deployment', 'name': name},
                         'minReplicas': service['replicas'], 'maxReplicas': maximum,
                         'behavior': {'scaleDown': {'stabilizationWindowSeconds': 300}},
                         'metrics': [{'type': 'Resource', 'resource': {'name': 'cpu',
                            'target': {'type': 'Utilization', 'averageUtilization': 70}}}]}})
    return documents
