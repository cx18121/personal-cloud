#!/usr/bin/env bash
set -euo pipefail

# Build the Mac's current Herdr commit on the personal cloud host.
#
# Herdr's client and server must speak the same wire protocol. Charlie runs a
# custom fork build, so no published release can ever match: stock 0.8.2 speaks
# protocol 20 while the fork speaks 21. The Mac is the single source of truth,
# and the host is built to match whatever it is running.
#
# Safe to run repeatedly. It skips the build when the host already has the
# commit, and it never fails the caller just because the host is unreachable.

host="${PERSONAL_CLOUD_HOST:-personal-cloud}"
custom_root="$HOME/.local/share/herdr-custom"

commit="${1:-}"
if [[ -z "$commit" ]]; then
  current=$(readlink "$custom_root/current" 2>/dev/null || true)
  if [[ -z "$current" ]]; then
    printf 'No custom Herdr build found at %s/current.\n' "$custom_root" >&2
    exit 1
  fi
  commit=$(basename "$(dirname "$current")")
fi

if [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'Expected a full Herdr commit SHA, got: %s\n' "$commit" >&2
  exit 1
fi

read_protocol() {
  awk '/^client:/ { in_client = 1; next }
       in_client && $1 == "protocol:" { print $2; exit }'
}

local_protocol=$("$custom_root/current" status 2>/dev/null | read_protocol || true)
if [[ -z "$local_protocol" ]]; then
  printf 'Could not read the local Herdr protocol version.\n' >&2
  exit 1
fi

if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$host" true 2>/dev/null; then
  printf 'Host %s is unreachable, so remote Herdr still runs its previous build.\n' "$host" >&2
  printf 'Rerun scripts/sync-herdr.sh when the host is back.\n' >&2
  exit 0
fi

printf 'Syncing Herdr %s to %s. A first build takes a few minutes.\n' "${commit:0:8}" "$host"

ssh "$host" 'bash -s' "$commit" <<'REMOTE'
set -euo pipefail

commit="$1"
root="$HOME/.local/share/herdr-custom"
src="$root/src"
target="$root/build-target"
stamp="$root/installed-commit"
bin="$HOME/.local/bin/herdr"
mise="$HOME/.local/bin/mise"

if [[ -x "$bin" && -f "$stamp" && "$(cat "$stamp")" == "$commit" ]]; then
  printf 'Host already runs Herdr %s.\n' "${commit:0:8}"
  exit 0
fi

mkdir -p "$root" "$HOME/.local/bin"

zig_bin=$("$mise" which zig)
if [[ ! -x "$zig_bin" ]]; then
  printf 'Zig is required to build Herdr and was not found.\n' >&2
  exit 1
fi

if [[ ! -d "$src/.git" ]]; then
  git clone --quiet https://github.com/cx18121/herdr.git "$src"
fi
git -C "$src" fetch --quiet --depth 1 origin "$commit"
git -C "$src" checkout --quiet --detach "$commit"

cd "$src"
ZIG="$zig_bin" CARGO_TARGET_DIR="$target" "$mise" exec -- \
  cargo build --release --locked --quiet

install -m 0755 "$target/release/herdr" "$bin"
printf '%s\n' "$commit" > "$stamp"
printf 'Installed Herdr %s on the host.\n' "${commit:0:8}"
REMOTE

# Verify what a login shell actually resolves, not the path we installed to.
# The published Herdr also reports version 0.8.2, so a mise shim earlier in PATH
# is invisible by version alone and only the protocol reveals it.
remote_protocol=$(ssh "$host" 'bash -lc "herdr status 2>/dev/null"' | read_protocol || true)
if [[ "$remote_protocol" != "$local_protocol" ]]; then
  remote_path=$(ssh "$host" 'bash -lc "command -v herdr"' 2>/dev/null || true)
  printf 'Protocol mismatch after sync: mac speaks %s, host speaks %s.\n' \
    "$local_protocol" "${remote_protocol:-unknown}" >&2
  printf 'The host resolves herdr to %s, which may be shadowing the build.\n' \
    "${remote_path:-nothing}" >&2
  exit 1
fi

printf 'Herdr is in sync. Both sides speak protocol %s.\n' "$local_protocol"
