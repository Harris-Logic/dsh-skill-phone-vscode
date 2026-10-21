# 手机/平板 → 浏览器里的 VS Code（openvscode-server + SSH 隧道）

把任意一台能跑 Termux 的手机/平板变成一台 **Web IDE 主机**：浏览器打开就是完整的 VS Code，
文件、终端、编译都在设备本地；同机浏览器直连 `127.0.0.1:8080`，
别的笔记本走 SSH 隧道连 `127.0.0.2:18080`，互不干扰。

## 何时用

- 想在手机/平板上跑 VS Code，但**用别的设备的浏览器**来操作（手机屏幕小、平板当屏幕）；
- 只有手机/平板是「算力 + 环境」，笔记本只是终端；
- 要在没有 Docker 的 Android 上做「类云端 IDE」，做题、写脚本、看项目；
- 换设备（新手机、平板、旧手机）要**一条命令复现**这套环境。

**不要**用它替代 Dev Containers：Android 上没有 Docker 守护进程（无 root、无 cgroups），
Dev Containers 扩展也只在桌面版 VS Code 里加载。需要 `devcontainer.json` 的隔离性时，
用多个 `proot-distro` 发行版当「容器」（可 tar 打包/还原），这是 Android 上最接近的做法。

## 两种访问方式

```
【同一台设备】浏览器 → http://127.0.0.1:8080   （不需要隧道、不需要 ssh）
【跨设备】    浏览器 → http://127.0.0.2:18080 ──ssh -N -L──► 设备 127.0.0.1:8080
```

- 同机方式最简单：Termux 里 `termux-open-url http://127.0.0.1:8080/`。
- 跨设备方式沿用 dsh 隧道那套约定：本机绑**回环别名 127.0.0.2**、端口 **18080**，
  这样不会和本机已有的 `127.0.0.1:8080` 打架，cookie 也是独立域名。
- **设备端永远只绑 `127.0.0.1`**。这是能改文件的 IDE（等价 RCE 面），
  任何 `--host 0.0.0.0` / 局域网直连都是在裸奔；要远程就用隧道或 Tailscale。

## 为什么不是官方 `code serve-web`

实测（openvscode-server 之前踩的两条）：

| 尝试 | 结果 |
|---|---|
| 官方 **server** 包 `server-linux-arm64`（217 MB） | 只有 Remote-SSH 后端，`out/` 里**没有 `workbench.html`**，`http://…:8080/` 返回 `404 Not Found`，日志也没有 "Web UI available" |
| 官方 **桌面**包 + `bin/code serve-web` | 桌面包含 Web 客户端，但 `bin/code` 在 Linux 上是 `ELECTRON_RUN_AS_NODE=1 code out/cli.js`，
 动态链接器仍要 Chromium 图形库（libnss3/libgbm/libgtk…），容器里要额外装 ~200 MB |
| **openvscode-server**（本技能） | 74 MB 单包、自带 Web 客户端、只依赖 glibc，proot 里直接跑 ✅ |

结论：要「浏览器 UI + 轻量自包含」，openvscode-server 是 Android/proot 上最省事的选择；
代价是扩展走 **Open VSX**（没有 Pylance / Copilot / C# Dev Kit 这类微软专有件）。

## 前置条件

1. **设备**：Android 7+（Termux 可用）、ARM64 或 x86_64；磁盘 ≥ 2 GB 余量；
   Termux 里装好 `proot-distro` 和至少一个发行版（脚本会检测，缺了会 `proot-distro install ubuntu`）；
2. **SSH**（仅跨设备方式需要）：设备跑着 sshd（Termux 默认 8022），本机公钥在
   `~/.ssh/authorized_keys` 里；
3. **本机** `~/.ssh/config` 里有别名，脚本只用它拿 User/Port/Key，**不用它的 IP**
   （IP 每次热点重连都会变，脚本自己探测）：

```
Host phone
  HostName 192.168.43.1     # 会被 -o HostName=<探测到的地址> 覆盖，写什么都行
  Port 8022
  User u0_a488
  IdentityFile ~/.ssh/termux_ssh_key
  StrictHostKeyChecking accept-new
```

## 安装

### 设备端（Termux，一条命令）

```bash
# 从仓库取脚本；或把 scripts/ 拷到设备上
bash scripts/vscode-install.sh
```

它会：检测架构 → 从 GitHub 取最新 openvscode-server → **分块断点续传下载**（慢链路也能完成）→
解压到 proot 里的 `/root/openvscode-server` → 写 `~/vscode-web.sh` → 启动并等 `HTTP 200`。

可选环境变量：`PROOT_DISTRO=debian`、`VSCODE_PORT=8080`、`VSCODE_DIR=/root/openvscode-server`。

### 本机（把 skill 装进 dsh）

```powershell
git clone https://github.com/Harris-Logic/dsh-skill-phone-vscode
cd dsh-skill-phone-vscode
powershell -ExecutionPolicy Bypass -File .\install.ps1
# 或手工：把 SKILL.md + scripts/ 复制到 %USERPROFILE%\.dsh\skills\phone-vscode-server\
```

新开一个 dsh 会话，catalog 里出现 `phone-vscode-server`。

## 用法

```bat
scripts\phone-code.cmd            :: Windows 双击/命令行，成功返回 0
```

```bash
./scripts/phone-code.sh           # 建隧道/复用 → 打印浏览器地址
./scripts/phone-code.sh --stop    # 关掉本机隧道（设备端服务继续跑）
./scripts/ph.sh -u 'uname -a'     # 顺手在设备 proot 里执行命令
```

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `PHONE_HOST` | `phone` | ssh 别名，提供 User/Port/Key |
| `PHONE_IP` | 自动 | 手工指定设备地址（探测失败时） |
| `LOCAL_HOST` | `127.0.0.2` | 本机（笔记本）监听地址 |
| `LOCAL_PORT` | `18080` | 本机监听端口，Windows 保留段会自动避让 |
| `REMOTE_PORT` | `8080` | 设备上 openvscode-server 的端口 |
| `PHONE_RESTART` | `0` | `1` = 先停旧隧道再重建 |
| `PHONE_OPEN` | `0` | `1` = 跑完用默认浏览器打开 |

