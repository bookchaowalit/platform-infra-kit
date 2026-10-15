"""Operator CLI. Plans are read-only; recovery targets must be explicit and new."""
import argparse
import json
import os
from pathlib import Path
import re

import yaml
import psycopg

from .release import validate_plan


def _dsn(variable):
    if not re.fullmatch(r'[A-Z][A-Z0-9_]{0,127}', variable):
        raise ValueError('invalid connection variable name')
    value = os.environ.get(variable)
    if not value:
        raise ValueError('explicit database connection environment is missing')
    return value


def main():
    parser = argparse.ArgumentParser(description='Shared infrastructure release and recovery')
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check-release', help='validate immutable images and aggregate limits')
    check.add_argument('plan', type=Path)
    render = commands.add_parser('render-kubernetes', help='render manifests without applying them')
    render.add_argument('plan', type=Path)
    render.add_argument('--namespace', required=True)
    render.add_argument('--output', required=True, type=Path)
    verify = commands.add_parser('verify-bundle', help='verify the exact hashed wheel artifact set')
    verify.add_argument('bundle', type=Path)
    backup = commands.add_parser('backup', help='create a private archive without replacing a backup')
    backup.add_argument('--dsn-env', required=True)
    backup.add_argument('--output', required=True, type=Path)
    backup.add_argument('--pg-bin', required=True, type=Path)
    restore = commands.add_parser('restore', help='restore into an explicitly named fresh database')
    restore.add_argument('--dsn-env', required=True)
    restore.add_argument('--archive', required=True, type=Path)
    restore.add_argument('--target', required=True)
    restore.add_argument('--confirm-new-database', required=True)
    restore.add_argument('--pg-bin', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'check-release':
            errors = validate_plan(yaml.safe_load(args.plan.read_text()))
            print(json.dumps({'valid': not errors, 'errors': errors}))
            return int(bool(errors))
        if args.command == 'render-kubernetes':
            from .delivery import render_kubernetes
            documents = render_kubernetes(yaml.safe_load(args.plan.read_text()), namespace=args.namespace)
            with args.output.open('x') as stream:
                yaml.safe_dump_all(documents, stream, sort_keys=False)
            print(json.dumps({'status': 'rendered', 'documents': len(documents)}))
            return 0
        if args.command == 'verify-bundle':
            from .delivery import verify_wheel_manifest
            errors = verify_wheel_manifest(args.bundle)
            print(json.dumps({'valid': not errors, 'errors': errors}))
            return int(bool(errors))
        if args.command == 'backup':
            from .recovery import create_backup
            create_backup(_dsn(args.dsn_env), args.output, pg_bin=args.pg_bin)
            print(json.dumps({'status': 'backup_created'}))
            return 0
        if args.target != args.confirm_new_database:
            raise ValueError('new database confirmation does not match')
        from .recovery import restore_backup
        restore_backup(_dsn(args.dsn_env), args.archive, target_database=args.target, pg_bin=args.pg_bin)
        print(json.dumps({'status': 'restored_into_new_database'}))
        return 0
    except (ValueError, OSError, RuntimeError, yaml.YAMLError, psycopg.Error):
        # Do not print connection strings, provider fields or exception payloads.
        print(json.dumps({'status': 'failed', 'error': 'configuration_or_operation_failed'}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
