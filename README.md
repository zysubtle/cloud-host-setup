# cloud-setup — 云主机「ssh + tmux + Claude Code」远程工作环境

把这个目录整个拷到一台新的 Ubuntu 云主机上，跑一个脚本，之后就能从 Mac / Ubuntu 用
ssh 一连上去就看到 `/data` 下的项目菜单，选一个目录直接接回该目录的 Claude Code 会话。

## 目录内容

| 文件 | 作用 | 在哪运行 |
|---|---|---|
| `setup-claude-host.sh` | 一键配置主机：装 tmux、locale、PATH、写 `~/.terminal-rc`，安装启动脚本，可选装远程桌面 | 新主机，普通用户 |
| `terminal-startup.sh` | 登录后的目录菜单 + 接回/恢复 Claude 的 tmux 会话（部署时被复制为 `~/.terminal-startup.sh`） | 由 `~/.terminal-rc` 自动 source |
| `mount-data-disk.sh` | 识别、格式化并挂载 ECS 数据盘到 `/data`，写入 fstab | 新主机，sudo |
| `setup-xrdp.sh` | 安装 XFCE 桌面 + xrdp + Firefox，供 Mac 的 Windows App 远程桌面连接 | 新主机，sudo（`setup-claude-host.sh` 会自动调用） |

## 整体链路

```
客户端 Terminal / Termius
  └─ ssh -t <别名> bash --rcfile /home/<用户>/.terminal-rc
       └─ ~/.terminal-rc    : source ~/.bashrc ; cd /data ; source ~/.terminal-startup.sh
            └─ terminal-startup.sh
                 1. 列出 /data 下的一级子目录（含隐藏目录），让你选一个
                 2. cd 进去，按目录物理路径算出固定会话名  termius-claude-<sha256(目录)>
                 3. 该 tmux 会话已存在 → 直接接回
                    会话在但进程已退出 → 在原窗格里重新执行 claude --continue
                    会话不存在        → 新建会话并运行 claude --continue，然后接入
```

- 菜单里输入 `0`、直接回车、`q` 或 Ctrl-D 会退出菜单，停在 `/data` 的普通 shell。
- 在 Claude 里按 `Ctrl-b d` 脱离 tmux，回到 shell；下次连上再选同一目录就接回来。
- ssh 断线（换网络、电脑休眠）不会中断 Claude，它一直跑在 tmux 里；重新连接后选同一目录即可接回。
- 同一个目录永远对应同一个 tmux 会话，所以多台客户端选同一目录会看到同一个画面。
- 会话名前缀 `termius-claude-` 和函数名 `termius_*` 是刻意保留的，改掉会让已有会话接不回来。

## 新主机部署步骤

1. **先装好 Claude Code 并授权一次**
   普通 ssh 登录，安装 `claude`（确保在 PATH 里，例如 `~/.local/bin`），运行一次 `claude` 完成登录。
   启动脚本用的是 `claude --continue`，没授权过是进不去的。

2. **拷贝本目录**
   ```bash
   scp -r ~/cloud-setup user@host:~/
   ```

3. **（有数据盘时）先挂数据盘**
   ```bash
   ssh -t user@host 'sudo bash ~/cloud-setup/mount-data-disk.sh --detect'   # 只看不改
   ssh -t user@host 'sudo bash ~/cloud-setup/mount-data-disk.sh'            # 挂到 /data
   ```

4. **运行主机配置脚本**
   ```bash
   ssh -t user@host 'bash ~/cloud-setup/setup-claude-host.sh'
   ```
   脚本结束时会打印客户端要填的连接命令。常用环境变量：

   | 变量 | 作用 |
   |---|---|
   | `SKIP_XRDP=1` | 不装远程桌面 |
   | `XRDP_ARGS="--public --no-browser"` | 透传给 `setup-xrdp.sh` 的参数 |
   | `USER_ONLY=1` | 只写用户目录下的配置，跳过所有需要 sudo 的步骤 |
   | `FORCE=1` | 覆盖已存在且内容不同的 `~/.terminal-rc` / `~/.terminal-startup.sh`（原文件自动备份） |
   | `STARTUP_SRC=/路径` | 指定启动脚本来源文件（默认用本目录的 `terminal-startup.sh`） |

   脚本可以重复执行：配置文件内容相同就跳过，不同且没给 `FORCE=1` 时只警告不覆盖。

