#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
LC_ALL=C shasum -a 256 -c build/CoreBindings.sha256
