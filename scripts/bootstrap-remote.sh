#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mise bootstrap remote \
  --host ubuntu@personal-cloud \
  --source "$root/bootstrap" \
  --bootstrap-command 'curl -fsSL https://mise.run | sh' \
  --update \
  --yes
