#!/usr/bin/env bash
# 在 Ubuntu 24.04 上安装 XFCE 桌面 + xrdp + Firefox 浏览器，供 macOS 上的 Windows App 远程连接。
#
# 用法（在云主机上执行）：
#   sudo bash setup-xrdp.sh               # 默认：xrdp 只监听 127.0.0.1，通过 SSH 隧道连接（推荐）
#   sudo bash setup-xrdp.sh --public      # xrdp 监听所有网卡，直接连 公网IP:3389（需在安全组放行 3389）
#   sudo bash setup-xrdp.sh --user NAME   # 指定登录桌面的用户；默认是执行 sudo 的用户，不存在则自动创建
#   sudo bash setup-xrdp.sh --no-browser  # 不安装 Firefox
#
# 可以重复执行，也可以用来在两种模式之间切换。

set -Eeuo pipefail
trap 'echo "[错误] 第 $LINENO 行执行失败：$BASH_COMMAND" >&2' ERR

MODE=tunnel
DESKTOP_USER=""
PORT=3389
INSTALL_BROWSER=1

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
die()  { printf '[错误] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：sudo bash setup-xrdp.sh [--public] [--user 用户名] [--no-browser]
  （默认）       xrdp 只监听 127.0.0.1，通过 SSH 隧道连接（推荐）
  --public       xrdp 监听所有网卡，可直接连接 公网IP:3389，需在云安全组放行 TCP 3389
  --user 用户名  登录远程桌面的用户；默认是执行 sudo 的用户，不存在则自动创建
  --no-browser   不安装 Firefox 浏览器（它是 snap 包，连同依赖约 1.5 GB）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public) MODE=public ;;
    --tunnel) MODE=tunnel ;;
    --user)   [[ $# -ge 2 ]] || die "--user 后面需要跟用户名"; DESKTOP_USER="$2"; shift ;;
    --user=*) DESKTOP_USER="${1#*=}" ;;
    --no-browser) INSTALL_BROWSER=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "未知参数：$1" ;;
  esac
  shift
done

# ---------- 前置检查 ----------
[[ $EUID -eq 0 ]] || die "请用 root 权限运行：sudo bash setup-xrdp.sh"
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] \
  || die "本脚本只在 Ubuntu 24.04 上验证过，当前系统是：${PRETTY_NAME:-未知}"

DESKTOP_USER="${DESKTOP_USER:-${SUDO_USER:-}}"
[[ -n "$DESKTOP_USER" && "$DESKTOP_USER" != root ]] \
  || die "请用 --user 指定一个普通用户来登录桌面（不建议用 root），例如：sudo bash setup-xrdp.sh --user myuser"
if ! id "$DESKTOP_USER" >/dev/null 2>&1; then
  [[ "$DESKTOP_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "用户名不合法：$DESKTOP_USER"
fi

# 实测桌面部分约占 2.8 GB（Firefox 另需约 1.5 GB，不够时会跳过）
(( $(df -Pk / | awk 'NR==2 {print $4}') > 3 * 1024 * 1024 )) || die "根分区剩余空间不足 3 GB"
(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) > 1800 * 1024 )) || warn "内存不足 2 GB，桌面可能会比较卡"

# ---------- 登录用户和密码（先问完，后面就不用守着了） ----------
if ! id "$DESKTOP_USER" >/dev/null 2>&1; then
  log "创建用户 $DESKTOP_USER"
  useradd -m -s /bin/bash "$DESKTOP_USER"
fi

if [[ "$(passwd -S "$DESKTOP_USER" | awk '{print $2}')" == P ]]; then
  log "用户 $DESKTOP_USER 已有密码，远程桌面就用这个密码登录"