设备端服务重启：`bash ~/vscode-web.sh`（打印 20 秒内每次探测的 HTTP 码）。

## 关键坑（都踩过）

### 1) 服务必须从 **Termux** 侧后台拉起，不能在 proot 会话里 `nohup`

`proot-distro login` 默认 `--kill-on-exit`：会话一退出，里面所有子进程**连同 nohup 的一起被杀**。
所以启动命令必须是 Termux 侧：

```bash
nohup proot-distro login ubuntu -- bash -lc 'exec /root/openvscode-server/bin/openvscode-server …' \
  > ~/vscode-web.log 2>&1 < /dev/null &
```

让 proot 进程本身常驻，服务才活得下来。`vscode-install.sh` 和 `vscode-web.sh` 都是这么写的。

### 2) proot 里 `tar -xzf` 会报 `Cannot change mode …`

proot 对 rootfs 里的 chmod 有限制，直接解压会失败在顶层目录。加三个参数：

```bash
tar -xzf pkg.tar.gz --no-same-owner --no-same-permissions --no-overwrite-dir \
    --strip-components=1 -C /root/openvscode-server
```

### 3) 慢/不稳的链路：必须分块续传

热点/移动网络下载 74–217 MB 会在同一位置反复卡死（实测卡在 91 MB、95 MB 两次）。
`vscode-install.sh` 用 2 MB 分块 + 每块最多重试 5 次 + 断点续传到已有文件，
卡住只损失一块，整体能走完。

### 4) Windows 端口保留段

```cmd
netsh int ipv4 show excludedportrange protocol=tcp
```

落在保留段里的端口**任何新 bind 都返回 `Permission denied`（WSAEACCES）**，和「谁占着」无关；
旧监听照常工作，最容易误判成「上次隧道没释放」。脚本检测到就自动 `18080→18081…`，
并打印永久解法（管理员）：

```cmd
netsh int ipv4 delete excludedportrange protocol=tcp startport=3080 numberofports=1
```

### 5) 设备地址问「网关」，不要问「MAC」

热点下设备既是 DHCP 服务器也是默认网关 → 默认网关就是它，换网段也成立。
MAC 不可靠：热点 AP 的 BSSID 常被随机化（本地管理位 = 1），每次开热点都变；
ARP 表还只在有流量后才有条目。候选地址还要再验一次 **8022 端口通**才算设备。

### 6) 手机休眠会冻结 Termux

`termux-wake-lock`（脚本已带）+ Android 电池优化里把 Termux 设为「不限制」；
否则服务在几十分钟后无响应，重跑 `vscode-web.sh` 即恢复。

## 排障对照表

| 现象 | 真正原因 | 处置 |
|---|---|---|
| `http://127.0.0.2:18080/` 打不开 | 隧道没建 / 端口被占 | 重跑 `phone-code.sh`；看 `LOCAL_PORT` 是否被保留段吞掉 |
| 本机 18080 已被别的服务泛监听（`0.0.0.0:18080`） | 泛监听与具体地址可以并存，内核按最具体地址分发 | 一般不用管；脚本用**页面内容**判断隧道是否可用，不看端口有没有响应 |
| 设备端 `HTTP=200`，本机 `000` | 隧道没起或绑错地址 | `netstat -ano -p tcp | findstr :18080` 看有没有 `127.0.0.2:18080` |
| `bind [127.0.0.2]:18080: Permission denied` | Windows 保留段（不是没释放） | 换端口，或管理员删保留段 |
| `连不上设备` | 热点没连、IP 变、sshd 没跑 | `netsh wlan show interfaces` 看 SSID；`PHONE_IP=` 手工指定 |
| 设备端进程在但端口无响应 | Termux 被冻结 | Termux 里 `bash ~/vscode-web.sh` |
| 浏览器白屏 | 服务刚起、静态资源还没就绪 | 等 3–5 秒刷新；`tail -f ~/vscode-web.log` 看 `Web UI available` |
| 扩展商店搜不到 Pylance/Copilot | Open VSX 没有微软专有扩展 | 正常；需要就用桌面版 VS Code + Remote-SSH |

## 验证清单

- [ ] 设备上 `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/` → `200`
- [ ] 本机 `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.2:18080/` → `200`
- [ ] 页面源码含 `stable-<hash>/static/...`（确认是 workbench，不是别的服务）
- [ ] 同机浏览器 `http://127.0.0.1:8080/` 能进（不依赖隧道）
- [ ] 再跑一次 `phone-code.sh` → `已有隧道，复用`
- [ ] 关掉本机隧道（`--stop`）后重跑 → 能重建

## 安全

- 默认 `--without-connection-token`：**只在服务绑 `127.0.0.1`、且外部只经 SSH 隧道**的前提下可接受；
  一旦你把它绑到 `0.0.0.0`，必须加 `--connection-token`。
- 隧道只绑回环；不要 `-L 0.0.0.0:...`。
- 设备端 root（proot 内）可读写整个 rootfs，别把 `~/.ssh` 私钥、token 放进被共享的目录。

## 为什么是 skill 而不是插件

没有运行时注入：不需要向 dsh 进程注册服务、不改 `cordis.patch.yml`。
它是「操作规程 + 可执行脚本」，随 skill 分发；只有想把隧道管理变成 dsh 内的工具时才值得做成插件。
