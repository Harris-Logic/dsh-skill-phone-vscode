#!/usr/bin/env bash
# Run a command on the device over ssh, resolving its current address first.
#
#   ./ph.sh 'uname -a'          # inside Termux
#   ./ph.sh -u 'dsh --version'  # inside the proot distro (clean PATH)
#
# Env: PHONE_HOST (ssh alias, default "phone"), PHONE_IP (skip auto-detect)
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHONE_HOST="${PHONE_HOST:-phone}"
PHONE_IP="${PHONE_IP:-}"
OPTS="-o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes"
CLEAN_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

resolve_ip() {
  [ -n "$PHONE_IP" ] && return 0
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      local ps1="$SCRIPT_DIR/phone-ip.ps1"
      [ -f "$ps1" ] || return 0
      local win; win="$(cygpath -w "$ps1" 2>/dev/null || printf '%s' "$ps1")"
      PHONE_IP=$(powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$win" 2>/dev/null | tr -d '\r' | head -1) ;;
    Darwin)
      PHONE_IP=$(ipconfig getoption en0 router 2>/dev/null) ;;
    *)
      PHONE_IP=$(ip route show default dev wlan0 2>/dev/null | awk '{print $3; exit}')
      [ -z "$PHONE_IP" ] && PHONE_IP=$(ip route show default 2>/dev/null | awk '{print $3; exit}') ;;
  esac
}
resolve_ip

if [ -n "$PHONE_IP" ]; then
  OPTS="$OPTS -o HostName=$PHONE_IP"
fi

if [ "${1:-}" = "-u" ]; then
  shift
  CMD="export PATH=$CLEAN_PATH; $*"
  exec ssh $OPTS "$PHONE_HOST" "proot-distro login ubuntu -- bash -lc $(printf '%q' "$CMD")"
fi
exec ssh $OPTS "$PHONE_HOST" "bash -lc $(printf '%q' "$*")"
