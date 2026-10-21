#!/usr/bin/env bash
# ==========================================================
#  Laptop side: reach the device's openvscode-server through an SSH tunnel
#
#  浏览器 → http://127.0.0.2:18080 ──ssh -N -L──► 设备 127.0.0.1:8080
#
#  Usage:
#      ./phone-code.sh              # create/reuse tunnel, print the URL
#      ./phone-code.sh --stop       # stop the tunnel (device server keeps running)
#
#  Env:
#      PHONE_HOST=phone   ssh alias (User/Port/Key), default "phone"
#      PHONE_IP=1.2.3.4   override address detection
#      LOCAL_HOST=127.0.0.2  local bind address (loopback alias, keeps 127.0.0.1 free)
#      LOCAL_PORT=18080      local port (Windows reserved ranges are skipped)
#      REMOTE_PORT=8080      device port
#      PHONE_RESTART=1       stop the old tunnel and rebuild
#      PHONE_OPEN=1          open the URL in the default browser
# ==========================================================
set -u

PHONE_HOST="${PHONE_HOST:-phone}"
PHONE_IP="${PHONE_IP:-}"
LOCAL_HOST="${LOCAL_HOST:-127.0.0.2}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
REMOTE_PORT="${REMOTE_PORT:-8080}"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  Darwin)               PLATFORM=macos ;;
  *)                    PLATFORM=linux ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNDIR="$SCRIPT_DIR/.run"
mkdir -p "$RUNDIR" 2>/dev/null

say() { printf '%s\n' "$*"; }

# ---------- --stop ----------
if [ "${1:-}" = "--stop" ]; then
  found=""
  for pf in "$RUNDIR"/code-*.pid; do
    [ -f "$pf" ] || continue
    pid=$(cat "$pf" 2>/dev/null)
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null && say "stopped tunnel pid $pid ($(basename "$pf"))" && found=1
    fi
    rm -f "$pf"
  done
  [ -z "$found" ] && say "no running tunnel found"
  say "note: the server on the device keeps running; restart it with: ssh <device> 'bash ~/vscode-web.sh'"
  exit 0
fi

# ---------- Windows: avoid reserved port ranges ----------
port_excluded() {
  [ "$PLATFORM" = "windows" ] || return 1
  netsh int ipv4 show excludedportrange protocol=tcp 2>/dev/null | awk -v p="$1" '
    $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && p + 0 >= $1 + 0 && p + 0 <= $2 + 0 { hit = 1 }
    END { exit hit ? 0 : 1 }'
}

REQUESTED_PORT="$LOCAL_PORT"
if port_excluded "$LOCAL_PORT"; then
  for cand in 18081 18082 18083 18084; do
    if ! port_excluded "$cand"; then
      LOCAL_PORT="$cand"
      say ">>> local port $REQUESTED_PORT is in a Windows reserved range, using $LOCAL_PORT"
      break
    fi
  done
fi

TAG="${LOCAL_HOST//:/_}-${LOCAL_PORT}"
PIDFILE="$RUNDIR/code-$TAG.pid"
TUNLOG="$RUNDIR/code-$TAG.log"
URL="http://$LOCAL_HOST:$LOCAL_PORT/"

# ---------- single instance lock ----------
LOCKDIR="$RUNDIR/.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  LOCK_PID=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [ -n "${LOCK_PID:-}" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    say "!! another phone-code.sh is running (pid $LOCK_PID); wait for it"
    exit 1
  fi
  rm -rf "$LOCKDIR" 2>/dev/null
  mkdir "$LOCKDIR" 2>/dev/null || { say "!! cannot take lock $LOCKDIR"; exit 1; }
fi
echo $$ > "$LOCKDIR/pid" 2>/dev/null
trap 'rm -rf "$LOCKDIR" 2>/dev/null' EXIT

# ---------- resolve the device address ----------
if [ -z "$PHONE_IP" ]; then
  case "$PLATFORM" in
    windows)
      if [ -f "$SCRIPT_DIR/phone-ip.ps1" ]; then
        win="$(cygpath -w "$SCRIPT_DIR/phone-ip.ps1" 2>/dev/null || printf '%s' "$SCRIPT_DIR/phone-ip.ps1")"
        PHONE_IP=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
                   -File "$win" 2>/dev/null | tr -d '\r' | head -1)
      fi ;;
    macos)
      PHONE_IP=$(ipconfig getoption en0 router 2>/dev/null) ;;
    *)
      PHONE_IP=$(ip route show default dev wlan0 2>/dev/null | awk '{print $3; exit}')
      [ -z "$PHONE_IP" ] && PHONE_IP=$(ip route show default 2>/dev/null | awk '{print $3; exit}') ;;
  esac
fi

SSH_OPTS="-o LogLevel=ERROR -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ConnectTimeout=10"
TUNNEL_OPTS="-o ExitOnForwardFailure=yes -o BatchMode=yes"
if [ -n "$PHONE_IP" ]; then
  SSH_OPTS="$SSH_OPTS -o HostName=$PHONE_IP"
  TARGET="$PHONE_HOST -> $PHONE_IP"
