#!/data/data/com.termux/files/usr/bin/bash
# ==========================================================
#  重启设备上的 VS Code（openvscode-server，跑在 proot 里）
#
#  用法（Termux）:  bash ~/vscode-web.sh
#
#  可选环境变量:
#      PROOT_DISTRO=ubuntu   VSCODE_PORT=8080   VSCODE_DIR=/root/openvscode-server
# ==========================================================
set -u
DISTRO="${PROOT_DISTRO:-ubuntu}"
PORT="${VSCODE_PORT:-8080}"
DIR="${VSCODE_DIR:-/root/openvscode-server}"

termux-wake-lock 2>/dev/null || true
# 方括号避免 pkill -f 匹配到本脚本自己
pkill -f 'openvscode-server/bin/openvscode-serve[r]' 2>/dev/null || true
sleep 3

cd "$HOME"
nohup proot-distro login "$DISTRO" -- bash -lc \
  "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; exec $DIR/bin/openvscode-server --host 127.0.0.1 --port $PORT --without-connection-token --disable-telemetry" \
  > "$HOME/vscode-web.log" 2>&1 < /dev/null &

echo "已启动，等待就绪 ..."
for i in $(seq 1 20); do
  sleep 2
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" "http://127.0.0.1:$PORT/" 2>/dev/null)
  echo "  [$((i*2))s] HTTP=$code"
  [ "$code" = "200" ] && break
done
echo "--- ~/vscode-web.log 尾部 ---"
tail -5 "$HOME/vscode-web.log" 2>/dev/null