5. **云厂商安全组放行**
   - 日常连接只用 SSH（TCP `22`），能跑上面的脚本就说明已经通了，不用再加规则。
   - 远程桌面用了 `--public` 时：入方向 TCP `3389`（来源建议只填自己的 IP）

6. **客户端配置**

   `~/.ssh/config` 加一段并确认 `ssh <别名> 'echo ok'` 免密能通（不行就 `ssh-copy-id <别名>`）：
   ```
   Host <别名>
       HostName <公网IP>
       User <用户>
       ServerAliveInterval 60
   ```

   连接命令（Terminal.app 描述文件的「运行命令」、Termius 本地终端的 Snippet 都填这一条）：
   ```bash
   ssh -t <别名> bash --rcfile /home/<用户>/.terminal-rc
   ```
   - `-t` 不能省：带命令时 ssh 默认不分配终端，bash 不会进入交互模式，目录菜单和 tmux 都起不来。
   - 建议写绝对路径：写 `~` 的话要加引号，否则会被本地 shell 展开成本机的路径。
   - 不要再在外面套一层 `tmux new -A`，启动脚本自己管理 tmux。
   - 用 Termius 自带的 SSH 连主机时，也可以把 `exec bash --rcfile ~/.terminal-rc` 设为该主机的启动 Snippet（在服务器上执行）。

## 各脚本详细说明

### setup-claude-host.sh

按顺序做这些事（`USER_ONLY=1` 时跳过前两项和建 `/data`）：

1. `apt` 安装 `tmux curl ca-certificates`
2. 生成 `en_US.UTF-8`，当前 locale 不是 UTF-8 时把系统默认设为 `C.UTF-8`
3. `~/.bashrc` 加入 `~/.local/bin` 到 PATH
4. 检查 `claude` 是否可用，没有就退出（不代装）
5. 创建 `/data` 并把属主改成当前用户
6. 写入 `~/.terminal-rc`，把 `terminal-startup.sh` 复制为 `~/.terminal-startup.sh`
7. 同目录有 `setup-xrdp.sh` 时用 sudo 执行它（失败不影响前面的配置，脚本以退出码 1 结束）
8. 打印 ssh config、连接命令两件事

不能用 root 运行，否则配置会写到 `/root` 下。

### terminal-startup.sh

被 `~/.terminal-rc` source，不是独立执行的脚本（没有 shebang，不要 `bash terminal-startup.sh`）。

- `termius_menu`：通用编号菜单，会过滤方向键等转义序列，输入无效时重新询问。
- `termius_choose_directory`：扫描 `/data` 的一级子目录，选中后 `cd -P` 进入。
- `termius_launch_claude`：检查 `tmux` `claude` `sha256sum` 都在，然后按上面「整体链路」的三种情况接回或新建会话。
  传给 tmux 会话的环境：只有 `PATH`（保证找得到 `~/.local/bin/claude`）。不再传 `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`——它会把 Claude Code 固定成经典渲染器，盖过 `~/.claude/settings.json` 的 `tui` 设置；渲染器由 `/tui` 决定（全屏在 tmux 里可用，滚轮依赖 tmux `mouse on`）。
- 最后一行 `clear; { termius_choose_directory && termius_launch_claude; } || :` 保证任何一步失败都只是留在 shell，不会把登录 shell 带崩。

本目录里的 `terminal-startup.sh` 是一份独立的普通文件，登录时实际读取的是 `~/.terminal-startup.sh`，两者需要手动保持一致。
改过其中一份之后，用下面的命令同步并核对：

```bash
cp ~/.terminal-startup.sh ~/cloud-setup/terminal-startup.sh   # 改的是登录用的那份，同步到部署目录
cp ~/cloud-setup/terminal-startup.sh ~/.terminal-startup.sh   # 改的是部署目录那份，同步到登录用的
diff ~/.terminal-startup.sh ~/cloud-setup/terminal-startup.sh && echo 一致
```

