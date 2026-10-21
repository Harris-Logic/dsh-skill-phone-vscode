#!/data/data/com.termux/files/usr/bin/bash
# ==========================================================
#  在 Termux 里一条命令装好 openvscode-server（跑在 proot 发行版里）
#
#  用法:
#      bash vscode-install.sh
#
#  可选环境变量:
#      PROOT_DISTRO=ubuntu      proot-distro 的发行版名
#      VSCODE_PORT=8080         设备端监听端口（只绑 127.0.0.1）
#      VSCODE_DIR=/root/openvscode-server   安装目录（proot 内路径）
# ==========================================================
set -u

DISTRO="${PROOT_DISTRO:-ubuntu}"
PORT="${VSCODE_PORT:-8080}"
DIR_IN_PROOT="${VSCODE_DIR:-/root/openvscode-server}"

say() { printf '%s\n' "$*"; }

command -v proot-distro >/dev/null 2>&1 || {
  say "!! 没装 proot-distro：pkg install proot-distro"
  exit 1
}
termux-wake-lock 2>/dev/null || true

if proot-distro login "$DISTRO" -- true >/dev/null 2>&1; then
  say ">>> 发行版 $DISTRO 已就绪"
else
  say ">>> 发行版 $DISTRO 不存在，正在安装（几分钟）..."
  proot-distro install "$DISTRO" || { say "!! proot-distro install $DISTRO 失败"; exit 1; }
fi

# ---- proot 内执行的安装脚本（下载 + 校验 + 解压）----
INNER=$(cat <<'INNER_EOF'
#!/bin/bash
set -u
PORT="$1"
DIR="$2"
say() { printf '%s\n' "$*"; }

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) A=arm64 ;;
  x86_64|amd64)  A=x64 ;;
  *) say "!! 不支持的架构: $ARCH"; exit 1 ;;
esac

if [ -x "$DIR/bin/openvscode-server" ]; then
  say ">>> 已安装: $("$DIR/bin/openvscode-server" --version 2>/dev/null | head -1)"
  exit 0
fi

command -v curl >/dev/null 2>&1 || { say "!! 容器里没有 curl：apt-get install -y curl"; exit 1; }

URL=""
api=$(curl -fsSL -m 20 https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest 2>/dev/null || true)
if [ -n "$api" ]; then
  URL=$(printf '%s' "$api" | grep -o 'https://[^"]*linux-'"$A"'\.tar\.gz' | head -1)
fi
if [ -z "$URL" ]; then
  # GitHub API 未鉴权会 403（限流），退回已知可用版本
  URL="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v1.109.5/openvscode-server-v1.109.5-linux-$A.tar.gz"
fi
say ">>> 下载: $URL"

TOTAL=$(curl -sIL -m 30 "$URL" 2>/dev/null | awk '{ if (tolower($1)=="content-length:") v=$2 } END { gsub(/\r/,"",v); print v }')
case "${TOTAL:-}" in ''|*[!0-9]*) say "!! 拿不到包大小（网络？）"; exit 1 ;; esac
say ">>> 大小: $TOTAL 字节，开始分块续传"

TMP=/root/.vscode-pkg.tar.gz
rm -f "$TMP"
CHUNK=$((2 * 1024 * 1024))
start=0
while [ "$start" -lt "$TOTAL" ]; do
  end=$((start + CHUNK - 1))
  [ "$end" -ge "$TOTAL" ] && end=$((TOTAL - 1))
  want=$((end - start + 1))
  ok=""
  for try in 1 2 3 4 5; do
    curl -sSL --max-time 300 -r "$start-$end" -o /tmp/.vscode-chunk "$URL" 2>/dev/null
    got=$(stat -c %s /tmp/.vscode-chunk 2>/dev/null || echo 0)
    [ "$got" -eq "$want" ] && { ok=1; break; }
    sleep 2
  done
  if [ -z "$ok" ]; then say "!! 第 $start 块连续失败，重跑本脚本会续传"; exit 1; fi
  cat /tmp/.vscode-chunk >> "$TMP"
  start=$((end + 1))
  say "    progress=$start/$TOTAL"
done

gzip -t "$TMP" 2>/dev/null || { say "!! 包损坏，删掉重来"; rm -f "$TMP"; exit 1; }

# proot 里 chmod rootfs 有限制，必须带这三个参数 + strip-components
mkdir -p "$DIR"
tar -xzf "$TMP" --no-same-owner --no-same-permissions --no-overwrite-dir \
    --strip-components=1 -C "$DIR" || { say "!! 解压失败"; exit 1; }
rm -f "$TMP" /tmp/.vscode-chunk
say ">>> 已解压到 $DIR：$("$DIR/bin/openvscode-server" --version 2>/dev/null | head -1)"
INNER_EOF
)

B64=$(printf '%s' "$INNER" | base64 | tr -d '\n')
say ">>> 在 $DISTRO 里安装 openvscode-server（慢链路会分块续传，可中断后重跑）..."
proot-distro login "$DISTRO" -- bash -lc \
  "echo $B64 | base64 -d > /root/.vscode-install-inner.sh && bash /root/.vscode-install-inner.sh '$PORT' '$DIR_IN_PROOT'" \
  || { say "!! 安装失败"; exit 1; }

# ---- 生成 Termux 侧的重启脚本 ----
WEB_SH="$HOME/vscode-web.sh"
cat > "$WEB_SH" <<WEB_EOF
#!/data/data/com.termux/files/usr/bin/bash
# 重启设备上的 VS Code（openvscode-server，跑在 proot $DISTRO 里）
termux-wake-lock 2>/dev/null || true
pkill -f 'openvscode-server/bin/openvscode-serve[r]' 2>/dev/null || true
sleep 3
cd "\$HOME"
nohup proot-distro login $DISTRO -- bash -lc \\
  'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin; exec $DIR_IN_PROOT/bin/openvscode-server --host 127.0.0.1 --port $PORT --without-connection-token --disable-telemetry' \\
  > "\$HOME/vscode-web.log" 2>&1 < /dev/null &
echo "已启动，等待就绪 ..."
for i in \$(seq 1 20); do
  sleep 2
  code=\$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:$PORT/ 2>/dev/null)
  echo "  [\$((i*2))s] HTTP=\$code"
  [ "\$code" = "200" ] && break
done
tail -5 "\$HOME/vscode-web.log" 2>/dev/null
WEB_EOF
chmod +x "$WEB_SH"
say ">>> 已生成 $WEB_SH"

say ">>> 启动并验证 ..."
bash "$WEB_SH"

say ""
say "============================================================"
say "  设备本机浏览器:  http://127.0.0.1:$PORT/"
say "  另一台电脑:      在本机跑 scripts/phone-code.sh，隧道到 127.0.0.2:18080"
say "  重启服务:        bash ~/vscode-web.sh"
say "============================================================"
