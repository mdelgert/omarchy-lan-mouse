#!/usr/bin/env bash
# Shared helpers for the omarchy-lan-mouse plugin scripts.
#
# The plugin never runs user-supplied shell. Every script that accepts a
# subnet or a port validates it here first and refuses to build a command
# out of anything that does not match, so a bad value in shell.json fails
# loudly instead of reaching pacman, ufw, or a shell.
#
# Sourced, not executed. Callers are expected to `set -uo pipefail`.

DEFAULT_SUBNET="192.168.100.0/24"
DEFAULT_PORT="4242"
UFW_COMMENT="Lan Mouse"

# ---- Paths. Everything this plugin tracks lives under one per-user runtime
#      directory, which systemd clears at logout — so a PID from a previous
#      session can never be mistaken for a live daemon.

runtime_dir() {
  local base="${XDG_RUNTIME_DIR:-}"
  # /run/user/<uid> is what XDG_RUNTIME_DIR points at on a systemd session;
  # falling back to it keeps the path identical when the variable is unset
  # (a bare `bash -c` from the shell process, say) rather than inventing a
  # second location.
  [[ -n $base ]] || base="/run/user/$(id -u)"
  printf '%s/omarchy-lan-mouse\n' "$base"
}

pid_file() { printf '%s/lan-mouse.pid\n' "$(runtime_dir)"; }
log_file() { printf '%s/lan-mouse.log\n' "$(runtime_dir)"; }

config_file() {
  printf '%s/lan-mouse/config.toml\n' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

ensure_runtime_dir() {
  local dir
  dir="$(runtime_dir)" || return 1
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null
  return 0
}

# ---- Validation. Both predicates are total: they answer for any input and
#      never evaluate it.

valid_port() {
  local value="${1:-}"
  [[ $value =~ ^[0-9]{1,5}$ ]] || return 1
  # 10# so a value like 0080 is read as decimal rather than octal.
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

valid_subnet() {
  local value="${1:-}"
  [[ $value =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
  local octet
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    (( 10#$octet <= 255 )) || return 1
  done
  (( 10#${BASH_REMATCH[5]} <= 32 ))
}

# Echo the argument when it validates, the default otherwise. Used by
# health-check, which reports on whatever the shell.json settings are and
# must not abort on a typo.
checked_port()   { valid_port   "${1:-}" && printf '%s\n' "$1" || printf '%s\n' "$DEFAULT_PORT"; }
checked_subnet() { valid_subnet "${1:-}" && printf '%s\n' "$1" || printf '%s\n' "$DEFAULT_SUBNET"; }

# ---- Daemon identity. The plugin owns exactly one process and identifies it
#      by PID *and* by what that PID is actually running. PIDs are recycled,
#      so a stored number alone proves nothing.

# True when $1 is a live `lan-mouse daemon` owned by this user.
is_tracked_daemon() {
  local pid="${1:-}"
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  (( pid > 1 )) || return 1
  [[ -r /proc/$pid/cmdline ]] || return 1

  # Ownership check first: /proc/<pid> is owned by the process's real UID, so
  # this refuses to touch anything that is not ours even if the name matches.
  local owner
  owner="$(stat -c %u "/proc/$pid" 2>/dev/null)" || return 1
  [[ $owner == "$(id -u)" ]] || return 1

  local -a argv=()
  mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || return 1
  (( ${#argv[@]} >= 2 )) || return 1
  [[ ${argv[0]##*/} == "lan-mouse" ]] || return 1

  # `daemon` anywhere in the arguments, so an invocation carrying --port or
  # --config still matches. Subcommands other than `daemon` do not.
  local arg
  for arg in "${argv[@]:1}"; do
    [[ $arg == "daemon" ]] && return 0
  done
  return 1
}

# Print the tracked PID when the recorded process is a live lan-mouse daemon.
# Returns non-zero (printing nothing) when there is no PID file, the file is
# junk, or the PID belongs to something else.
tracked_pid() {
  local file pid
  file="$(pid_file)"
  [[ -f $file ]] || return 1
  read -r pid < "$file" 2>/dev/null || return 1
  is_tracked_daemon "$pid" || return 1
  printf '%s\n' "$pid"
}

# ---- JSON. A five-line encoder rather than a jq dependency, so the widget
#      still reports health on a machine where jq is missing.

json_string() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  # Strip any remaining C0 control characters; none of our values need them.
  s="$(printf '%s' "$s" | tr -d '\000-\037')"
  printf '"%s"' "$s"
}

# Every `lan-mouse daemon` owned by this user, one PID per line. Read-only,
# and used only to *report* daemons this plugin did not start — a lan-mouse
# the user launched by hand still shows up in health, but Stop will not touch
# it. This is the whole reason the plugin tracks a PID file instead of
# matching on process name.
lan_mouse_daemon_pids() {
  local -a candidates=()
  if command -v pgrep >/dev/null 2>&1; then
    # Matches on comm, which is cheap; is_tracked_daemon does the real
    # verification on each hit below.
    mapfile -t candidates < <(pgrep -u "$(id -u)" -x lan-mouse 2>/dev/null)
  else
    local entry
    for entry in /proc/[0-9]*; do
      candidates+=("${entry##*/}")
    done
  fi

  local pid
  for pid in "${candidates[@]}"; do
    is_tracked_daemon "$pid" && printf '%s\n' "$pid"
  done
  return 0
}
