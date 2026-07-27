#!/system/bin/sh
# =============================================================================
# MagiskSSH WebUI API Script
# Called by ksu.exec() / ksu.spawn() from the frontend WebUI.
#
# Usage: sh api.sh <action> [args...]
#
# Actions:
#   status        - Check if sshd is running, return JSON status
#   start         - Start sshd service
#   stop          - Stop sshd service
#   restart       - Restart sshd service
#   read_config   - Read sshd_config content (base64 encoded)
#   write_config  - Write base64-encoded stdin to sshd_config
#   read_keys     - Read authorized_keys content
#   write_keys    - Write stdin to authorized_keys
#   add_key       - Append a key from stdin to authorized_keys
#   delete_key    - Delete key at line number ($2)
#   get_ip        - Get device local IP address
#   tail_log      - Tail -f the ssh log (for spawn, streaming)
#   read_log      - Read ssh log snapshot (for exec, one-shot)
#   read_log_from - Read log lines from offset $2 onwards, prints "<total>\n<lines>"
#   clear_log     - Truncate the ssh log file
# =============================================================================

# --- Paths -------------------------------------------------------------------
# Derive MODDIR from this script's own location: .../scripts/api.sh → ...
MODDIR="$(dirname "$(dirname "$(readlink -f "$0")")")"

# MagiskSSH stores persistent data under /data/adb/ssh (patched from /data/ssh)
SSHDIR="/data/adb/ssh"

SSHD_BIN="/system/bin/sshd"
SSHD_CONFIG="${SSHDIR}/sshd_config"
PID_FILE="${SSHDIR}/sshd.pid"

# MagiskSSH has two users: root and shell, each with their own authorized_keys
AUTH_KEYS_ROOT="${SSHDIR}/root/.ssh/authorized_keys"
AUTH_KEYS_SHELL="${SSHDIR}/shell/.ssh/authorized_keys"

# Resolve keys file based on optional user arg (default: root)
get_keys_file() {
  case "${1:-root}" in
    shell) echo "$AUTH_KEYS_SHELL" ;;
    *)     echo "$AUTH_KEYS_ROOT"  ;;
  esac
}

# sshd does not write a log file by default; we redirect via -E flag when
# starting through the WebUI. On stock MagiskSSH (opensshd.init) there is
# no log file — so we create one if needed.
LOG_FILE="${SSHDIR}/sshd.log"

# The original init script shipped with the module
INIT_SCRIPT="${MODDIR}/opensshd.init"

# --- Helpers -----------------------------------------------------------------

json_escape() {
  # 1. 逃逸反斜杠和引号
  # 2. 将换行符转为 \n
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN { ORS="\\n" } { print }' | sed 's/\\n$//'
}

json_ok() {
  local msg
  msg=$(json_escape "$1")
  printf '{"errno":0,"stdout":"%s","stderr":""}\n' "$msg"
}

json_err() {
  local msg
  msg=$(json_escape "$1")
  printf '{"errno":1,"stdout":"","stderr":"%s"}\n' "$msg"
}

get_pid() {
  # First try the PID file
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  # Fallback to pidof; take only the first PID (master process)
  pidof sshd 2>/dev/null | awk '{print $1}'
}

ensure_dirs() {
  mkdir -p "${SSHDIR}/root/.ssh" 2>/dev/null
  mkdir -p "${SSHDIR}/shell/.ssh" 2>/dev/null
  touch "$AUTH_KEYS_ROOT" "$AUTH_KEYS_SHELL" 2>/dev/null
  chmod 600 "$AUTH_KEYS_ROOT" "$AUTH_KEYS_SHELL" 2>/dev/null
}

# --- Actions -----------------------------------------------------------------

do_status() {
  local pid port running="false"
  pid=$(get_pid)
  if [ -n "$pid" ]; then
    running="true"
    port=$(grep -i "^Port " "$SSHD_CONFIG" 2>/dev/null | awk '{print $2}')
    [ -z "$port" ] && port="22"
  fi
  json_ok "{\"running\":$running,\"pid\":\"$pid\",\"port\":\"$port\"}"
}

do_get_ip() {
  # 按优先级尝试常见接口，取第一个有效 IPv4
  local ip
  for iface in wlan0 wlan1 eth0 eth1 rmnet_data0 rmnet0; do
    ip=$(ip addr show "$iface" 2>/dev/null \
         | grep 'inet ' \
         | awk '{print $2}' \
         | cut -d'/' -f1 \
         | head -1)
    if [ -n "$ip" ]; then
        json_ok "$ip"
        return 0
    fi
  done
  # fallback: 取所有非 127.x 的 inet 地址里的第一个
  ip=$(ip addr 2>/dev/null \
       | grep 'inet ' \
       | grep -v '127\.0\.0' \
       | awk '{print $2}' \
       | cut -d'/' -f1 \
       | head -1)
  json_ok "${ip:-unknown}"
}

do_start() {
  local pid
  pid=$(get_pid)
  if [ -n "$pid" ]; then
    json_ok "sshd already running (pid ${pid})"
    return 0
  fi

  # Use the module's opensshd.init if available (it handles key generation etc.)
  if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" start >/dev/null 2>&1
  elif [ -x "$SSHD_BIN" ]; then
    # Direct start with log redirect
    "$SSHD_BIN" -f "$SSHD_CONFIG" -E "$LOG_FILE" >/dev/null 2>&1
  else
    json_err "sshd binary not found"
    return 1
  fi

  sleep 1
  pid=$(get_pid)
  if [ -n "$pid" ]; then
    json_ok "sshd started (pid ${pid})"
  else
    json_err "sshd failed to start"
    return 1
  fi
}

