#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PYTHONPATH="$ROOT/src"

for asset in \
    manifest.json VERSION README.md SECURITY.md install.sh uninstall.sh \
    systemd/simplevm-guest-tools.service \
    systemd/simplevm-guest-tools-session.service \
    bin/simplevm-guest-tools-daemon bin/simplevm-guest-tools-session
do
    test -f "$ROOT/$asset" || {
        echo "Missing installer asset: $asset" >&2
        exit 1
    }
done

python3 -m unittest discover -s "$ROOT/tests" -p 'test_*.py' -v
