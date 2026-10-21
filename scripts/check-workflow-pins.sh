#!/usr/bin/env bash
# Keep the shell entrypoint used by CI; the checker uses only Python's stdlib.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/check-workflow-pins.py" "$@"
