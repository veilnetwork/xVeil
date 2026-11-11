#!/usr/bin/env python3
"""Build the self-contained `curl ... | bash` helper; never fetch floating code."""
import argparse
from pathlib import Path


def build(source):
    return '''#!/usr/bin/env bash
# Additional xVeil node-management helper. No Veil service is installed here.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
if [ "$(uname -s)" != Linux ]; then
  echo 'veil-connect requires Linux' >&2
  exit 1
fi
if [ "$(id -u)" != 0 ]; then
  echo 'Run this bootstrap as root; the phone will choose what to install.' >&2
  exit 1
fi
missing=0
for dependency in python3 openssl qrencode sudo ip curl flock; do
  command -v "$dependency" >/dev/null || missing=1
done
# HTTPS release downloads and the deployment lock are needed after pairing,
# even when all dependencies of the helper itself were already installed.
if ! test -s /etc/ssl/certs/ca-certificates.crt && ! test -s /etc/pki/tls/certs/ca-bundle.crt; then
  missing=1
fi
if [ "$missing" = 1 ]; then
  if ! command -v apt-get >/dev/null; then
    echo 'Install Python 3.8+, openssl, qrencode, sudo, iproute2, curl, ca-certificates and util-linux; retry.' >&2
    exit 1
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3 openssl qrencode ca-certificates sudo iproute2 curl util-linux
fi
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)' || {
  echo 'Python 3.8+ is required' >&2
  exit 1
}
umask 077
workdir=$(mktemp -d)
trap 'rm -rf -- "$workdir"' EXIT
cat > "$workdir/veil-connect.py" <<'XVEIL_CONNECT_SOURCE_V1'
''' + source + '''
XVEIL_CONNECT_SOURCE_V1
python3 "$workdir/veil-connect.py" --bootstrap "$@"
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    source = Path(__file__).with_name("veil_connect_agent.py").read_text()
    args.output.write_text(build(source))
    args.output.chmod(0o755)


if __name__ == "__main__":
    main()
