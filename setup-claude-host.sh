#!/usr/bin/env bash
#
# setup-claude-host.sh — 在新的 Ubuntu 云主机上一键配置「mosh + tmux + Claude Code」远程工作环境
#
# 做的事情:
#   1. apt 安装 mosh tmux curl
#   2. 确保 locale 为 UTF-8，并生成 en_US.UTF-8（mosh 对 locale 很挑剔）
#   3. ufw 启用时放行 mosh 的 UDP 60000-61000（云厂商安全组仍需手动放行）
#   4. ~/.bashrc 加入 ~/.local/bin 到 PATH
#   5. 检查 claude 是否已安装（不代装；没有则提示先安装并退出）
#   6. 创建 /data（有数据盘的话之后用 mount-data-disk.sh 挂到这里）
#   7. 写入 ~/.mosh-rc，并把本脚本同目录的 terminal-startup.sh 复制为 ~/.terminal-startup.sh
#   8. 同目录有 setup-xrdp.sh 时，用 sudo 执行它安装 XFCE 远程桌面（可选，SKIP_XRDP=1 跳过）
#   9. 打印客户端要用的连接命令
#
# 用法（在新主机上用普通用户运行，需要 sudo；不要用 root）:
#   scp -r ~/cloud-setup user@host:~/
#   ssh -t user@host 'bash ~/cloud-setup/setup-claude-host.sh'
#
# 可选环境变量:
#   STARTUP_SRC=/路径  指定启动脚本来源文件（默认找本脚本同目录的 terminal-startup.sh）
#   USER_ONLY=1    只做用户目录下的配置，跳过所有需要 sudo 的步骤（apt / locale / ufw / 建 /data）
#   FORCE=1        覆盖已存在但内容不同的 ~/.terminal-startup.sh 和 ~/.mosh-rc（原文件会备份）
#   SKIP_XRDP=1    不执行同目录的 setup-xrdp.sh
#   XRDP_ARGS="..." 传给 setup-xrdp.sh 的参数，例如 XRDP_ARGS="--public --no-browser"
#
set -euo pipefail

DATA_ROOT=/data
RC_FILE="$HOME/.mosh-rc"
STARTUP_FILE="$HOME/.terminal-startup.sh"
BASHRC="$HOME/.bashrc"
USER_ONLY="${USER_ONLY:-0}"
FORCE="${FORCE:-0}"
SKIP_XRDP="${SKIP_XRDP:-0}"
XRDP_ARGS="${XRDP_ARGS:-}"
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "请用普通用户运行（需要 sudo 的地方脚本会自行调用），用 root 会把东西装到 /root 下"

if [[ $USER_ONLY != 1 ]]; then
  command -v sudo >/dev/null || die "缺少 sudo，可用 USER_ONLY=1 只做用户级配置"
  [[ -r /etc/os-release ]] && . /etc/os-release
  [[ "${ID:-}" == ubuntu || "${ID_LIKE:-}" == *debian* ]] || warn "不是 Ubuntu/Debian，apt 相关步骤可能失败"

  # ---------- 1. 软件包 ----------
  log "安装 mosh tmux curl"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mosh tmux curl ca-certificates

  # ---------- 2. locale ----------
  log "检查 locale"
  if ! locale -a 2>/dev/null | grep -qi '^en_US\.utf-\?8$'; then
    echo "生成 en_US.UTF-8（客户端多半会把这个 LANG 传过来）"
    sudo locale-gen en_US.UTF-8 >/dev/null
  fi
  if ! locale charmap 2>/dev/null | grep -qi 'utf-\?8'; then
    warn "当前会话 locale 不是 UTF-8，把系统默认设为 LANG=C.UTF-8（重新登录后生效）"
    sudo update-locale LANG=C.UTF-8
  fi

  # ---------- 3. ufw ----------
  if command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "ufw 已启用，放行 mosh 的 UDP 60000:61000"
    sudo ufw allow 60000:61000/udp >/dev/null
  fi
fi

for bin in mosh-server tmux sha256sum; do
  command -v "$bin" >/dev/null || die "未找到 $bin，请先安装"
done

# ---------- 4. PATH ----------
log "确保 $BASHRC 中有 ~/.local/bin"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "$PATH_LINE" "$BASHRC" 2>/dev/null; then
  printf '\n%s\n' "$PATH_LINE" >> "$BASHRC"
  echo "已追加到 $BASHRC"
fi
export PATH="$HOME/.local/bin:$PATH"

# ---------- 5. Claude Code（不代装，只检查） ----------
if command -v claude >/dev/null; then
  log "Claude Code 已安装: $(command -v claude)"
else
  die "未找到 claude。请先自行安装 Claude Code（并确保它在 PATH 里，例如 ~/.local/bin），然后重新运行本脚本"
fi