在本机重跑 `setup-claude-host.sh` 时，两份内容相同就跳过；不同且没给 `FORCE=1` 只会警告，不会覆盖登录用的那份。

### mount-data-disk.sh

```bash
sudo ./mount-data-disk.sh                     # 自动检测数据盘，挂到 /data
sudo ./mount-data-disk.sh /mnt/data           # 指定挂载点
sudo ./mount-data-disk.sh /data /dev/nvme0n1  # 指定挂载点和设备
sudo ./mount-data-disk.sh --detect            # 只检测，不做任何修改
```

- 候选数据盘 = 整盘、不是系统盘、没有分区、没有被挂载；找到多块时要求手动指定。
- 盘上没有文件系统 → 提示输入 `yes` 后格式化为 ext4，并把挂载点属主改成执行 sudo 的用户。
- 盘上已有文件系统 → 不格式化，直接挂载（保留数据）。
- fstab 用 UUID 写入，带 `nofail`，写完会 `mount -a` 立即验证，写坏了当场报错而不是重启后才发现。

### setup-xrdp.sh

```bash
sudo bash setup-xrdp.sh               # 默认：xrdp 只监听 127.0.0.1，通过 SSH 隧道连接（推荐）
sudo bash setup-xrdp.sh --public      # 监听所有网卡，直接连 公网IP:3389（需放行 TCP 3389）
sudo bash setup-xrdp.sh --user NAME   # 指定登录桌面的用户；默认是执行 sudo 的用户，不存在则创建
sudo bash setup-xrdp.sh --no-browser  # 不装 Firefox（snap 包，约 1.5 GB）
```

- 只在 Ubuntu 24.04 上验证过；要求根分区剩余 3 GB 以上。
- 可重复执行，也可用来在隧道/公网两种模式之间切换。
- 检测到有人正在远程桌面里时会拒绝改配置（重启 xrdp 会让已有桌面会话失联），先注销再重跑。
- 隧道模式 Mac 端连接：本地开一个终端保持 `ssh -N -L 3389:127.0.0.1:3389 用户@主机`，Windows App 里添加 PC `127.0.0.1`。

## 本机自测

```bash
bash --rcfile ~/.terminal-rc    # 应直接弹出 /data 的目录菜单；输 0 回到 shell
bash -n ~/.terminal-startup.sh  # 语法检查
HOME=$(mktemp -d) USER_ONLY=1 bash ~/cloud-setup/setup-claude-host.sh   # 在临时目录里演练安装
```

注意：在菜单里选了目录就会真的去接 tmux 会话；只想看菜单的话选 `0`。
不要在主机上执行 `tmux kill-server`，它会连带结束所有目录的 Claude 会话。

## 常见问题

- **连上后没有菜单，直接是 shell，或者什么都不显示**
  先看连接命令有没有带 `-t`；再看 `~/.terminal-rc` 第二行是否存在；`/data` 下没有任何子目录时菜单也会跳过并提示。
- **`claude --continue` 进不去 / 窗口一闪就退**
  先普通 ssh 登录运行一次 `claude` 完成授权；或者 `~/.local/bin` 不在 PATH 里（脚本会往 `~/.bashrc` 追加）。
- **登录时报 `setlocale: ... cannot change locale`**
  客户端经 ssh 传过来的 `LANG`（例如 `en_NZ.UTF-8`）服务器上没有，`sudo locale-gen <该 locale>` 后重新连接。

## 更名记录

2026-11-04：`termius-startup.sh` 改名为 `terminal-startup.sh`（它已不只给 Termius 用）。
`~/.termius-startup.sh` 保留为指向新文件的符号链接，旧的 Termius Snippet 不改也能用；
客户端全部改成新名字后可以删掉这个链接。

2026-11-08：改用 ssh 连接，不再安装 mosh、不再放行 UDP 60000-61000；`~/.mosh-rc` 改名为 `~/.terminal-rc`。
已经部署过的旧主机不受影响，上面的 `~/.mosh-rc` 和 mosh 照旧可用。
