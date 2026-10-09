#!/usr/bin/env bash
set -euo pipefail
package_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ $EUID != 0 ]]; then echo 'Run this updater as root.' >&2; exit 1; fi
installed_helper=/opt/openwebpbx/tools/upgrade.py
if [[ -f "$installed_helper" ]] && [[ "$(python3 "$installed_helper" --protocol-version 2>/dev/null || true)" == 1 ]]; then
  exec python3 "$installed_helper" "$@"
fi
# One-time operator bootstrap from 1.0.3. Automatic updates always invoke the
# installed verifier directly and never execute code from a downloaded archive.
exec python3 "$package_dir/upgrade.py" "$@"
