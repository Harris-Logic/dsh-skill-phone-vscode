# dsh-skill-phone-vscode

A DeepSeek Harness **skill** that turns a phone or tablet (Termux + proot distro) into a
**browser-accessible VS Code host**: open `http://127.0.0.1:8080/` in the device's own browser,
or `http://127.0.0.2:18080/` from another laptop through an SSH tunnel bound to the loopback
alias `127.0.0.2`.

把手机/平板（Termux + proot 发行版）变成「浏览器里的 VS Code 主机」：
设备自己的浏览器开 `127.0.0.1:8080`；别的笔记本走 SSH 隧道连 `127.0.0.2:18080`，
两者互不干扰，换设备一条命令复现。

```
on the device : browser → http://127.0.0.1:8080   (no tunnel)
other laptop  : browser → http://127.0.0.2:18080 ──ssh -N -L──► device 127.0.0.1:8080
```

## Why this shape

| Decision | Reason |
|---|---|
| **openvscode-server**, not official `code serve-web` | the official *server* package ships without `workbench.html` (`/` → 404); the desktop package needs Chromium libs in the container. openvscode-server is a 74 MB self-contained web build |
| **bind `127.0.0.1` on the device** | an editable IDE is an RCE surface; never `--host 0.0.0.0` |
| **tunnel binds `127.0.0.2`** | keeps `127.0.0.1:*` free on the laptop, and gives the IDE its own cookie domain |
| **`--without-connection-token`** | acceptable only because the listener is loopback-only and reached through SSH; add `--connection-token` if you ever expose it |
| **device address = WLAN default gateway** | on a hotspot the device *is* the gateway; its MAC is randomized per session, so MAC lookup is not an option |
| **chunked 2 MB resume download** | 74 MB over a hotspot stalls repeatedly at the same byte; chunks + retries finish the job |

## Quick start

### 1) On the device (Termux)

```bash
bash scripts/vscode-install.sh
```

It detects the arch, fetches the latest openvscode-server, downloads it in resumable chunks,
extracts it into the proot distro (`/root/openvscode-server`), writes `~/vscode-web.sh`,
starts the server and waits for `HTTP 200`.

### 2) On the laptop

```powershell
git clone https://github.com/Harris-Logic/dsh-skill-phone-vscode
cd dsh-skill-phone-vscode
powershell -ExecutionPolicy Bypass -File .\install.ps1     # copy the skill into ~/.dsh/skills
scripts\phone-code.cmd                                      # build/reuse the tunnel, print the URL
```

Prerequisite: an `~/.ssh/config` alias (default `phone`) that supplies User/Port/Key — the script
detects the address itself and overrides only `HostName`:

```
Host phone
  HostName 192.168.43.1     # overridden by -o HostName=<detected>
  Port 8022
  User u0_a488
  IdentityFile ~/.ssh/termux_ssh_key
  StrictHostKeyChecking accept-new
```

## Scripts

| File | Runs on | Purpose |
|---|---|---|
| `scripts/vscode-install.sh` | device (Termux) | install openvscode-server into the proot distro, write `~/vscode-web.sh` |
| `scripts/vscode-web.sh` | device (Termux) | restart the server, wait for `HTTP 200` |
| `scripts/phone-code.sh` | laptop | resolve device IP, ensure the server, build/reuse the tunnel, verify, print URL (`--stop` to close) |
| `scripts/phone-code.cmd` | Windows | double-click wrapper around `phone-code.sh` |
| `scripts/phone-ip.ps1` | Windows laptop | resolve the device address from the WLAN default gateway, verified on port 8022 |
| `scripts/ph.sh` | laptop | run a command on the device (`-u` for the proot distro) |

## Env

| Var | Default | Meaning |
|---|---|---|
| `PHONE_HOST` | `phone` | ssh alias |
| `PHONE_IP` | auto | override address detection |
| `LOCAL_HOST` | `127.0.0.2` | laptop bind address |
| `LOCAL_PORT` | `18080` | laptop port (Windows reserved ranges auto-skip) |
| `REMOTE_PORT` | `8080` | device port |
| `PHONE_RESTART` | `0` | `1` = rebuild the tunnel |
| `PHONE_OPEN` | `0` | `1` = open the browser |
| `PROOT_DISTRO` / `VSCODE_PORT` / `VSCODE_DIR` | `ubuntu` / `8080` / `/root/openvscode-server` | device-side install knobs |

## Gotchas (already handled in the scripts)

- **Start the server from Termux, not inside proot**: `proot-distro login` uses `--kill-on-exit`,
  so a `nohup` background job inside a proot session dies with the session.
- **`tar` in proot fails with `Cannot change mode`**: use
  `--no-same-owner --no-same-permissions --no-overwrite-dir --strip-components=1`.
- **Windows reserved port ranges** make *any* bind return `Permission denied` (WSAEACCES), which
  looks like "the tunnel is still holding the port". Check
  `netsh int ipv4 show excludedportrange protocol=tcp`.
- **Android freezes Termux**: `termux-wake-lock` (built into the scripts) plus disabling battery
  optimization for Termux.
- Extensions come from **Open VSX**: no Pylance / Copilot / C# Dev Kit. Use desktop VS Code with
  Remote-SSH if you need those.

See `SKILL.md` for the full skill text (when to use, troubleshooting table, verification checklist).
