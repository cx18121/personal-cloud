#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
host=ubuntu@personal-cloud
mise_version=2026.9.9

ssh "$host" \
  "if [ -x \"\$HOME/.local/bin/mise\" ]; then \"\$HOME/.local/bin/mise\" self-update $mise_version --yes --no-plugins; fi"

mise bootstrap remote \
  --host "$host" \
  --source "$root/bootstrap" \
  --bootstrap-command "MISE_VERSION=v$mise_version curl -fsSL https://mise.run | sh" \
  --update \
  --yes
