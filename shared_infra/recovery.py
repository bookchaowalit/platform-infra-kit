"""Back up explicitly selected databases and restore only into new databases."""
import os
from pathlib import Path
import re
import subprocess
import tempfile

import psycopg
from psycopg import sql
from psycopg.conninfo import conninfo_to_dict, make_conninfo


def _command(pg_bin: Path, name: str, dsn: str, args: list[str]):
    executable = Path(pg_bin) / name
    if not executable.is_file():
        raise ValueError('PostgreSQL client binary is unavailable')
    environment = {key: value for key, value in os.environ.items() if not key.startswith('PG')}
    # PGDATABASE is a database name, not a conninfo string. Populate individual
    # libpq variables explicitly, so the selected host and port are preserved.
    mapping = {'dbname': 'PGDATABASE', 'host': 'PGHOST', 'hostaddr': 'PGHOSTADDR',
               'port': 'PGPORT', 'user': 'PGUSER', 'password': 'PGPASSWORD',
               'connect_timeout': 'PGCONNECT_TIMEOUT', 'sslmode': 'PGSSLMODE',
               'sslrootcert': 'PGSSLROOTCERT', 'sslcert': 'PGSSLCERT', 'sslkey': 'PGSSLKEY',
               'sslcrl': 'PGSSLCRL', 'sslcrldir': 'PGSSLCRLDIR',
               'channel_binding': 'PGCHANNELBINDING', 'options': 'PGOPTIONS',
               'application_name': 'PGAPPNAME', 'target_session_attrs': 'PGTARGETSESSIONATTRS',
               'gssencmode': 'PGGSSENCMODE'}
    fields = conninfo_to_dict(dsn)
    if set(fields) - set(mapping):
        raise ValueError('unsupported explicit PostgreSQL connection option')
    environment.update({mapping[key]: value for key, value in fields.items()})
    environment['PGPASSFILE'] = os.devnull
    result = subprocess.run([str(executable), *args], env=environment,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            timeout=300, check=False)
    if result.returncode:
        raise RuntimeError(name + ' failed; inspect the selected environment without printing credentials')


def create_backup(dsn: str, destination: Path, *, pg_bin: Path) -> Path:
    """Create a private custom archive without overwriting an existing backup."""
    destination = Path(destination)
    if destination.exists():
        raise FileExistsError('backup already exists')
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.backup-', suffix='.partial', dir=destination.parent)
    os.close(fd)
    temporary = Path(temporary)
    try:
        temporary.chmod(0o600)
        _command(pg_bin, 'pg_dump', dsn, ['--format=custom', '--no-owner', '--no-privileges',
                                         '--file=' + str(temporary)])
        with temporary.open('rb') as stream:
            os.fsync(stream.fileno())
        # Atomic, exclusive publication: a racing writer cannot replace a backup.
        os.link(temporary, destination)
        return destination
    finally:
        temporary.unlink(missing_ok=True)


def restore_backup(admin_dsn: str, backup: Path, *, target_database: str, pg_bin: Path) -> str:
    """Restore an archive into a freshly created database; existing targets refuse."""
    if (not isinstance(target_database, str) or
            not re.fullmatch(r'[a-z][a-z0-9_]{2,62}', target_database) or
            target_database in {'postgres', 'template0', 'template1'}):
        raise ValueError('restore requires an explicit new database name')
    backup = Path(backup)
    if not backup.is_file():
        raise ValueError('backup archive is unavailable')
    with psycopg.connect(admin_dsn, autocommit=True) as conn:
        if conn.execute('SELECT 1 FROM pg_database WHERE datname=%s', (target_database,)).fetchone():
            raise ValueError('target database already exists')
        _command(pg_bin, 'pg_restore', admin_dsn, ['--list', str(backup)])
        conn.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(target_database)))
    target_dsn = make_conninfo(admin_dsn, dbname=target_database)
    # No --clean or drop flags. A failed restore leaves only this new target
    # for inspection; it can never erase an existing database.
    _command(pg_bin, 'pg_restore', target_dsn,
             ['--no-owner', '--no-privileges', '--exit-on-error', '--single-transaction',
              '--dbname=' + target_database, str(backup)])
    return target_dsn
