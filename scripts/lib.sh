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

# ---- Filesystem checks. The plugin's own directories and files are the only
#      things it will read state from or write state into, and "its own" is
#      decided by inspecting them rather than by trusting the path.

# True when $1 is a directory this user owns, is not itself a symlink, and is
# closed to group and other. Anything else is refused rather than used: a
# directory another user can write into or substitute is not somewhere this
# plugin can keep a lock or a switch position.
dir_is_own_private() {
  local dir="${1:-}" facts raw uid mode
  [[ -n $dir ]] || return 1
  [[ -L $dir ]] && return 1
  # %f is the raw mode in hex. Tested numerically rather than against %F,
  # whose wording varies with the file ("regular file", "regular empty file").
  facts="$(stat -c '%f|%u|%a' -- "$dir" 2>/dev/null)" || return 1
  IFS='|' read -r raw uid mode <<<"$facts"
  (( (16#$raw & 8#170000) == 8#040000 )) || return 1
  [[ $uid == "$(id -u)" ]] || return 1
  (( 8#$mode & 8#077 )) && return 1
  return 0
}

# True when the *open descriptor* $1 is a regular file this user owns, with a
# single link and no write access for anyone else.
#
# Opening a pathname follows symlinks, and a name can be replaced between the
# test and the open. Bash cannot pass O_NOFOLLOW, so nothing here is decided
# from the name: the redirection is performed first and then judged through
# /proc/self/fd/<n>, which describes what the open actually landed on. A
# redirect that arrived via a symlink, at a hardlinked file, or at a file
# other users can write is rejected at that point, before it is read or
# written. Callers pass fd 3 — a descriptor a child inherits, so the `stat`
# below sees the same file the shell opened.
fd_is_own_private_file() {
  local fd="${1:-}" facts raw uid mode links
  [[ $fd =~ ^[0-9]+$ ]] || return 1
  facts="$(stat -L -c '%f|%u|%a|%h' "/proc/self/fd/$fd" 2>/dev/null)" || return 1
  IFS='|' read -r raw uid mode links <<<"$facts"
  (( (16#$raw & 8#170000) == 8#100000 )) || return 1
  [[ $uid == "$(id -u)" ]] || return 1
  [[ $links == "1" ]] || return 1
  (( 8#$mode & 8#022 )) && return 1
  return 0
}

ensure_runtime_dir() {
  local dir
  dir="$(runtime_dir)" || return 1
  [[ -L $dir ]] && return 1
  mkdir -p -- "$dir" || return 1
  chmod 700 -- "$dir" 2>/dev/null
  dir_is_own_private "$dir"
}

# ---- Output limits. Panel.qml runs these scripts through a Process with a
#      StdioCollector and keeps each payload whole in memory, so whatever
#      reaches stdout or stderr is bounded here, at the producer, rather than
#      trusted to be short. The daemon log and `lan-mouse --version` are the
#      two sources whose length this plugin does not control at all.

FIELD_MAX_CHARS=200
LOG_EXCERPT_LINES=15
LOG_EXCERPT_COLUMNS=200
LOG_EXCERPT_BYTES=4096

# Echo $1 shortened to $2 characters (default FIELD_MAX_CHARS), marked when
# something was cut so a truncated value does not read as a complete one.
clamp_field() {
  local s="${1:-}" max="${2:-$FIELD_MAX_CHARS}"
  if (( ${#s} > max )); then
    printf '%s...\n' "${s:0:max}"
  else
    printf '%s\n' "$s"
  fi
}

# A bounded tail of a log file: at most LOG_EXCERPT_LINES lines, each clipped
# to LOG_EXCERPT_COLUMNS, the result capped at LOG_EXCERPT_BYTES, and C0
# controls dropped so a daemon log line cannot carry escape sequences into the
# terminal or the panel. Tab and newline are kept. Returns non-zero when there
# is nothing to show.
log_excerpt() {
  local path="${1:-}" text=""
  [[ -f $path && -s $path ]] || return 1
  text="$(tail -n "$LOG_EXCERPT_LINES" -- "$path" 2>/dev/null \
    | tr -d '\000-\010\013-\037\177' \
    | cut -c "1-$LOG_EXCERPT_COLUMNS" \
    | head -c "$LOG_EXCERPT_BYTES")"
  [[ -n $text ]] || return 1
  printf '%s\n' "$text"
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
  # stderr redirected first: the shell reports a failed input redirection
  # before a later 2>/dev/null takes effect, and a process exiting between
  # the check above and this read is normal, not something to print about.
  mapfile -d '' -t argv 2>/dev/null < "/proc/$pid/cmdline" || return 1
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

# ---- Desired state. The PID file lives in the runtime directory, which
#      systemd clears at logout — by design, so a dead session's PID cannot
#      be mistaken for a live daemon. That means it cannot also answer "did
#      the user leave this switched on?", which has to outlive the session.
#      So intent is recorded separately, under XDG_STATE_HOME, and the two
#      are read for different questions: the PID file for what *is* running,
#      this file for what *should* be.
#
#      Both directions go through fd 3 and fd_is_own_private_file: the file is
#      opened first and then judged by what the descriptor turned out to be,
#      so neither a symlink at the path nor a name swapped in mid-operation
#      decides where this plugin reads its intent from or writes it to.

state_dir() {
  printf '%s/omarchy-lan-mouse\n' "${XDG_STATE_HOME:-$HOME/.local/state}"
}

desired_state_file() { printf '%s/daemon-desired\n' "$(state_dir)"; }

ensure_state_dir() {
  local dir
  dir="$(state_dir)" || return 1
  [[ -L $dir ]] && return 1
  mkdir -p -- "$dir" || return 1
  chmod 700 -- "$dir" 2>/dev/null
  dir_is_own_private "$dir"
}

# Print "on" or "off", never anything else. A missing, unreadable, or
# unconvincing file reads as "off": a user who has never touched the switch
# has not asked for a daemon, and a file this plugin cannot vouch for is not
# grounds for starting one.
#
# The mode test allows the wider-but-unwritable permissions an older version
# of this plugin could leave behind, so an existing switch position survives
# the upgrade; anything group- or world-writable does not.
read_desired_state() {
  local file value=""
  file="$(desired_state_file)"
  if [[ ! -L $file ]]; then
    # stderr first: the shell reports a failed input redirection before a
    # later 2>/dev/null on the same command takes effect, and a missing file
    # is the ordinary case here, not something to print about.
    { fd_is_own_private_file 3 && read -r value <&3; } 2>/dev/null 3<"$file" || value=""
  fi
  [[ $value == "on" ]] && printf 'on\n' || printf 'off\n'
}

# Write the switch position. Returns non-zero without touching the recorded
# answer if any step fails, so a write that cannot be made safely leaves the
# previous answer standing rather than a truncated or unowned file.
write_desired_state() {
  local want="${1:-}" dir file tmp
  [[ $want == "on" || $want == "off" ]] || return 1
  ensure_state_dir || return 1
  dir="$(state_dir)"
  file="$(desired_state_file)"

  # mktemp under umask 077: the name is unpredictable, so it cannot be
  # pre-planted as a symlink, and the file is created O_EXCL and mode 600 so
  # no other user can open it. This replaces a temp path derived from the PID,
  # which was guessable by anyone who could see the process list.
  tmp="$(umask 077; mktemp -- "$dir/.daemon-desired.XXXXXXXXXX" 2>/dev/null)" || return 1
  [[ -n $tmp ]] || return 1

  if ! { fd_is_own_private_file 3 && printf '%s\n' "$want" >&3; } 2>/dev/null 3>"$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi

  # rename(2) replaces a symlink at the destination rather than following it,
  # and is atomic, so the switch reads as either the old answer or the new one
  # and never as a half-written file.
  if ! mv -f -- "$tmp" "$file" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}