do_stop() {
  local pid
  pid=$(get_pid)
  if [ -z "$pid" ]; then
    json_ok "sshd is not running"
    return 0
  fi

  if [ -x "$INIT_SCRIPT" ]; then
    "$INIT_SCRIPT" stop >/dev/null 2>&1
  else
    kill "$pid" 2>/dev/null
  fi

  sleep 1
  pid=$(get_pid)
  if [ -z "$pid" ]; then
    json_ok "sshd stopped"
  else
    kill -9 "$pid" 2>/dev/null
    json_ok "sshd force killed"
  fi
}

do_restart() {
  do_stop >/dev/null 2>&1
  sleep 1
  do_start
}

do_read_config() {
  if [ -f "$SSHD_CONFIG" ]; then
    local content
    content=$(base64 "$SSHD_CONFIG")
    json_ok "$content"
  else
    json_err "Config file not found: ${SSHD_CONFIG}"
    return 1
  fi
}

do_write_config() {
  local b64
  b64=$(cat)
  if [ -z "$b64" ]; then
    json_err "Empty config content"
    return 1
  fi
  printf '%s' "$b64" | base64 -d > "$SSHD_CONFIG"
  chmod 600 "$SSHD_CONFIG"
  json_ok "Config saved"
}

do_read_keys() {
  local target
  target=$(get_keys_file "$1")
  ensure_dirs
  if [ -f "$target" ]; then
    local content
    content=$(cat "$target")
    json_ok "$content"
  else
    json_ok ""
  fi
}

do_write_keys() {
  local target
  target=$(get_keys_file "$1")
  ensure_dirs
  local b64
  b64=$(cat)
  printf '%s' "$b64" | base64 -d > "$target"
  chmod 600 "$target"
  json_ok "Keys saved"
}

do_add_key() {
  local target
  target=$(get_keys_file "$1")
  ensure_dirs
  local b64 key
  b64=$(cat)
  key=$(printf '%s' "$b64" | base64 -d)
  if [ -z "$key" ]; then
    json_err "Empty key"
    return 1
  fi
  printf '%s\n' "$key" >> "$target"
  chmod 600 "$target"
  json_ok "Key added"
}

do_delete_key() {
  local line_num="$1"
  local user="$2"
  local target
  target=$(get_keys_file "$user")
  if [ -z "$line_num" ]; then
    json_err "Line number required"
    return 1
  fi
  case "$line_num" in
    ''|*[!0-9]*) json_err "Invalid line number: ${line_num}"; return 1 ;;
  esac
  ensure_dirs
  sed -i "${line_num}d" "$target"
  json_ok "Key at line ${line_num} deleted"
}

do_tail_log() {
  # Designed for ksu.spawn() — streams continuously
  if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
  fi
  exec tail -f "$LOG_FILE"
}

do_read_log() {
  if [ -f "$LOG_FILE" ]; then
    local content
    content=$(tail -n 200 "$LOG_FILE" | base64)
    json_ok "$content"
  else
    json_ok ""
  fi
}

# read_log_from <start_line>
# Returns: first line = total line count of log file
#          remaining lines = new content from start_line onwards
do_read_log_from() {
  local start="${1:-1}"
  if [ ! -f "$LOG_FILE" ]; then
    json_ok "$(printf '0' | base64)"
    return 0
  fi
  local total output
  total=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$start" -le "$total" ]; then
    output=$(printf '%s\n%s' "$total" "$(tail -n +"$start" "$LOG_FILE")" | base64)
    json_ok "$output"
  else
    json_ok "$(printf '%s' "$total" | base64)"
  fi
}

do_clear_log() {
  if [ -f "$LOG_FILE" ]; then
    : > "$LOG_FILE"
    json_ok "Log cleared"
  else
    json_ok "Log file does not exist"
  fi
}

do_get_settings() {
  local autostart="true"
  local keep_data="false"
  [ -f "${SSHDIR}/no-autostart" ] && autostart="false"
  [ -f "${SSHDIR}/KEEP_ON_UNINSTALL" ] && keep_data="true"
  json_ok "{\"autostart\":$autostart,\"keep_data\":$keep_data}"
}

do_set_settings() {
  local autostart="$1"
  local keep_data="$2"
  
  if [ "$autostart" = "true" ]; then
    rm -f "${SSHDIR}/no-autostart"
  else
    touch "${SSHDIR}/no-autostart"
  fi

  if [ "$keep_data" = "true" ]; then
    touch "${SSHDIR}/KEEP_ON_UNINSTALL"
  else
    rm -f "${SSHDIR}/KEEP_ON_UNINSTALL"
  fi
  json_ok "Settings updated"
}

# --- Main Dispatcher ---------------------------------------------------------

ACTION="$1"
shift

case "$ACTION" in
  status)        do_status ;;
  start)         do_start ;;
  stop)          do_stop ;;
  restart)       do_restart ;;
  read_config)   do_read_config ;;
  write_config)  do_write_config ;;
  read_keys)     do_read_keys  "$1" ;;
  write_keys)    do_write_keys "$1" ;;
  add_key)       do_add_key    "$1" ;;
  delete_key)    do_delete_key "$1" "$2" ;;
  get_ip)        do_get_ip ;;
  tail_log)      do_tail_log ;;
  read_log)      do_read_log ;;
  read_log_from) do_read_log_from "$1" ;;
  clear_log)     do_clear_log ;;
  get_settings)  do_get_settings ;;
  set_settings)  do_set_settings "$1" "$2" ;;
  *)
    json_err "Unknown action: ${ACTION}"
    exit 1
    ;;
esac
