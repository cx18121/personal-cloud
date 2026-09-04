#!/usr/bin/env bash
set -euo pipefail

server="$HOME/.emdash/workspace-server/current/bin/emdash-workspace-server"
socket="$HOME/.emdash/workspace-server/run/workspace.sock"
service="emdash-workspace-server.service"
prestart="$HOME/.local/bin/emdash-workspace-server-prestart"

if [[ ! -x "$server" ]]; then
  printf 'Emdash workspace server is not installed yet. Connect once from Emdash first.\n' >&2
  exit 1
fi

if ! command -v lsof >/dev/null 2>&1; then
  printf 'lsof is required to determine Emdash socket ownership.\n' >&2
  exit 1
fi

cat > "$prestart" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

socket="$HOME/.emdash/workspace-server/run/workspace.sock"

# lsof is an apt package on the disposable root volume while this script and the
# unit live on /home. Without it we cannot tell a stale socket from a live owner,
# so fail closed rather than deleting a socket that another server is serving.
if ! command -v lsof >/dev/null 2>&1; then
  printf 'lsof is unavailable, so socket ownership cannot be determined.\n' >&2
  exit 1
fi

if lsof -t -- "$socket" >/dev/null 2>&1; then
  printf 'Emdash workspace socket is owned by another process: %s\n' "$socket" >&2
  exit 1
fi
rm -f "$socket"
SCRIPT
chmod 0755 "$prestart"

unit_dir="$HOME/.config/systemd/user"
unit="$unit_dir/$service"
mkdir -p "$unit_dir"
cat > "$unit" <<'UNIT'
[Unit]
Description=Emdash workspace server
After=network-online.target
Wants=network-online.target
RequiresMountsFor=/home
ConditionPathIsMountPoint=/home
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStartPre=%h/.local/bin/emdash-workspace-server-prestart
ExecStart=%h/.emdash/workspace-server/current/bin/emdash-workspace-server serve --socket
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user stop "$service" 2>/dev/null || true

listener=$(lsof -F pT -- "$socket" 2>/dev/null \
  | awk '/^p/{pid=substr($0,2)} /^TST=LISTEN$/{print pid; exit}' || true)
if [[ -n "$listener" ]]; then
  command_line=$(tr '\0' ' ' < "/proc/$listener/cmdline")
  if [[ "$command_line" != *"/.emdash/workspace-server/"*" serve --socket"* ]]; then
    printf 'Refusing to replace unknown process %s using %s\n' "$listener" "$socket" >&2
    exit 1
  fi

  kill "$listener"
  for _ in {1..20}; do
    kill -0 "$listener" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$listener" 2>/dev/null; then
    printf 'Emdash workspace server process %s did not stop\n' "$listener" >&2
    exit 1
  fi
fi

# Write host settings only once every server is stopped. A running server may
# persist its own settings on shutdown and revert the values we just installed.
settings_state="$HOME/.emdash/workspace-server/state/host-settings.json"
if [[ -n "${EMDASH_HOST_SETTINGS:-}" ]]; then
  install -D -m 0644 "$EMDASH_HOST_SETTINGS" "$settings_state"
fi

rm -f "$socket"
systemctl --user reset-failed "$service" 2>/dev/null || true
systemctl --user enable "$service"
systemctl --user start "$service"

sleep 6
active=$(systemctl --user is-active "$service")
main_pid=$(systemctl --user show "$service" -p MainPID --value)
listener=$(lsof -F pT -- "$socket" 2>/dev/null \
  | awk '/^p/{pid=substr($0,2)} /^TST=LISTEN$/{print pid; exit}' || true)
restarts=$(systemctl --user show "$service" -p NRestarts --value)

if [[ "$active" != "active" || "$main_pid" != "$listener" || "$restarts" != "0" ]]; then
  systemctl --user --no-pager status "$service" >&2 || true
  printf 'Emdash workspace server failed stability check: active=%s pid=%s listener=%s restarts=%s\n' \
    "$active" "$main_pid" "$listener" "$restarts" >&2
  exit 1
fi

if [[ -n "${EMDASH_HOST_SETTINGS:-}" ]] && ! cmp -s "$EMDASH_HOST_SETTINGS" "$settings_state"; then
  printf 'Emdash reverted its host settings after startup: %s\n' "$settings_state" >&2
  exit 1
fi

printf 'Emdash workspace server is stable and owned by %s.\n' "$service"
