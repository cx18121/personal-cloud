#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_dir=$(cd -- "$script_dir/../config" && pwd)

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

mise="$HOME/.local/bin/mise"
dotfiles="$HOME/dotfiles"
managed_skills="$HOME/.local/share/personal-cloud/skills"
skills_dir="$HOME/.agents/skills"

if [[ ! -x "$mise" ]]; then
  printf 'Missing mise at %s.\n' "$mise" >&2
  exit 1
fi
if [[ ! -f "$dotfiles/mise.toml" ]]; then
  printf 'Missing shared bootstrap at %s/mise.toml.\n' "$dotfiles" >&2
  exit 1
fi

mkdir -p "$managed_skills" "$skills_dir"
git config --global init.defaultBranch main

# The previous bootstrap generated this as a real file. The shared dotfiles
# project now owns it as a symlink, so remove only that known legacy shape.
mise_config="$HOME/.config/mise/config.toml"
if [[ -e "$mise_config" && ! -L "$mise_config" ]]; then
  rm -f "$mise_config"
fi

rpiv_target="$HOME/.config/rpiv-todo/config.json"
rpiv_source="$dotfiles/pi/.config/rpiv-todo/config.json"
if [[ -f "$rpiv_target" && ! -L "$rpiv_target" ]]; then
  if ! cmp -s "$rpiv_target" "$rpiv_source"; then
    printf 'Refusing to replace changed rpiv-todo config: %s\n' "$rpiv_target" >&2
    exit 1
  fi
  rm -f "$rpiv_target"
fi

"$mise" -C "$dotfiles" -E linux bootstrap --locked --update --yes

# The packaged PDF skill is not part of the shared agent-skills repository.
rm -rf "$managed_skills/pdf"
cp -R "$config_dir/skills/pdf" "$managed_skills/pdf"
if [[ ! -e "$skills_dir/pdf" || -L "$skills_dir/pdf" ]]; then
  ln -sfn "$managed_skills/pdf" "$skills_dir/pdf"
else
  printf 'Leaving unmanaged skill in place: %s\n' "$skills_dir/pdf" >&2
fi

sudo install -m 0644 /dev/stdin /etc/profile.d/personal-cloud-home-guard.sh <<'GUARD'
if [ "$(findmnt -no LABEL /home 2>/dev/null)" != "personal-home" ]; then
  printf 'WARNING: /home is not the persistent volume. Work stored here is lost when this instance is replaced.\n' >&2
fi
GUARD

if ! grep -Eq '^[^#]*\s/home\s.*\bnofail\b' /etc/fstab; then
  printf 'The /home entry in /etc/fstab does not set nofail. Refusing to leave this host unbootable.\n' >&2
  exit 1
fi

if [[ -x "$HOME/.emdash/workspace-server/current/bin/emdash-workspace-server" ]]; then
  EMDASH_HOST_SETTINGS="$config_dir/emdash/host-settings.json" \
    "$script_dir/enable-emdash-autostart.sh"
fi

printf 'Shared developer setup and personal-cloud safeguards are ready.\n'
