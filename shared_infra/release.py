"""Validate immutable release inputs and aggregate resource budgets."""
import math
import re

_NAME = re.compile(r'[a-z][a-z0-9-]{0,62}')
_IMAGE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[0-9a-f]{64}')
_ENV = re.compile(r'[A-Z][A-Z0-9_]{0,127}')


def validate_plan(plan: dict) -> list[str]:
    """Return safe field errors; never echo environment values or payloads."""
    if not isinstance(plan, dict):
        return ['release plan must be an object']
    errors = []
    if set(plan) - {'version', 'stage', 'database_connection_budget', 'services'}:
        errors.append('unknown release plan fields')
    if type(plan.get('version')) is not int or plan['version'] != 1:
        errors.append('unsupported release version')
    if plan.get('stage') not in {'staged', 'production'}:
        errors.append('release stage must be explicit')
    budget = plan.get('database_connection_budget')
    if type(budget) is not int or not 1 <= budget <= 10000:
        errors.append('invalid database connection budget')
        budget = 0
    services = plan.get('services')
    if not isinstance(services, list) or not 1 <= len(services) <= 64:
        return errors + ['release requires 1..64 services']
    seen, connections = set(), 0
    allowed = {'name', 'image', 'replicas', 'max_replicas', 'pool_max', 'workers', 'worker_pool_max',
               'memory_mb', 'request_timeout_seconds', 'required_env'}
    for index, service in enumerate(services):
        label = f'service[{index}]'
        if not isinstance(service, dict):
            errors.append(label + ' must be an object')
            continue
        if set(service) - allowed:
            errors.append(label + ' has unknown fields; secret values do not belong in a release plan')
        name = service.get('name')
        if not isinstance(name, str) or not _NAME.fullmatch(name):
            errors.append(label + ' has invalid name')
        elif name in seen:
            errors.append(label + ' has duplicate name')
        else:
            seen.add(name)
        if not isinstance(service.get('image'), str) or not _IMAGE.fullmatch(service['image']):
            errors.append(label + ' image requires an immutable sha256 digest')
        bounds = {'replicas': (1, 64), 'pool_max': (1, 64), 'workers': (0, 256),
                  'worker_pool_max': (1, 64), 'memory_mb': (16, 32768)}
        valid_resources = True
        for field, (minimum, maximum) in bounds.items():
            value = service.get(field)
            if type(value) is not int or not minimum <= value <= maximum:
                valid_resources = False
                errors.append(label + ' has invalid ' + field)
        maximum = service.get('max_replicas', service.get('replicas'))
        if type(maximum) is not int or not 1 <= maximum <= 64 or (type(service.get('replicas')) is int and maximum < service['replicas']):
            valid_resources = False
            errors.append(label + ' has invalid max_replicas')
        timeout = service.get('request_timeout_seconds')
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 300:
            errors.append(label + ' has invalid request timeout')
        names = service.get('required_env', [])
        if (not isinstance(names, list) or len(names) > 64 or
                any(not isinstance(v, str) or not _ENV.fullmatch(v) or 'MIGRATION' in v or 'ADMIN' in v for v in names)):
            errors.append(label + ' environment must contain variable names only')
        if valid_resources:
            connections += maximum * service['pool_max'] + service['workers'] * service['worker_pool_max']
    if connections > budget:
        errors.append('API and worker connection budget exceeded')
    return errors