elif { : </dev/tty; } 2>/dev/null; then
  log "为用户 $DESKTOP_USER 设置远程桌面登录密码"
  while :; do
    read -rsp "输入密码（至少 8 位）: " pw1 </dev/tty; echo >&2
    read -rsp "再输入一次: " pw2 </dev/tty; echo >&2
    [[ "$pw1" == "$pw2" ]] || { warn "两次输入不一致，请重新输入"; continue; }
    (( ${#pw1} >= 8 ))     || { warn "密码至少 8 位，请重新输入"; continue; }
    break
  done
  printf '%s:%s\n' "$DESKTOP_USER" "$pw1" | chpasswd
  unset pw1 pw2
else
  warn "用户 $DESKTOP_USER 还没有密码，且当前不是交互式终端；装完后请执行：sudo passwd $DESKTOP_USER"
fi

# ---------- 安装软件包 ----------
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
APT=(apt-get -y -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
retry() {
  local i
  for i in 1 2 3; do
    "$@" && return 0
    if (( i < 3 )); then warn "命令失败（第 $i 次），15 秒后重试：$*"; sleep 15; fi
  done
  return 1
}

# 新买的云主机首次开机时，cloud-init 和自动更新可能正在占用 apt
if command -v cloud-init >/dev/null 2>&1 && [[ "$(cloud-init status 2>/dev/null || true)" == *"status: running"* ]]; then
  log "等待云主机首次启动的初始化（cloud-init）完成…"
  timeout 900 cloud-init status --wait >/dev/null 2>&1 || true
fi

log "安装 XFCE 桌面和 xrdp（需要几分钟）"
retry "${APT[@]}" update || die "apt-get update 失败，请检查网络或软件源"
# --no-upgrade：重复执行时不顺带升级已装的 xrdp（升级会重启 xrdp，见下面会话失联的说明）
retry "${APT[@]}" install --no-upgrade xfce4 xfce4-terminal xrdp xorgxrdp dbus-x11 fonts-noto-cjk \
  || die "安装软件包失败"

# ---------- 配置 xrdp ----------
log "配置 xrdp（模式：$MODE）"
INI=/etc/xrdp/xrdp.ini
SESMAN_INI=/etc/xrdp/sesman.ini
if [[ $MODE == tunnel ]]; then LISTEN="tcp://127.0.0.1:$PORT"; else LISTEN="$PORT"; fi
# 只改 [Globals] 段里的 port=（后面各会话段里也有 port=，不能动）
awk -v v="$LISTEN" '/^\[/ {g = ($0 == "[Globals]")} g && !d && /^port=/ {print "port=" v; d = 1; next} 1' \
  "$INI" > "$INI.new"
grep -qx "port=$LISTEN" "$INI.new" || die "修改 $INI 失败"
sed 's/^AllowRootLogin=.*/AllowRootLogin=false/' "$SESMAN_INI" > "$SESMAN_INI.new"

NEED_RESTART=0
cmp -s "$INI" "$INI.new"               || NEED_RESTART=1
cmp -s "$SESMAN_INI" "$SESMAN_INI.new" || NEED_RESTART=1
id -nG xrdp | grep -qw ssl-cert        || NEED_RESTART=1
systemctl is-active --quiet xrdp       || NEED_RESTART=1

# 重启 xrdp 会连带重启 xrdp-sesman，它会丢掉已有的桌面会话，之后再连会「连上就断」。
# 所以有会话在运行时，不改任何配置，先让用户注销。
if (( NEED_RESTART )) && pgrep -f 'Xorg :[0-9]+ .*xrdp/xorg[.]conf' >/dev/null; then
  rm -f "$INI.new" "$SESMAN_INI.new"
  die "检测到正在运行的远程桌面会话，现在重启 xrdp 会让它失联，之后再连会「连上就断」。配置未做任何改动。
请先在远程桌面里注销（Applications → Log Out），再通过 SSH 重新运行本脚本；
如果进不了桌面，可以通过 SSH 执行 sudo pkill -f 'xrdp/xorg[.]conf' 结束旧会话（未保存的内容会丢失）。"
fi

[[ -f $INI.orig ]] || cp -a "$INI" "$INI.orig"
cat "$INI.new" > "$INI" && rm -f "$INI.new"
cat "$SESMAN_INI.new" > "$SESMAN_INI" && rm -f "$SESMAN_INI.new"
usermod -aG ssl-cert xrdp   # xrdp 以 xrdp 用户运行，需要读取 TLS 证书私钥
runuser -u xrdp -- test -r /etc/xrdp/key.pem || warn "xrdp 无法读取 /etc/xrdp/key.pem，连接可能会失败"

# Ubuntu 24.04 每次用 apt 装软件或自动更新后，needrestart 会自动重启用到旧库的服务，
# 重启 xrdp 同样会让已有的桌面会话失联，所以让它跳过 xrdp（下次重启系统时自然会用上新库）
if [[ -d /etc/needrestart/conf.d ]]; then
  # shellcheck disable=SC2016  # 这是 Perl 代码，$ 不需要展开
  echo '$nrconf{override_rc}{qr(^xrdp)} = 0;' > /etc/needrestart/conf.d/xrdp.conf
fi

HOME_DIR="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
XS="$HOME_DIR/.xsession"
if [[ -e $XS && "$(cat "$XS")" != "exec xfce4-session" ]]; then
  runuser -u "$DESKTOP_USER" -- cp -a "$XS" "$XS.bak.$(date +%Y%m%d%H%M%S)"
fi
printf 'exec xfce4-session\n' | runuser -u "$DESKTOP_USER" -- tee "$XS" >/dev/null

if [[ $MODE == public ]] && command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == "Status: active"* ]]; then
  ufw allow "$PORT/tcp" >/dev/null
fi
if [[ $MODE == tunnel ]] && command -v sshd >/dev/null 2>&1; then
  # sshd -T 在 sshd 从未启动过（没有 /run/sshd）时会失败，此时跳过这项检查
  fwd="$({ sshd -T 2>/dev/null || true; } | awk '$1 == "allowtcpforwarding" {print $2}')"
  if [[ "$fwd" == no || "$fwd" == remote ]]; then
    warn "sshd 配置了 AllowTcpForwarding $fwd，SSH 隧道会连不上，请改成 yes 并重启 ssh"
  fi
fi

# ---------- 启动并自检 ----------
systemctl enable xrdp xrdp-sesman >/dev/null 2>&1 || true
if (( NEED_RESTART )); then
  log "启动 xrdp"
  systemctl restart xrdp-sesman xrdp
else
  log "xrdp 配置没有变化，无需重启（已有的桌面会话不受影响）"
fi

LISTENING=""
for _ in $(seq 1 15); do
  LISTENING="$(ss -Htln "sport = :$PORT" | awk '{print $4}' | paste -sd' ')"
  [[ -n "$LISTENING" ]] && break
  sleep 1
done
if ! systemctl is-active --quiet xrdp-sesman || ! systemctl is-active --quiet xrdp; then
  die "xrdp 启动失败，请查看：journalctl -u xrdp -u xrdp-sesman -n 50"
fi
if [[ $MODE == tunnel ]]; then
  [[ "$LISTENING" == "127.0.0.1:$PORT" ]] || die "xrdp 监听地址异常：${LISTENING:-无}"
else
  [[ -n "$LISTENING" && "$LISTENING" != "127.0.0.1:$PORT" ]] || die "xrdp 监听地址异常：${LISTENING:-无}"
fi

# ---------- 安装浏览器 ----------
# Ubuntu 24.04 的 Firefox 只有 snap 版。装不上不影响远程桌面，所以失败时只警告，不中止
BROWSER=""
if (( INSTALL_BROWSER )); then
  if snap list firefox >/dev/null 2>&1; then
    BROWSER=firefox
  elif (( $(df -Pk / | awk 'NR==2 {print $4}') < 2 * 1024 * 1024 )); then
    warn "根分区剩余空间不足 2 GB，跳过安装 Firefox"
  else
    log "安装 Firefox 浏览器（连同依赖约 1.5 GB，需要几分钟）"
    if retry "${APT[@]}" install --no-upgrade snapd \
      && timeout 900 snap wait system seed.loaded \
      && retry snap install firefox; then
      BROWSER=firefox
    else
      warn "Firefox 安装失败，远程桌面不受影响；可以稍后执行 sudo snap install firefox 重试"
    fi
  fi
fi
if [[ $BROWSER == firefox ]]; then
  # 设为 XFCE 的默认浏览器，免得第一次点「Web Browser」时先弹出选择框
  HELPERS="$HOME_DIR/.config/xfce4/helpers.rc"
  if ! grep -qs '^WebBrowser=' "$HELPERS"; then
    runuser -u "$DESKTOP_USER" -- mkdir -p "$HOME_DIR/.config/xfce4"
    echo 'WebBrowser=firefox' | runuser -u "$DESKTOP_USER" -- tee -a "$HELPERS" >/dev/null
  fi
fi

# ---------- 连接说明 ----------
SSH_USER="${SUDO_USER:-root}"
IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' \
  | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
  | head -n1 || true)"
IP="${IP:-<公网IP>}"

cat <<EOF

==================================================================
 安装完成：XFCE 桌面 + xrdp，监听 $LISTENING
 远程桌面登录用户：$DESKTOP_USER
EOF
if [[ $BROWSER == firefox ]]; then
  echo " 浏览器：Firefox（远程桌面左上角 Applications → Internet → Firefox）"
elif (( INSTALL_BROWSER )); then
  echo " 浏览器：Firefox 没装上，可以稍后执行 sudo snap install firefox"
fi
echo "=================================================================="
if [[ $MODE == tunnel ]]; then
  cat <<EOF
在 Mac 上连接：
 1. 打开「终端」执行下面的命令，并保持这个窗口不关：
      ssh -N -L 3389:127.0.0.1:$PORT $SSH_USER@$IP
 2. 打开 Windows App →「+」→「添加 PC」，PC 名称填：127.0.0.1
EOF
else
  cat <<EOF
在 Mac 上连接：
 1. 先在云厂商控制台的安全组放行 TCP $PORT（来源建议只填你自己的 IP）
 2. 打开 Windows App →「+」→「添加 PC」，PC 名称填：$IP
EOF
fi
cat <<EOF
 3. 用户名 $DESKTOP_USER，密码是这个用户的登录密码
 4. 显示设置里不要勾「针对 Retina 显示屏优化」；连接时出现证书警告点「继续」
EOF