# ---------- 6. /data ----------
if [[ $USER_ONLY != 1 && ! -d $DATA_ROOT ]]; then
  log "创建 $DATA_ROOT（有数据盘的话，之后用 mount-data-disk.sh 挂到这里）"
  sudo mkdir -p "$DATA_ROOT"
  sudo chown "$USER:$(id -gn)" "$DATA_ROOT"
fi

# ---------- 7. 配置文件 ----------
# write_file <路径>  （内容从 stdin 读入）
# 已存在且内容相同 -> 跳过；内容不同 -> 默认不覆盖，FORCE=1 时备份后覆盖
write_file() {
  local path=$1 tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ -e $path ]]; then
    if cmp -s "$tmp" "$path"; then
      log "$path 已是最新，跳过"
      rm -f "$tmp"; return 0
    fi
    if [[ $FORCE != 1 ]]; then
      warn "$path 已存在且内容不同，未覆盖（FORCE=1 可覆盖，原文件会备份）"
      rm -f "$tmp"; return 0
    fi
    cp -a "$path" "$path.bak.$(date +%Y%m%d%H%M%S)"
    echo "已备份原文件"
  fi
  install -m 0644 "$tmp" "$path"
  rm -f "$tmp"
  log "已写入 $path"
}

write_file "$RC_FILE" <<'EOF'
[ -f ~/.bashrc ] && source ~/.bashrc
cd /data && source "$HOME/.terminal-startup.sh"
EOF

# 启动脚本来源：优先 STARTUP_SRC 环境变量，其次本脚本同目录下的 terminal-startup.sh / .terminal-startup.sh
startup_src=""
for cand in "${STARTUP_SRC:-}" "$script_dir/terminal-startup.sh" "$script_dir/.terminal-startup.sh"; do
  if [[ -n $cand && -f $cand ]]; then startup_src=$cand; break; fi
done
if [[ -z $startup_src ]]; then
  if [[ -f $STARTUP_FILE ]]; then
    log "未找到启动脚本来源文件，沿用已有的 $STARTUP_FILE"
  else
    die "找不到启动脚本：请把 terminal-startup.sh 放在本脚本同目录（$script_dir），或用 STARTUP_SRC=/路径 指定"
  fi
elif [[ $(realpath "$startup_src") == "$(realpath -m "$STARTUP_FILE")" ]]; then
  log "$STARTUP_FILE 就是来源文件本身，跳过"
else
  log "启动脚本来源: $startup_src"
  write_file "$STARTUP_FILE" < "$startup_src"
fi

# ---------- 8. 远程桌面（可选：同目录有 setup-xrdp.sh 时执行） ----------
XRDP_SCRIPT="$script_dir/setup-xrdp.sh"
XRDP_DONE=0
XRDP_FAILED=0
if [[ $USER_ONLY == 1 ]]; then
  :
elif [[ $SKIP_XRDP == 1 ]]; then
  log "SKIP_XRDP=1，跳过远程桌面"
elif [[ -f $XRDP_SCRIPT ]]; then
  read -r -a xrdp_args <<<"$XRDP_ARGS"
  log "执行 setup-xrdp.sh 安装远程桌面（参数: ${XRDP_ARGS:-无}）"
  if sudo bash "$XRDP_SCRIPT" "${xrdp_args[@]}"; then
    XRDP_DONE=1
  else
    XRDP_FAILED=1
    warn "setup-xrdp.sh 执行失败，上面 mosh 相关配置不受影响；可稍后单独重跑: sudo bash $XRDP_SCRIPT $XRDP_ARGS"
  fi
else
  log "同目录没有 setup-xrdp.sh，跳过远程桌面"
fi

# ---------- 9. 总结 ----------
public_ip=$(curl -fsS4 --max-time 3 https://ifconfig.me 2>/dev/null || echo '<公网IP>')
cat <<EOF

================= 服务器端配置完成 =================

接下来在客户端（Mac / Ubuntu）做三件事：

1. 云厂商安全组放行 UDP 60000-61000
   阿里云：入方向，自定义 UDP，端口 60000/61000，来源 0.0.0.0/0

2. ~/.ssh/config 加一段（别名随意）:
   Host <别名>
       HostName $public_ip
       User $USER
       ServerAliveInterval 60
   并确认 ssh <别名> 'echo ok' 能免密通过（不行就 ssh-copy-id <别名>）

3. Terminal 描述文件的「运行命令」填（必须是绝对路径，mosh 不展开 ~）:
   mosh --predict=never <别名> -- bash --rcfile $RC_FILE

首次使用前，先普通 ssh 登录一次运行 claude 完成授权，
否则启动脚本里的 claude --continue 进不去。
本机自测：bash --rcfile $RC_FILE  应直接弹出 /data 的目录菜单。
EOF
if (( XRDP_DONE )); then
  echo "远程桌面（xrdp）已装好，Mac 端连接方法见上方 setup-xrdp.sh 的输出。"
fi
if (( XRDP_FAILED )); then
  warn "远程桌面步骤失败，详见上方 setup-xrdp.sh 的输出；其余配置已完成。"
  exit 1
fi