else
  TARGET="$PHONE_HOST (address from ssh config)"
fi

# ---------- helpers ----------
looks_like_code() {  # $1 = base URL; the workbench index references stable-<hash>
  curl -s -m 8 --noproxy '*' "$1" 2>/dev/null | grep -qE 'workbench|stable-[0-9a-f]{6,}'
}

open_url() {
  case "$PLATFORM" in
    windows) cmd.exe /c start "" "$1" >/dev/null 2>&1 ;;
    macos)   open "$1" >/dev/null 2>&1 ;;
    *)       xdg-open "$1" >/dev/null 2>&1 ;;
  esac
}

# ---------- 1) ssh reachability ----------
if ! ssh -o ConnectTimeout=8 -o BatchMode=yes $SSH_OPTS "$PHONE_HOST" 'true' 2>/dev/null; then
  say "!! cannot reach the device ($TARGET)"
  say "   1) is this laptop on the device's hotspot / same LAN?"
  say "   2) is sshd running on the device (Termux, port 8022)?"
  say "   3) specify manually: PHONE_IP=192.168.43.1 ./phone-code.sh"
  exit 1
fi
say ">>> ssh ok ($TARGET)"

# ---------- 2) make sure the server runs on the device ----------
phone_http() {
  ssh $SSH_OPTS "$PHONE_HOST" \
    "curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:$REMOTE_PORT/" 2>/dev/null
}

STATE=$(phone_http)
if [ "$STATE" != "200" ]; then
  say ">>> device server not answering (HTTP=${STATE:-000}), starting it ..."
  ssh $SSH_OPTS "$PHONE_HOST" 'bash ~/vscode-web.sh' 2>/dev/null | sed 's/^/    /'
  for _ in $(seq 1 10); do
    sleep 2
    STATE=$(phone_http)
    [ "$STATE" = "200" ] && break
  done
fi
if [ "$STATE" != "200" ]; then
  say "!! device server is not up (HTTP=${STATE:-000})"
  say "   on the device: bash ~/vscode-web.sh   (see ~/vscode-web.log)"
  exit 1
fi
say ">>> device server: HTTP=200"

# ---------- 3) tunnel ----------
if [ "${PHONE_RESTART:-0}" = "1" ] && [ -f "$PIDFILE" ]; then
  OLD=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "${OLD:-}" ] && kill "$OLD" 2>/dev/null && sleep 2 && say ">>> stopped old tunnel (pid $OLD)"
  rm -f "$PIDFILE"
fi

if looks_like_code "$URL"; then
  say ">>> tunnel already up: $URL"
else
  ATTEMPT=0; READY=""
  while [ "$ATTEMPT" -lt 3 ]; do
    ATTEMPT=$((ATTEMPT + 1))
    say ">>> building tunnel $URL -> device 127.0.0.1:$REMOTE_PORT ..."
    : > "$TUNLOG"
    nohup ssh -N -L "$LOCAL_HOST:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT" \
          $SSH_OPTS $TUNNEL_OPTS "$PHONE_HOST" >>"$TUNLOG" 2>&1 &
    TUNNEL_PID=$!
    echo "$TUNNEL_PID" > "$PIDFILE" 2>/dev/null || true
    disown 2>/dev/null || true
    for _ in $(seq 1 10); do
      sleep 1
      kill -0 "$TUNNEL_PID" 2>/dev/null || break
      if looks_like_code "$URL"; then READY=yes; break; fi
    done
    [ -n "$READY" ] && break
    if grep -qiE 'bind \[|cannot listen to port' "$TUNLOG" 2>/dev/null; then
      say "    local port $LOCAL_PORT busy, retry in 2s ..."
      sleep 2
      continue
    fi
    break
  done
  if [ -z "$READY" ]; then
    say "!! tunnel failed. log:"
    sed 's/^/   /' "$TUNLOG" 2>/dev/null
    if port_excluded "$LOCAL_PORT"; then
      say "   cause: $LOCAL_PORT is in a Windows reserved range (bind always denied)"
      say "   fix:  LOCAL_PORT=18090 ./phone-code.sh"
      say "   or (admin): netsh int ipv4 delete excludedportrange protocol=tcp startport=$LOCAL_PORT numberofports=1"
    fi
    exit 1
  fi
  say ">>> tunnel up (pid $TUNNEL_PID)"
fi

# ---------- 4) end to end ----------
if ! looks_like_code "$URL"; then
  say "!! $URL does not look like the VS Code workbench"
  say "   something else may be listening there; try LOCAL_PORT=18090"
  exit 1
fi


say ""
say "============================================================"
say "  browser:  $URL"
say "  on the device itself, no tunnel needed:  http://127.0.0.1:$REMOTE_PORT/"
say "============================================================"
say "  stop tunnel : $0 --stop"
say "  restart srv : ssh <device> 'bash ~/vscode-web.sh'"
say "  log         : $TUNLOG"

if [ "${PHONE_OPEN:-0}" = "1" ]; then
  say ">>> opening in the default browser ..."
  open_url "$URL" || say "   (could not open automatically, copy the URL above)"
fi
