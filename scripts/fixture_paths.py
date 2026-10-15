"""Check the actual Unix socket addresses before starting an owned stand."""
import os
import sys


def validate_unix_fixture_paths(root):
    limit = 104 if sys.platform == 'darwin' else 108 if sys.platform.startswith('linux') else None
    if limit is None:
        return
    for name in ('admin.sock', 'ipc.sock'):
        size = len(os.fsencode(root / '0' / name))
        if size >= limit:
            raise ValueError(
                f'Fixture {name} address needs {size} bytes; the platform permits '
                f'at most {limit - 1}. Choose a shorter --directory.')
