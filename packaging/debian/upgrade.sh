#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ $EUID != 0 ]]; then echo 'Run this updater as root.' >&2; exit 1; fi
exec python3 ./upgrade.py "$@"
