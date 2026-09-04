#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_dir=$(cd -- "$script_dir/../config" && pwd)

# Refuse before writing anything. Everything below installs into $HOME, so a late
# check would leave gigabytes of state on the disposable root volume.
if ! mountpoint -q /home; then
  printf '/home is not mounted. Refusing to configure this host.\n' >&2
  exit 1
fi
home_label=$(findmnt -no LABEL /home)
if [[ "$home_label" != "personal-home" ]]; then
  printf '/home is %s with label "%s", not the persistent volume. Refusing.\n' \
    "$(findmnt -no SOURCE /home)" "$home_label" >&2
  exit 1
fi

pi_dir="$HOME/.pi/agent"
skills_dir="$HOME/.agents/skills"
shared_skills="$HOME/Projects/personal/agent-skills/skills"
managed_skills="$HOME/.local/share/personal-cloud/skills"

mkdir -p \
  "$HOME/.config/herdr" \
  "$HOME/.local/bin" \
  "$HOME/Projects/personal" \
  "$pi_dir" \
  "$skills_dir" \
  "$managed_skills"

git config --global init.defaultBranch main

mapfile -t tool_specs < <(python3 - "$script_dir/../mise.toml" <<'PY'
import sys
import tomllib
from pathlib import Path

config = tomllib.loads(Path(sys.argv[1]).read_text())
for name, version in config["tools"].items():
    if not isinstance(version, str):
        raise SystemExit(f"tool {name} must pin a string version")
    print(f"{name}@{version}")
PY
)
# mapfile swallows the producer's exit status, so assert the result instead.
if [[ "${#tool_specs[@]}" -eq 0 ]]; then
  printf 'Could not read the [tools] table from bootstrap/mise.toml\n' >&2
  exit 1
fi
"$HOME/.local/bin/mise" use -g "${tool_specs[@]}"

# Earlier bootstraps pinned the published Herdr, which speaks an older wire
# protocol than Charlie's fork while reporting the same version number. mise
# activation re-prepends its shim directory ahead of ~/.local/bin, so leaving
# any trace of it would shadow the matching build from scripts/sync-herdr.sh.
# Remove the pin, the installed copy, and the stale shim so only one herdr exists.
"$HOME/.local/bin/mise" unuse -g herdr 2>/dev/null || true
"$HOME/.local/bin/mise" uninstall --all herdr 2>/dev/null || true
rm -f "$HOME/.local/share/mise/shims/herdr"

python3 - "$pi_dir/settings.json" "$config_dir/pi/settings.json" <<'PY'
import json
import os
import sys
from pathlib import Path

output = Path(sys.argv[1])
template = Path(sys.argv[2])
settings = json.loads(template.read_text())

if output.exists():
    current = json.loads(output.read_text())
    if "lastChangelogVersion" in current:
        settings["lastChangelogVersion"] = current["lastChangelogVersion"]

temporary = output.with_suffix(".json.tmp")
temporary.write_text(json.dumps(settings, indent=2) + "\n")
os.replace(temporary, output)
PY

install -m 0644 "$config_dir/pi/AGENTS.md" "$pi_dir/AGENTS.md"

if [[ ! -d "$shared_skills" ]]; then
  printf 'Missing shared skills repository: %s\n' "$shared_skills" >&2
  exit 1
fi

while IFS= read -r target; do
  source=$(readlink "$target")
  if [[ "$source" == "$shared_skills/"* && ! -d "$source" ]]; then
    rm "$target"
  fi
done < <(find "$skills_dir" -mindepth 1 -maxdepth 1 -type l -print)

while IFS= read -r source; do
  name=$(basename "$source")
  target="$skills_dir/$name"
  if [[ -e "$target" && ! -L "$target" ]]; then
    printf 'Leaving unmanaged skill in place: %s\n' "$target" >&2
    continue
  fi
  ln -sfn "$source" "$target"
done < <(find "$shared_skills" -mindepth 1 -maxdepth 1 -type d -print | sort)

rm -rf "$managed_skills/pdf"
cp -R "$config_dir/skills/pdf" "$managed_skills/pdf"
if [[ ! -e "$skills_dir/pdf" || -L "$skills_dir/pdf" ]]; then
  ln -sfn "$managed_skills/pdf" "$skills_dir/pdf"
else
  printf 'Leaving unmanaged skill in place: %s\n' "$skills_dir/pdf" >&2
fi

"$HOME/.local/bin/mise" exec -- pi update --extensions --approve

path_line='export PATH="$HOME/.local/bin:$PATH"'

# The line must come first in each file. mise writes its own activation block,
# and activation calls `mise`, which lives in ~/.local/bin. Appending the PATH
# line instead leaves activation running before mise is findable, which fails
# on every shell and prints Ubuntu's "Command 'mise' not found" suggestion.
ensure_path_first() {
  local file="$1"
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "$path_line" > "$tmp"
  if [[ -f "$file" ]]; then
    # Drop earlier copies so reruns cannot stack duplicates.
    grep -Fxv "$path_line" "$file" >> "$tmp" || true
  fi
  install -m 0644 "$tmp" "$file"
  rm -f "$tmp"
}

ensure_path_first "$HOME/.bash_profile"
ensure_path_first "$HOME/.bashrc"

# The warning must live on the root volume. A copy under $HOME is invisible in the
# exact state it exists to report, because $HOME is on the volume that is missing.
sudo install -m 0644 /dev/stdin /etc/profile.d/personal-cloud-home-guard.sh <<'GUARD'
if [ "$(findmnt -no LABEL /home 2>/dev/null)" != "personal-home" ]; then
  printf 'WARNING: /home is not the persistent volume. Work stored here is lost when this instance is replaced.\n' >&2
fi
GUARD

# Remove the earlier guard that was written to the wrong volume.
if [[ -f "$HOME/.bashrc" ]]; then
  sed -i '/mountpoint -q \/home || printf "WARNING/d' "$HOME/.bashrc"
fi

if grep -Eq ' /home ext4 defaults,nofail 0 2$' /etc/fstab; then
  sudo sed -i 's# /home ext4 defaults,nofail 0 2$# /home ext4 defaults,nofail,x-systemd.device-timeout=2min 0 2#' /etc/fstab
  sudo findmnt --verify --verbose
  sudo systemctl daemon-reload
fi

# Standing assertion. The migration only rewrites one exact shape, so verify the
# invariant itself: a required /home would strand this headless host on reboot.
if ! grep -Eq '^[^#]*\s/home\s.*\bnofail\b' /etc/fstab; then
  printf 'The /home entry in /etc/fstab does not set nofail. Refusing to leave this host unbootable.\n' >&2
  exit 1
fi

if [[ -x "$HOME/.emdash/workspace-server/current/bin/emdash-workspace-server" ]]; then
  EMDASH_HOST_SETTINGS="$config_dir/emdash/host-settings.json" \
    "$script_dir/enable-emdash-autostart.sh"
fi

printf 'Developer tools and portable Pi configuration installed.\n'
