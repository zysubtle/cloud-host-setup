#!/usr/bin/env bash
#
# syncthing-vpc-sync.sh
# 两台同 VPC 的 Ubuntu 服务器（A、B）之间，通过私网用 Syncthing 双向同步一个文件夹。
# 只支持 Ubuntu 20.04 及以上版本。
#
# 用法（A、B 两台都要运行，需要 root）：
#   sudo bash syncthing-vpc-sync.sh            交互式安装与配置（两台同时运行，需要互相输入设备 ID）
#   sudo bash syncthing-vpc-sync.sh finalize   仅 B：等首次同步完成后切换为双向（setup 结束时也可直接进入）
#   sudo bash syncthing-vpc-sync.sh status     查看连接与同步状态
#   sudo bash syncthing-vpc-sync.sh uninstall  卸载：停止同步，删除 Syncthing 和本脚本的配置（同步目录里的文件保留）
#
# 可选环境变量：
#   ST_VERSION=v2.1.7          指定要下载的 Syncthing 版本（默认 GitHub 最新版；本机已安装则跳过安装）
#   ST_TARBALL=/path/x.tar.gz  使用本地安装包（服务器无法访问 GitHub 时用）。也可以直接把
#                              syncthing-linux-<架构>-<版本>.tar.gz（及 sha256sum.txt.asc）放在脚本同目录
#
# 工作方式：
#   - 只走私网：只监听本机私网 IP，关闭全局发现、本地发现、中继、NAT 穿透，对端地址写死为私网 IP。
#   - A 的文件夹类型为“发送与接收”；B 先设为“仅接收”，完整拉取 A 的内容；
#     确认同步完成后，B 切换为“发送与接收”，此后双方的修改互相同步。
#   - 可选“回收站式”版本控制：被删除或覆盖的文件保存在 <目录>/.stversions，按天数自动清理。
#
# 完整说明见同目录的 README.md。

if [ -z "${BASH_VERSION:-}" ]; then
  echo "请用 bash 运行：sudo bash $0" >&2
  exit 1
fi
set -Eeuo pipefail

STATE_FILE=/etc/syncthing-vpc-sync.conf
UNIT_FILE=/etc/systemd/system/syncthing@.service
ST_BIN=/usr/bin/syncthing
SYSCTL_FILE=/etc/sysctl.d/90-syncthing-inotify.conf
SYNC_PORT=22000
SELF=${BASH_SOURCE[0]:-syncthing-vpc-sync.sh}

ROLE='' PEER_ROLE='' LOCAL_IP='' PEER_IP='' PEER_ID='' MY_ID='' ST_VER=''
RUN_USER='' PREV_RUN_USER='' FOLDER_PATH='' FOLDER_ID='' VER_DAYS=''
OLD_FOLDER_ID='' OLD_FOLDER_PATH=''
GUI_USER='' GUI_PASS='' API='' TMPD=''

# ============================== 输出与交互 ==============================

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GRN=$'\e[32m' C_YEL=$'\e[33m' C_CYN=$'\e[36m' C_BLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_RED='' C_GRN='' C_YEL='' C_CYN='' C_BLD='' C_OFF=''
fi
info() { printf '%s==>%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
ok() { printf '%s[完成]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die() {
  printf '%s[错误]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  exit 1
}
cleanup() { if [[ -n $TMPD ]]; then rm -rf "$TMPD"; fi; }
trap cleanup EXIT
trap 'printf "%s[错误]%s 第 %s 行命令执行失败：%s\n" "$C_RED" "$C_OFF" "$LINENO" "$BASH_COMMAND" >&2' ERR
trap 'trap - ERR; printf "\n"; warn "已中断"; exit 130' INT

# ask 变量名 "提示" [默认值]
ask() {
  local __var=$1 __prompt=$2 __def=${3-} __ans=''
  if [[ -n $__def ]]; then __prompt+=" [${__def}]"; fi
  read -r -p "${__prompt}: " __ans </dev/tty || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}
# ask_secret 变量名 "提示"（不回显）
ask_secret() {
  local __var=$1 __ans=''
  read -r -s -p "$2: " __ans </dev/tty || true
  printf '\n' >/dev/tty
  printf -v "$__var" '%s' "$__ans"
}
# confirm "问题" Y|N（默认值）
confirm() {
  local def=${2:-N} ans='' hint='[y/N]'
  if [[ $def == Y ]]; then hint='[Y/n]'; fi
  read -r -p "$1 $hint " ans </dev/tty || true
  [[ ${ans:-$def} =~ ^[Yy] ]]
}

need_root() { [[ $EUID -eq 0 ]] || die "请用 root 运行：sudo bash $SELF ${1-}"; }
need_tty() { { true </dev/tty; } 2>/dev/null || die "请在交互式终端中运行本脚本"; }
# require_ubuntu [os-release 文件]
require_ubuntu() {
  local id
  id=$(. "${1:-/etc/os-release}" 2>/dev/null && printf '%s' "${ID:-}" || true)
  [[ $id == ubuntu ]] || die "本脚本只支持 Ubuntu（当前系统：${id:-未知}）"
}

# ============================== 小工具 ==============================

valid_ip() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}
is_private_ip() {
  [[ $1 =~ ^10\. || $1 =~ ^192\.168\. || $1 =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ||
    $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}
# 注意：$(...) 里“允许失败”的命令一律在括号内写 || true，
# 否则在部分 bash 版本中会触发 ERR trap，打印误报的错误信息。
local_has_ip() { [[ $(ip -4 -o addr show 2>/dev/null || true) == *" $1/"* ]]; }
detect_ip() {
  local ip
  ip=$(ip -4 route get 100.100.100.200 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)
  if [[ -z $ip ]]; then ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true); fi
  printf '%s' "$ip"
}
user_home() { getent passwd "$1" | cut -d: -f6 || true; }
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
# version_ge A B：A >= B 时为真
version_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p) == "$2" ]]; }
systemd_version() {
  local v
  v=$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2 + 0}' || true)
  printf '%s' "${v:-0}"
}
svc_state() { systemctl is-active "syncthing@$RUN_USER" 2>/dev/null || true; }
dir_is_empty() {
  [[ -z $(find "$1" -mindepth 1 -maxdepth 1 ! -name .stfolder ! -name .stversions -print -quit 2>/dev/null || true) ]]
}
# has_marker 目录 文件夹ID：目录里是否有这个文件夹的 .stfolder 标记。
# Syncthing（v1.28 起）创建 .stfolder 时，会在里面写一个记录文件夹 ID 的文件，
# 文件名为 syncthing-folder-<文件夹 ID 的 SHA-256 前 6 位>.txt
has_marker() {
  local h
  h=$(printf '%s' "$2" | sha256sum | cut -c1-6)
  grep -qxF "folderID: $2" "$1/.stfolder/syncthing-folder-$h.txt" 2>/dev/null
}

# ============================== 状态文件 ==============================

save_state() {
  (
    umask 077
    for v in ROLE RUN_USER LOCAL_IP PEER_IP PEER_ID FOLDER_ID FOLDER_PATH VER_DAYS; do
      printf '%s=%q\n' "$v" "${!v}"
    done >"$STATE_FILE"
  )
}
load_state() {
  [[ -f $STATE_FILE ]] || die "未找到 $STATE_FILE，请先运行：sudo bash $SELF"
  # shellcheck source=/dev/null
  source "$STATE_FILE"
  if [[ $ROLE == A ]]; then PEER_ROLE=B; else PEER_ROLE=A; fi
}

# ============================== 安装 ==============================

install_pkgs() {
  local -a o=(-y -qq -o DPkg::Lock::Timeout=300)
  local i
  # NEEDRESTART_SUSPEND：装完软件包后不运行 needrestart，避免它询问要重启哪些服务
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
  if apt-get install "${o[@]}" "$@" >/dev/null 2>&1; then return 0; fi
  # 软件包列表为空或过期时先更新。刚开机时系统的自动更新可能正占用 apt 的锁，最多等约 1 分钟
  for i in 1 2 3 4 5 6; do
    if apt-get update -qq >/dev/null 2>&1; then break; fi
    sleep 10
  done
  apt-get install "${o[@]}" "$@" >/dev/null
}

ensure_deps() {
  local miss='' c
  for c in curl jq tar; do
    if ! command -v "$c" >/dev/null 2>&1; then miss+=" $c"; fi
  done
  if [[ -n $miss ]]; then
    info "安装依赖：${miss# }"
    # shellcheck disable=SC2086
    install_pkgs $miss || die "安装依赖失败：${miss# }。请手动执行 apt-get update && apt-get install -y${miss} 后重试"
  fi
}

unit_exists() {
  [[ -f $UNIT_FILE || -f /lib/systemd/system/syncthing@.service ||
    -f /usr/lib/systemd/system/syncthing@.service ]]
}

# 兼容版服务文件，用于 systemd < 247 的系统（Ubuntu 20.04 及更早版本）。
# 官方安装包里的服务文件带有较新的沙箱选项，需要较新的 systemd，例如其中的
# 系统调用白名单 @system-service 在 systemd 239 之前不存在，会导致 Syncthing 无法正常运行。
write_basic_unit() {
  cat >"$UNIT_FILE" <<EOF
[Unit]
Description=Syncthing - Open Source Continuous File Synchronization for %I
Documentation=man:syncthing(1)
After=network.target

[Service]
User=%i
ExecStart=$(command -v syncthing) serve --no-browser --no-restart
Restart=on-failure
RestartSec=5
SuccessExitStatus=3 4
RestartForceExitStatus=3 4
ProtectSystem=full
PrivateTmp=true
SystemCallArchitectures=native
MemoryDenyWriteExecute=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

latest_version() {
  local v
  v=$(curl -fsSL -m 20 https://api.github.com/repos/syncthing/syncthing/releases/latest 2>/dev/null |
    jq -r '.tag_name // empty' 2>/dev/null || true)
  if [[ $v != v* ]]; then
    # API 被限流时，从 releases/latest 的跳转地址里取版本号
    v=$(curl -fsSIL -m 20 -o /dev/null -w '%{url_effective}' \
      https://github.com/syncthing/syncthing/releases/latest 2>/dev/null || true)
    v=${v##*/}
  fi
  if [[ $v == v* ]]; then printf '%s' "$v"; fi
}

offline_hint() {
  printf '%s' "本机可能无法访问 GitHub。可以在能上网的机器上，从 https://github.com/syncthing/syncthing/releases" \
    " 下载 syncthing-linux-$1-<版本>.tar.gz 和 sha256sum.txt.asc，放到本脚本所在目录后重新运行" \
    "（或用 ST_TARBALL=文件路径 指定）。两台服务器请使用同一版本。"
}

find_local_tarball() {
  local d f
  if [[ -n ${ST_TARBALL:-} ]]; then
    printf '%s' "$ST_TARBALL"
    return 0
  fi
  d=$(cd "$(dirname -- "$SELF")" 2>/dev/null && pwd || true)
  d=${d:-$PWD}
  # 有多个版本时取版本号最高的
  for f in "$d"/syncthing-linux-"$1"-v*.tar.gz; do
    if [[ -f $f ]]; then printf '%s\n' "$f"; fi
  done | sort -V | sed -n '$p'
}

verify_sha256() {
  local name want got
  name=$(basename -- "$1")
  want=$(awk -v f="$name" '$2 == f || $2 == "*" f {print $1}' "$2")
  got=$(sha256sum -- "$1" | awk '{print $1}')
  [[ -n $want && $want == "$got" ]] || die "SHA256 校验不通过：$1"
  ok "SHA256 校验通过"
}

install_syncthing() {
  if command -v syncthing >/dev/null 2>&1; then
    ok "已安装 Syncthing（$(command -v syncthing)），跳过安装"
  else
    local arch ver tb sums url bin unitsrc
    case $(uname -m) in
      x86_64 | amd64) arch=amd64 ;;
      aarch64 | arm64) arch=arm64 ;;
      *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
    if [[ -n ${ST_TARBALL:-} && ! -f ${ST_TARBALL:-} ]]; then die "ST_TARBALL 指定的文件不存在：$ST_TARBALL"; fi
    tb=$(find_local_tarball "$arch")
    if [[ -n $tb ]]; then
      info "使用本地安装包：$tb"
      sums=$(dirname -- "$tb")/sha256sum.txt.asc
      if [[ -f $sums ]]; then verify_sha256 "$tb" "$sums"; else warn "未找到 $sums，跳过 SHA256 校验"; fi
    else
      ver=${ST_VERSION:-}
      if [[ -n $ver && $ver != v* ]]; then ver=v$ver; fi
      if [[ -z $ver ]]; then ver=$(latest_version); fi
      [[ -n $ver ]] || die "获取 Syncthing 最新版本号失败。$(offline_hint "$arch")"
      url=https://github.com/syncthing/syncthing/releases/download/$ver
      tb=$TMPD/syncthing-linux-$arch-$ver.tar.gz
      info "下载 Syncthing $ver（$arch）"
      curl -fsSL -m 900 -o "$tb" "$url/${tb##*/}" || die "下载失败：$url/${tb##*/}。$(offline_hint "$arch")"
      curl -fsSL -m 60 -o "$TMPD/sha256sum.txt.asc" "$url/sha256sum.txt.asc" || die "下载校验文件失败"
      verify_sha256 "$tb" "$TMPD/sha256sum.txt.asc"
    fi
    mkdir -p "$TMPD/x"
    tar -xzf "$tb" -C "$TMPD/x" || die "解压失败：$tb"
    bin=$(find "$TMPD/x" -maxdepth 2 -type f -name syncthing | sed -n 1p)
    [[ -n $bin ]] || die "安装包中没有找到 syncthing 程序：$tb"
    install -m 0755 "$bin" "$ST_BIN"
    ok "已安装到 $ST_BIN"
    unitsrc=$(find "$TMPD/x" -type f -path '*/etc/linux-systemd/system/syncthing@.service' | sed -n 1p)
    # 官方服务文件带较新的沙箱选项，只在 systemd 247 及以上（Ubuntu 22.04 及以上）使用
    if ! unit_exists && [[ -n $unitsrc ]] && (($(systemd_version) >= 247)); then
      install -m 0644 "$unitsrc" "$UNIT_FILE"
    fi
  fi
  if ! unit_exists; then write_basic_unit; fi
  systemctl daemon-reload
}

tune_inotify() {
  local cur
  cur=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || true)
  if ((${cur:-0} < 524288)); then
    echo 'fs.inotify.max_user_watches=524288' >"$SYSCTL_FILE"
    sysctl -q -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
    ok "已调大 inotify 监控上限：$cur -> 524288"
  fi
}

# Ubuntu 默认不启用 ufw；启用了的话，只对对方 IP 放行同步端口
open_firewall() {
  command -v ufw >/dev/null 2>&1 || return 0
  # LC_ALL=C：中文环境下 ufw status 的输出会被翻译
  [[ $(LC_ALL=C ufw status 2>/dev/null || true) == *"Status: active"* ]] || return 0
  if ufw allow from "$PEER_IP" to any port "$SYNC_PORT" proto tcp >/dev/null 2>&1; then
    ok "ufw 已放行 $PEER_IP -> TCP $SYNC_PORT"
  else
    warn "ufw 放行失败，请手动执行：ufw allow from $PEER_IP to any port $SYNC_PORT proto tcp"
  fi
}

check_time_sync() {
  local s
  s=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  if [[ $s == no ]]; then
    warn "系统时间没有与 NTP 同步。双向同步按修改时间处理冲突，建议先开启时间同步：timedatectl set-ntp true"
  fi
}

# ============================== 目录准备 ==============================

prepare_folder() {
  local grp bad=''
  grp=$(id -gn "$RUN_USER")
  if [[ $ROLE == A ]]; then
    if dir_is_empty "$FOLDER_PATH"; then
      warn "A 上的 $FOLDER_PATH 是空目录，而 A 应该是已有数据的一方。"
      confirm "确认 A、B 角色没有选反，继续？" N || die "已取消"
    fi
  elif [[ ! -e $FOLDER_PATH ]]; then
    (umask 022 && mkdir -p "$FOLDER_PATH")
    chown "$RUN_USER:$grp" "$FOLDER_PATH"
    ok "已创建目录 $FOLDER_PATH"
  elif [[ ! -d $FOLDER_PATH ]]; then
    die "$FOLDER_PATH 已存在但不是目录"
  elif dir_is_empty "$FOLDER_PATH"; then
    chown "$RUN_USER:$grp" "$FOLDER_PATH"
  elif [[ $FOLDER_ID != "$OLD_FOLDER_ID" ]]; then
    # 文件夹 ID 与上次相同时，目录里是已经同步过来的数据（或者搬移过来的同一个文件夹），不用提醒
    warn "B 上的 $FOLDER_PATH 不是空目录。"
    warn "首次同步阶段，这些文件会被标记为“本地修改”；切换为双向前，脚本会让你选择还原（以 A 为准）还是同步给 A。"
    confirm "确定继续？" N || die "已取消"
  fi

  info "检查 $RUN_USER 对 $FOLDER_PATH 的读写权限……"
  if ! runuser -u "$RUN_USER" -- test -r "$FOLDER_PATH" -a -w "$FOLDER_PATH" -a -x "$FOLDER_PATH"; then
    bad=$FOLDER_PATH
  else
    bad=$(find "$FOLDER_PATH" ! -user "$RUN_USER" -print -quit 2>/dev/null || true)
  fi
  if [[ -n $bad ]]; then
    warn "用户 $RUN_USER 可能无法修改 $FOLDER_PATH 中的部分内容（例如：$bad 不属于 $RUN_USER）。"
    warn "双向同步要求运行用户能读写整个目录。"
    if confirm "是否执行 chown -R $RUN_USER:$grp $FOLDER_PATH ？" N; then
      chown -R "$RUN_USER:$grp" "$FOLDER_PATH"
      ok "已修改 $FOLDER_PATH 的属主"
    elif ! runuser -u "$RUN_USER" -- test -r "$FOLDER_PATH" -a -w "$FOLDER_PATH" -a -x "$FOLDER_PATH"; then
      die "用户 $RUN_USER 对 $FOLDER_PATH 没有读写权限。请修正权限，或改用拥有该目录的用户运行"
    else
      warn "未修改权限，继续。无法修改的文件会同步失败，可用 status 查看错误数"
    fi
  fi
}

# ============================== Syncthing API ==============================

# 与 Syncthing 自身的规则一致：旧位置 ~/.config/syncthing 存在配置时优先使用
find_config() {
  local h f
  h=$(user_home "$RUN_USER")
  for f in "$h/.config/syncthing/config.xml" "$h/.local/state/syncthing/config.xml"; do
    if [[ -f $f ]]; then
      printf '%s' "$f"
      return 0
    fi
  done
}

svc_check() {
  local s
  s=$(svc_state)
  if [[ $s == failed || $s == inactive ]]; then
    die "syncthing@$RUN_USER 服务没有在运行（$s）。查看日志：journalctl -u syncthing@$RUN_USER -n 50 --no-pager"
  fi
}

api_init() {
  local cfg='' gui addr key scheme=http i
  for ((i = 0; i < 60; i++)); do
    cfg=$(find_config)
    if [[ -n $cfg ]] && grep -q '<apikey>' "$cfg"; then break; fi
    cfg=''
    svc_check
    sleep 1
  done
  [[ -n $cfg ]] || die "60 秒内未找到 Syncthing 配置文件。查看日志：journalctl -u syncthing@$RUN_USER -n 50 --no-pager"
  key=$(sed -n '/<apikey>/{s:.*<apikey>\([^<]*\)</apikey>.*:\1:p;q;}' "$cfg")
  gui=$(sed -n '/<gui[ >]/,/<\/gui>/p' "$cfg")
  addr=$(sed -n '/<address>/{s:.*<address>\([^<]*\)</address>.*:\1:p;q;}' <<<"$gui")
  if grep -q 'tls="true"' <<<"$gui"; then scheme=https; fi
  addr=${addr:-127.0.0.1:8384}
  addr=${addr/0.0.0.0/127.0.0.1}
  addr=${addr/'[::]'/'[::1]'}
  API="$scheme://$addr"
  # API 密钥写入仅 root 可读的临时文件，避免出现在进程列表里
  (umask 077 && printf 'header = "X-API-Key: %s"\n' "$key" >"$TMPD/curl.cfg")
  for ((i = 0; i < 60; i++)); do
    if curl -fsk -m 3 -K "$TMPD/curl.cfg" "$API/rest/system/ping" >/dev/null 2>&1; then return 0; fi
    svc_check
    sleep 1
  done
  die "无法访问 Syncthing API（$API）。查看日志：journalctl -u syncthing@$RUN_USER -n 50 --no-pager"
}

# api METHOD PATH [JSON]（JSON 通过标准输入传给 curl，避免密码出现在进程列表里）
api() {
  local -a a=(-fsSk -m 60 -K "$TMPD/curl.cfg" -X "$1")
  if (($# >= 3)); then
    curl "${a[@]}" -H 'Content-Type: application/json' --data-binary @- "$API$2" <<<"$3"
  else
    curl "${a[@]}" "$API$2"
  fi
}

# ============================== 配置步骤 ==============================

collect_inputs() {
  local v def home days_txt gui_txt new_id change_txt

  echo "本机角色："
  echo "  1) A —— 数据来源（已有要同步的文件夹）"
  echo "  2) B —— 接收方（先完整接收 A 的数据，再切换为双向同步）"
  case $ROLE in A) def=1 ;; B) def=2 ;; *) def='' ;; esac
  while :; do
    ask v "请选择 1 或 2" "$def"
    case $v in
      1 | A | a) ROLE=A && break ;;
      2 | B | b) ROLE=B && break ;;
      *) warn "请输入 1 或 2" ;;
    esac
  done
  if [[ $ROLE == A ]]; then PEER_ROLE=B; else PEER_ROLE=A; fi

  while :; do
    ask LOCAL_IP "本机（$ROLE）私网 IP" "${LOCAL_IP:-$(detect_ip)}"
    if ! valid_ip "$LOCAL_IP"; then warn "IP 格式不正确" && continue; fi
    if ! local_has_ip "$LOCAL_IP"; then warn "本机网卡上没有 $LOCAL_IP，请填写本机的私网 IP" && continue; fi
    if ! is_private_ip "$LOCAL_IP"; then warn "$LOCAL_IP 看起来不是私网地址"; fi
    break
  done

  while :; do
    ask PEER_IP "对端（$PEER_ROLE）私网 IP" "$PEER_IP"
    if ! valid_ip "$PEER_IP"; then warn "IP 格式不正确" && continue; fi
    if [[ $PEER_IP == "$LOCAL_IP" ]]; then warn "对端 IP 不能与本机相同" && continue; fi
    if ! is_private_ip "$PEER_IP"; then warn "$PEER_IP 看起来不是私网地址"; fi
    break
  done

  while :; do
    ask RUN_USER "运行 Syncthing 的系统用户（需要对同步目录有读写权限）" "${RUN_USER:-${SUDO_USER:-root}}"
    if ! id -u "$RUN_USER" >/dev/null 2>&1; then warn "用户 $RUN_USER 不存在" && continue; fi
    home=$(user_home "$RUN_USER")
    if [[ -z $home || ! -d $home ]] || ! runuser -u "$RUN_USER" -- test -w "$home"; then
      warn "用户 $RUN_USER 的家目录（${home:-无}）不存在或不可写，Syncthing 需要在其中保存配置，请换一个用户"
      continue
    fi
    break
  done
  if [[ $RUN_USER == root ]]; then
    warn "将以 root 运行 Syncthing。可以使用，但更安全的做法是用拥有同步目录的普通用户运行。"
  fi

  while :; do
    ask FOLDER_PATH "本机要同步的目录（绝对路径；A、B 上的路径可以不同）" "$FOLDER_PATH"
    if [[ $FOLDER_PATH != /* ]]; then warn "请输入以 / 开头的绝对路径" && continue; fi
    FOLDER_PATH=$(realpath -m -- "$FOLDER_PATH")
    case $FOLDER_PATH in
      / | /usr | /usr/* | /etc | /etc/* | /boot | /boot/* | /efi | /efi/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/*)
        warn "不能使用系统目录 $FOLDER_PATH" && continue
        ;;
    esac
    if [[ $home/ == "$FOLDER_PATH"/* ]]; then
      warn "同步目录不能是 $home 或它的上级目录（Syncthing 的配置和数据库保存在 $home 下）" && continue
    fi
    if [[ $ROLE == A && ! -d $FOLDER_PATH ]]; then
      warn "目录 $FOLDER_PATH 不存在（A 上应填写已有数据的目录）" && continue
    fi
    # 搬移目录时，原目录里不能还有这个文件夹的 .stfolder（说明是复制了一份）：脚本改好路径之前，
    # Syncthing 会继续使用原目录，期间的变化不在新目录里，改过去后会被当成本机的修改或删除，同步给对方
    if [[ -n $OLD_FOLDER_ID && $FOLDER_PATH != "$OLD_FOLDER_PATH" ]] && has_marker "$FOLDER_PATH" "$OLD_FOLDER_ID" &&
      has_marker "$OLD_FOLDER_PATH" "$OLD_FOLDER_ID"; then
      warn "原目录 $OLD_FOLDER_PATH 还在，看起来是复制了一份。请先停止 Syncthing，用 mv 搬移目录（或者把原目录改名），然后重新输入"
      continue
    fi
    break
  done

  # 目录与上次不同时：新目录里有原文件夹的 .stfolder，说明是把原目录整个搬了过来，文件夹 ID 不变；
  # 否则就是改为同步另一个目录，必须换一个新的文件夹 ID。原因：Syncthing 的数据库按文件夹 ID 记录了
  # 原目录里的文件，同一个 ID 直接改到另一个目录，会因为缺少 .stfolder 报错停止；
  # 如果再手动补上 .stfolder，原目录的文件会被当成已删除，并同步给对方。
  def=${FOLDER_ID:-share} new_id=''
  if [[ -n $OLD_FOLDER_ID && $FOLDER_PATH != "$OLD_FOLDER_PATH" ]] && ! has_marker "$FOLDER_PATH" "$OLD_FOLDER_ID"; then
    def='' new_id=1
    warn "同步目录改了（上次是 $OLD_FOLDER_PATH），需要换一个新的文件夹 ID，A、B 填写相同的新 ID。"
    warn "如果是把原目录整个搬到了这里，请连同原目录里的 .stfolder 一起搬过来，这样不用换 ID。"
  fi
  while :; do
    ask FOLDER_ID "文件夹 ID（A、B 必须填写相同的值）" "$def"
    if [[ ! $FOLDER_ID =~ ^[A-Za-z0-9._-]+$ ]]; then
      warn "只能包含字母、数字、点、下划线和短横线" && continue
    fi
    if [[ -n $new_id && $FOLDER_ID == "$OLD_FOLDER_ID" ]]; then
      warn "目录改了，不能再用 $OLD_FOLDER_ID，请换一个新的文件夹 ID" && continue
    fi
    break
  done

  while :; do
    ask VER_DAYS "被删除/覆盖的旧文件在 .stversions 中保留几天（0 表示不启用版本控制）" "${VER_DAYS:-30}"
    if [[ $VER_DAYS =~ ^[0-9]{1,5}$ ]]; then break; fi
    warn "请输入 0~99999 的整数"
  done
  VER_DAYS=$((10#$VER_DAYS))

  while :; do
    ask_secret GUI_PASS "设置 Web 管理界面密码（直接回车则不设置/不修改）"
    if [[ -z $GUI_PASS ]]; then break; fi
    ask_secret v "再输入一次密码"
    if [[ $v == "$GUI_PASS" ]]; then break; fi
    warn "两次输入不一致，请重新输入"
  done
  if [[ -n $GUI_PASS ]]; then ask GUI_USER "Web 管理界面用户名" "admin"; fi

  if ((VER_DAYS > 0)); then days_txt="保留 $VER_DAYS 天"; else days_txt="不启用"; fi
  if [[ -n $GUI_PASS ]]; then gui_txt="用户 $GUI_USER（已设置密码）"; else gui_txt="不修改"; fi
  change_txt=''
  if [[ -n $OLD_FOLDER_ID && $FOLDER_ID != "$OLD_FOLDER_ID" ]]; then
    change_txt="  停止同步          : 上次的文件夹 $OLD_FOLDER_ID（$OLD_FOLDER_PATH），只移除配置，不删除文件"
  elif [[ -n $OLD_FOLDER_ID && $FOLDER_PATH != "$OLD_FOLDER_PATH" ]]; then
    change_txt="  目录搬移          : $OLD_FOLDER_PATH -> $FOLDER_PATH"
  fi
  cat <<EOF

------------------------ 请确认 ------------------------
  本机角色          : $ROLE
  本机私网 IP       : $LOCAL_IP
  对端（$PEER_ROLE）私网 IP : $PEER_IP
  运行用户          : $RUN_USER
  同步目录          : $FOLDER_PATH
  文件夹 ID         : $FOLDER_ID
EOF
  if [[ -n $change_txt ]]; then printf '%s\n' "$change_txt"; fi
  cat <<EOF
  旧版本文件        : $days_txt
  Web 管理界面账号  : $gui_txt
--------------------------------------------------------
EOF
  confirm "开始安装并配置？" Y || die "已取消"
}

# 全局选项：只监听私网 IP，关闭一切公网发现/中继/NAT 穿透，关闭自动升级与数据上报。
# 首次启动后立即执行，尽量缩短使用默认配置（会连接公网发现服务器和中继）的时间。
configure_options() {
  local la="tcp://$LOCAL_IP:$SYNC_PORT" body
  body=$(jq -n --arg la "$la" '{
    listenAddresses: [$la],
    globalAnnounceEnabled: false, localAnnounceEnabled: false,
    relaysEnabled: false, natEnabled: false,
    autoUpgradeIntervalH: 0, urAccepted: -1, crashReportingEnabled: false,
    startBrowser: false }')
  api PATCH /rest/config/options "$body" >/dev/null || die "写入全局选项失败"
  api GET /rest/config/options | jq -e --arg la "$la" '
    .listenAddresses == [$la] and (.globalAnnounceEnabled | not) and (.localAnnounceEnabled | not)
    and (.relaysEnabled | not) and (.natEnabled | not)' >/dev/null || die "全局选项校验失败"
  ok "已改为仅通过私网 $la 通信（已关闭全局发现、本地发现、中继、NAT 穿透）"
}

exchange_ids() {
  local id canon
  printf '\n%s' "$C_BLD"
  cat <<EOF
================================================================================
  本机（$ROLE，$LOCAL_IP）的设备 ID：

    $MY_ID

  1. 把上面这个 ID 输入到 $PEER_ROLE 上运行的脚本中；
  2. 把 $PEER_ROLE 上的脚本显示的设备 ID 输入到下面。
================================================================================
EOF
  printf '%s\n' "$C_OFF"
  while :; do
    ask id "$PEER_ROLE（$PEER_IP）的设备 ID" "$PEER_ID"
    id=${id//[[:space:]]/}
    id=${id^^}
    if [[ ! ${id//-/} =~ ^[A-Z2-7]{56}$ ]]; then
      warn "设备 ID 格式不正确（应为 8 组、每组 7 个字符，用 - 连接）" && continue
    fi
    # 由 Syncthing 校验（含校验位）并转换为标准格式
    canon=$(api GET "/rest/svc/deviceid?id=$id" | jq -r '.id // empty' || true)
    if [[ -z $canon ]]; then warn "设备 ID 校验未通过，可能复制不完整或有错字，请重新输入" && continue; fi
    if [[ $canon == "$MY_ID" ]]; then warn "这是本机自己的 ID，请输入 $PEER_ROLE 的 ID" && continue; fi
    PEER_ID=$canon
    break
  done
}

# 以 Syncthing 的实际配置为准再查一次：同一个文件夹 ID 不能直接改到另一个目录（原因见 collect_inputs）。
# 状态文件丢失、或者与实际配置不一致时，collect_inputs 里的检查会漏掉。
check_folder_path() {
  local cur
  cur=$(api GET "/rest/config/folders/$FOLDER_ID" 2>/dev/null | jq -r '.path // empty' || true)
  cur=${cur%/}
  if [[ -z $cur || $cur == "$FOLDER_PATH" ]]; then return 0; fi
  # 搬移：新目录里有这个文件夹的 .stfolder，原目录里已经没有了
  if has_marker "$FOLDER_PATH" "$FOLDER_ID" && ! has_marker "$cur" "$FOLDER_ID"; then return 0; fi
  die "文件夹 $FOLDER_ID 现在同步的是 $cur，不能直接改成 $FOLDER_PATH。改为同步另一个目录：请重新运行，换一个新的文件夹 ID；搬移目录：请先停止 Syncthing，再用 mv 把原目录（连同 .stfolder）整个搬过去。详见 README 的“更改同步目录”"
}

configure_peer() {
  local ftype=sendreceive cur body
  info "添加对端设备与共享文件夹"

  # 对端设备：地址写死为私网 IP（必须先于文件夹添加，否则文件夹里的该设备会被丢弃）
  body=$(jq -n --arg id "$PEER_ID" --arg name "$PEER_ROLE-$PEER_IP" --arg addr "tcp://$PEER_IP:$SYNC_PORT" \
    '{deviceID: $id, name: $name, addresses: [$addr], autoAcceptFolders: false}')
  api POST /rest/config/devices "$body" >/dev/null || die "添加对端设备失败"

  # 换了文件夹 ID：先移除上次的文件夹。Syncthing 只删除它的配置、数据库记录和目录里的 .stfolder，
  # 不删除目录里的文件。先移除再添加：新旧文件夹用同一个目录时，新文件夹才能创建自己的 .stfolder
  if [[ -n $OLD_FOLDER_ID && $OLD_FOLDER_ID != "$FOLDER_ID" ]] &&
    api GET "/rest/config/folders/$OLD_FOLDER_ID" >/dev/null 2>&1; then
    api DELETE "/rest/config/folders/$OLD_FOLDER_ID" >/dev/null || die "移除上次的文件夹 $OLD_FOLDER_ID 失败"
    ok "已停止同步上次的文件夹 $OLD_FOLDER_ID（$OLD_FOLDER_PATH 中的文件保留不动）"
  fi

  # 文件夹：A 为发送与接收；B 首次为仅接收（若之前已切换为双向则保持）
  if [[ $ROLE == B ]]; then
    cur=$(api GET "/rest/config/folders/$FOLDER_ID" 2>/dev/null | jq -r '.type // empty' || true)
    if [[ $cur == sendreceive ]]; then
      info "B 上该文件夹之前已切换为双向，保持不变"
    else
      ftype=receiveonly
    fi
  fi
  body=$(jq -n --arg id "$FOLDER_ID" --arg path "$FOLDER_PATH" --arg type "$ftype" \
    --arg me "$MY_ID" --arg peer "$PEER_ID" --argjson days "$VER_DAYS" '
    {id: $id, label: $id, path: $path, type: $type,
     devices: [{deviceID: $me}, {deviceID: $peer}],
     fsWatcherEnabled: true}
    + (if $days > 0 then {versioning: {type: "trashcan", params: {cleanoutDays: ($days | tostring)}}} else {} end)')
  api POST /rest/config/folders "$body" >/dev/null || die "添加文件夹失败"

  api GET "/rest/config/folders/$FOLDER_ID" | jq -e --arg p "$FOLDER_PATH" --arg t "$ftype" --arg peer "$PEER_ID" '
    .path == $p and .type == $t and any(.devices[]; .deviceID == $peer)' >/dev/null || die "文件夹配置校验失败"
  ok "已添加对端 tcp://$PEER_IP:$SYNC_PORT，文件夹 $FOLDER_ID（类型 $ftype）"

  # Web 管理界面账号放在最后：修改它会让 Syncthing 的 API 监听重启，紧随其后的请求可能失败
  if [[ -n $GUI_PASS ]]; then
    body=$(jq -n --arg u "$GUI_USER" --arg p "$GUI_PASS" '{user: $u, password: $p}')
    if ! api PATCH /rest/config/gui "$body" >/dev/null; then
      warn "设置 Web 管理界面账号失败，可以之后在 Web 界面中设置"
    fi
  fi
}

check_listen() {
  local i
  for ((i = 0; i < 15; i++)); do
    if ss -ltn 2>/dev/null | awk -v a="$LOCAL_IP:$SYNC_PORT" '$4 == a {f = 1} END {exit !f}'; then
      ok "Syncthing 仅监听私网地址 $LOCAL_IP:$SYNC_PORT"
      return 0
    fi
    sleep 1
  done
  warn "未检测到 $LOCAL_IP:$SYNC_PORT 处于监听状态，请查看日志：journalctl -u syncthing@$RUN_USER -n 50 --no-pager"
}

check_peer_version() {
  if [[ -n $1 && -n $ST_VER && $1 != "$ST_VER" ]]; then
    warn "两端 Syncthing 版本不同（本机 $ST_VER，$PEER_ROLE 为 $1），建议保持一致"
  fi
}

wait_peer() {
  local i c='{}' rs='' pend
  info "等待与 $PEER_ROLE（$PEER_IP）建立连接（对端脚本也需要完成配置）……"
  for ((i = 0; i < 45; i++)); do
    c=$(api GET /rest/system/connections 2>/dev/null | jq -c --arg p "$PEER_ID" '.connections[$p] // {}' || true)
    if [[ -z $c ]]; then c='{}'; fi
    if [[ $(jq -r '.connected // false' <<<"$c") == true ]]; then
      rs=$(api GET "/rest/db/completion?folder=$FOLDER_ID&device=$PEER_ID" 2>/dev/null |
        jq -r '.remoteState // "n/a"' || true)
      if [[ $rs == valid || $rs == n/a ]]; then
        ok "已连接到 $PEER_ROLE（$(jq -r '.address // ""' <<<"$c")），双方都已共享文件夹 $FOLDER_ID"
        check_peer_version "$(jq -r '.clientVersion // ""' <<<"$c")"
        return 0
      fi
    fi
    sleep 2
  done
  if [[ $(jq -r '.connected // false' <<<"$c") == true ]]; then
    warn "已连接到 $PEER_ROLE，但对方还没有共享文件夹 $FOLDER_ID（状态：$rs）"
    pend=$(api GET "/rest/cluster/pending/folders?device=$PEER_ID" 2>/dev/null |
      jq -r 'keys | join(", ")' 2>/dev/null || true)
    if [[ -n $OLD_FOLDER_ID && $OLD_FOLDER_ID != "$FOLDER_ID" && $pend == "$OLD_FOLDER_ID" ]]; then
      warn "$PEER_ROLE 上还是上次的文件夹 $OLD_FOLDER_ID：请在 $PEER_ROLE 上也重新运行脚本，文件夹 ID 填 $FOLDER_ID"
    elif [[ -n $pend ]]; then
      warn "对方共享过来的文件夹 ID 是：$pend —— 两边的文件夹 ID 必须一致，请在其中一台重新运行脚本修正"
    else
      warn "请确认 $PEER_ROLE 上的脚本已经执行完配置步骤"
    fi
  elif timeout 3 bash -c "exec 3<>/dev/tcp/$PEER_IP/$SYNC_PORT" 2>/dev/null; then
    warn "90 秒内未能连接到 $PEER_ROLE。$PEER_IP:$SYNC_PORT 端口可以连通，但没有建立 Syncthing 连接："
    warn "  请确认两边输入的设备 ID 正确，并且 $PEER_ROLE 上的脚本已经执行完配置步骤。"
  else
    warn "90 秒内未能连接到 $PEER_ROLE，且无法连通 $PEER_IP:$SYNC_PORT，请检查："
    warn "  1. $PEER_ROLE 上的脚本是否已执行完；"
    warn "  2. 阿里云安全组入方向是否放行了 TCP $SYNC_PORT（授权对象为对端私网 IP 或安全组）；"
    warn "  3. 系统防火墙（ufw 或 iptables/nftables 规则）是否放行。"
  fi
  warn "Syncthing 会在后台自动重连，排查后运行 sudo bash $SELF status 查看状态"
  return 1
}

# ============================== B：首次同步后切换为双向 ==============================

# 判定“首次同步完成”：已连接 A、A 已共享该文件夹、本地空闲且无待同步项和错误，
# 并且 A 的索引序号在连续 3 次检查（约 30 秒）中没有变化。
wait_initial_sync() {
  local stable=0 last='' ns=0 bad=0 hint_ns='' hint_err='' conn rs st state need errs gb ib seq
  while :; do
    conn=$(api GET /rest/system/connections 2>/dev/null |
      jq -r --arg p "$PEER_ID" '.connections[$p].connected // false' || true)
    rs=$(api GET "/rest/db/completion?folder=$FOLDER_ID&device=$PEER_ID" 2>/dev/null |
      jq -r '.remoteState // "n/a"' || true)
    st=$(api GET "/rest/db/status?folder=$FOLDER_ID" 2>/dev/null || true)
    if [[ -z $st ]]; then
      sleep 10
      continue
    fi
    state='' need='' errs='' gb='' ib='' seq=''
    read -r state need errs gb ib seq < <(jq -r --arg p "$PEER_ID" '
      [(.state // "unknown"), (.needTotalItems // -1), (.errors // .pullErrors // 0),
       (.globalBytes // 0), (.inSyncBytes // 0), (.remoteSequence[$p] // -1)]
      | map(tostring) | join(" ")' <<<"$st" 2>/dev/null || true) || true
    printf '\r\e[K连接A:%s  A端共享:%s  状态:%s  已同步:%s/%s  待同步:%s项  错误:%s' \
      "$conn" "$rs" "$state" "$(human "$ib")" "$(human "$gb")" "$need" "$errs"

    if [[ $rs == notSharing ]]; then ns=$((ns + 1)); else ns=0; fi
    if [[ $state == error || $errs != 0 ]]; then bad=$((bad + 1)); else bad=0; fi
    if [[ -z $hint_ns ]] && ((ns >= 6)); then
      printf '\n'
      warn "A 没有与 B 共享文件夹 $FOLDER_ID：请确认 A 的脚本已执行完，且两边填写的文件夹 ID 相同"
      hint_ns=1
    fi
    if [[ -z $hint_err ]] && ((bad >= 6)); then
      printf '\n'
      warn "有文件同步出错，可在 Web 管理界面查看原因（或 journalctl -u syncthing@$RUN_USER）"
      hint_err=1
    fi

    if [[ $conn == true && ($rs == valid || $rs == n/a) && $state == idle && $need == 0 && $errs == 0 ]]; then
      if [[ $seq == "$last" ]]; then stable=$((stable + 1)); else stable=1; fi
      last=$seq
      if ((stable >= 3)); then
        printf '\n'
        return 0
      fi
    else
      stable=0
      last=''
    fi
    sleep 10
  done
}

finalize_folder() {
  local t ro choice
  t=$(api GET "/rest/config/folders/$FOLDER_ID" 2>/dev/null | jq -r .type || true)
  [[ -n $t ]] || die "本机找不到文件夹 $FOLDER_ID，请先运行：sudo bash $SELF"
  if [[ $t == sendreceive ]]; then
    ok "文件夹 $FOLDER_ID 已经是双向同步"
    return 0
  fi
  info "等待首次同步完成（每 10 秒刷新；可随时 Ctrl+C 退出，之后运行 sudo bash $SELF finalize 继续）"
  info "数据量大时耗时较长，建议在 tmux/screen 中运行；在此期间请不要在 B 上修改 $FOLDER_PATH"
  while :; do
    wait_initial_sync
    ro=$(api GET "/rest/db/status?folder=$FOLDER_ID" 2>/dev/null | jq -r '.receiveOnlyTotalItems // 0' || true)
    if [[ -z $ro ]]; then continue; fi # 查询失败：重新等待后再查
    if ((ro == 0)); then break; fi
    warn "B 上有 $ro 项本地修改（B 独有的文件，或在 B 上改动过的文件），切换前需要处理："
    echo "  1) 还原：丢弃这些修改，让 B 与 A 完全一致（会删除/覆盖 B 上的这些文件）"
    echo "  2) 保留：切换为双向后，把这些修改同步给 A（与 A 上同名文件冲突时会生成 .sync-conflict 副本）"
    echo "  3) 暂不切换，退出"
    while :; do
      ask choice "请选择 1/2/3"
      case $choice in 1 | 2 | 3) break ;; esac
    done
    case $choice in
      1)
        api POST "/rest/db/revert?folder=$FOLDER_ID" >/dev/null || die "还原失败"
        info "已开始还原，重新等待同步完成"
        sleep 5
        ;;
      2) break ;;
      3)
        info "未切换。处理好后运行 sudo bash $SELF finalize"
        exit 0
        ;;
    esac
  done
  api PATCH "/rest/config/folders/$FOLDER_ID" '{"type":"sendreceive"}' >/dev/null || die "切换为双向失败"
  t=$(api GET "/rest/config/folders/$FOLDER_ID" | jq -r .type || true)
  [[ $t == sendreceive ]] || die "切换失败，当前类型为 ${t:-未知}"
  ok "B 已切换为“发送与接收”，A 与 B 现在是双向同步（A 之后的变化也会继续同步过来）"
}

# ============================== 子命令 ==============================

cmd_setup() {
  local port qpath
  need_root
  require_ubuntu
  need_tty
  command -v systemctl >/dev/null 2>&1 || die "本脚本需要 systemd"
  if [[ -f $STATE_FILE ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    PREV_RUN_USER=$RUN_USER OLD_FOLDER_ID=$FOLDER_ID OLD_FOLDER_PATH=$FOLDER_PATH
    info "检测到上次的配置（$STATE_FILE），将作为默认值"
  fi
  cat <<EOF
${C_BLD}=========== Syncthing 私网双向同步配置 ===========${C_OFF}
请在 A、B 两台服务器上【同时】运行本脚本（开两个终端窗口）。
中途每台都会显示自己的设备 ID，并要求输入对方的设备 ID。

EOF
  collect_inputs
  ensure_deps
  check_time_sync
  if [[ -n $PREV_RUN_USER && $PREV_RUN_USER != "$RUN_USER" ]] &&
    systemctl is-active --quiet "syncthing@$PREV_RUN_USER" 2>/dev/null; then
    warn "上次配置的 syncthing@$PREV_RUN_USER 仍在运行，会与本次的 syncthing@$RUN_USER 冲突（同一目录、同一端口）"
    if confirm "停止并禁用 syncthing@$PREV_RUN_USER？" Y; then
      systemctl stop "syncthing@$PREV_RUN_USER"
      systemctl disable -q "syncthing@$PREV_RUN_USER"
    fi
  fi
  prepare_folder
  install_syncthing
  tune_inotify
  open_firewall

  info "启动服务 syncthing@$RUN_USER"
  systemctl enable -q "syncthing@$RUN_USER"
  systemctl restart "syncthing@$RUN_USER" ||
    die "启动失败，查看日志：journalctl -u syncthing@$RUN_USER -n 50 --no-pager"
  api_init
  ST_VER=$(api GET /rest/system/version | jq -r .version)
  version_ge "${ST_VER#v}" 1.12.0 || die "Syncthing $ST_VER 版本过旧（需要 v1.12 以上），请卸载旧版本后重新运行本脚本"
  MY_ID=$(api GET /rest/system/status | jq -r .myID)
  ok "Syncthing $ST_VER 已运行"
  configure_options
  check_folder_path

  exchange_ids
  configure_peer
  save_state

  info "重启服务，使监听地址生效"
  systemctl restart "syncthing@$RUN_USER" ||
    die "重启失败，查看日志：journalctl -u syncthing@$RUN_USER -n 50 --no-pager"
  api_init
  if [[ -n $GUI_PASS && $(api GET /rest/config/gui | jq -r '.user // ""' || true) != "$GUI_USER" ]]; then
    warn "Web 管理界面账号似乎没有设置成功，可以之后在 Web 界面中设置"
  fi
  check_listen
  wait_peer || true

  port=${API##*:}
  printf -v qpath '%q' "$FOLDER_PATH"
  echo
  ok "$ROLE 配置完成"
  cat <<EOF
  - 查看状态：      sudo bash $SELF status
  - Web 管理界面：  在本地电脑执行 ssh -L $port:127.0.0.1:$port <用户>@<本机 IP>，然后打开 http://127.0.0.1:$port
  - 阿里云安全组：  入方向需放行 TCP $SYNC_PORT，授权对象 $PEER_IP/32（同一普通安全组内默认互通）
  - 冲突文件：      find $qpath -name '*.sync-conflict-*'
EOF

  if [[ $ROLE == A ]]; then
    echo "  - B 会先完整接收 A 的数据，然后切换为双向；在 B 完成切换前，请不要在 B 上修改文件。"
    return 0
  fi
  echo
  if [[ $(api GET "/rest/config/folders/$FOLDER_ID" | jq -r .type || true) == sendreceive ]]; then
    ok "B 已经是双向同步"
  elif confirm "现在等待首次同步完成，并自动把 B 切换为双向？" Y; then
    finalize_folder
  else
    info "稍后运行：sudo bash $SELF finalize"
  fi
}

cmd_finalize() {
  need_root finalize
  need_tty
  load_state
  [[ $ROLE == B ]] || die "finalize 只需要在 B 上运行"
  ensure_deps
  api_init
  finalize_folder
}

cmd_status() {
  need_root status
  load_state
  ensure_deps
  api_init
  local st conn pct n ftype listen
  conn=$(api GET /rest/system/connections | jq -r --arg p "$PEER_ID" \
    '.connections[$p] | if .connected then "已连接（\(.address)，\(.clientVersion)）" else "未连接" end')
  ftype=$(api GET "/rest/config/folders/$FOLDER_ID" | jq -r .type)
  st=$(api GET "/rest/db/status?folder=$FOLDER_ID")
  pct=$(api GET "/rest/db/completion?folder=$FOLDER_ID&device=$PEER_ID" | jq -r '.completion | floor')
  listen=$(ss -ltn 2>/dev/null | awk -v p=":$SYNC_PORT" '$4 ~ p"$" {print $4}' | paste -sd' ' - || true)
  n=$({ find "$FOLDER_PATH" -path "$FOLDER_PATH/.stversions" -prune -o -name '*.sync-conflict-*' -print 2>/dev/null ||
    true; } | wc -l)
  cat <<EOF
角色          : $ROLE（$LOCAL_IP）    服务 syncthing@$RUN_USER：$(svc_state)
Syncthing     : $(api GET /rest/system/version | jq -r .version)
本机设备 ID   : $(api GET /rest/system/status | jq -r .myID)
监听地址      : ${listen:-无}
对端 $PEER_ROLE（$PEER_IP）: $conn
文件夹        : $FOLDER_ID -> $FOLDER_PATH
  类型        : $ftype
  状态        : $(jq -r .state <<<"$st")
  本地文件数  : $(jq -r .localFiles <<<"$st")（$(human "$(jq -r .localBytes <<<"$st")")）
  本机待同步  : $(jq -r .needTotalItems <<<"$st") 项，错误 $(jq -r '.errors // .pullErrors // 0' <<<"$st") 项
  对端完成度  : ${pct}%
  冲突文件数  : $n
EOF
}

# 本机所有 syncthing@ 服务实例对应的用户（已加载的，或设置了开机自启的）
st_instances() {
  local f
  {
    systemctl list-units --all --plain --no-legend 'syncthing@*.service' 2>/dev/null | awk '{print $1}' || true
    for f in "${UNIT_FILE%/*}"/*.wants/syncthing@*.service; do
      if [[ -L $f || -e $f ]]; then printf '%s\n' "${f##*/}"; fi
    done
  } | sed -n 's/^syncthing@\(..*\)\.service$/\1/p' | sort -u
}

# 卸载前查看同步进度，有没同步完的内容时输出提示，查不到就什么都不输出。
# 函数体在子 shell 里运行，api_init 失败时只会退出子 shell
sync_progress() (
  local need='' pct=''
  [[ -n $FOLDER_ID && -n $PEER_ID && $(svc_state) == active ]] || exit 0
  command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 || exit 0
  api_init >/dev/null 2>&1 || exit 0
  need=$(api GET "/rest/db/status?folder=$FOLDER_ID" | jq -r '.needTotalItems // empty' || true)
  pct=$(api GET "/rest/db/completion?folder=$FOLDER_ID&device=$PEER_ID" | jq -r '.completion // empty | floor' || true)
  if [[ $need =~ ^[0-9]+$ ]] && ((need > 0)); then
    echo "本机还有 $need 项没有从 $PEER_ROLE 同步过来，卸载后就不会再同步了"
  fi
  if [[ $pct =~ ^[0-9]+$ ]] && ((pct < 100)); then
    echo "$PEER_ROLE 的同步进度是 ${pct}%，本机卸载后，还没传给 $PEER_ROLE 的内容就传不过去了"
  fi
)

# fw_has_rule 规则：firewalld 的运行时或永久配置里有这条 rich rule
fw_has_rule() {
  firewall-cmd -q --query-rich-rule="$1" 2>/dev/null || firewall-cmd -q --permanent --query-rich-rule="$1" 2>/dev/null
}

cmd_uninstall() {
  need_root uninstall
  require_ubuntu
  need_tty
  local -a users=() units=() cfgs=() files=() own=() fx=() keep=()
  local u h d f pkg='' keep_bin='' added='' rule='' frule='' prog='' counts='' ntmp=0 nconf=0 vsize='' del_ver='' out qpath
  if [[ -f $STATE_FILE ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
    if [[ $ROLE == A ]]; then PEER_ROLE=B; else PEER_ROLE=A; fi
  fi

  # ---- 找出要卸载的内容 ----
  mapfile -t users < <({
    if [[ -n $RUN_USER ]]; then printf '%s\n' "$RUN_USER"; fi
    st_instances
  } | awk 'NF && !seen[$0]++')
  for u in "${users[@]}"; do
    units+=("syncthing@$u")
    h=$(user_home "$u")
    h=${h%/}
    if [[ -z $h ]]; then continue; fi
    for d in "$h/.config/syncthing" "$h/.local/state/syncthing"; do
      if [[ -d $d ]]; then cfgs+=("$d"); fi
    done
  done
  # 程序：本脚本装在 $ST_BIN；属于某个软件包的，说明是 apt 装的；在别的位置的，不是本脚本装的，不动
  if [[ -e $ST_BIN ]]; then
    pkg=$(dpkg -S "$ST_BIN" 2>/dev/null |
      sed -n 's/^\([a-z0-9][a-z0-9+.-]*\)\(:[a-z0-9]*\)\{0,1\}: .*/\1/p' | sed -n 1p || true)
    if [[ -z $pkg ]]; then files+=("$ST_BIN"); fi
  else
    keep_bin=$(command -v syncthing 2>/dev/null || true)
  fi
  if [[ -z $pkg && -z $keep_bin && -f $UNIT_FILE ]]; then files+=("$UNIT_FILE"); fi
  if [[ -n $PEER_IP ]] && command -v ufw >/dev/null 2>&1; then
    added=$(LC_ALL=C ufw show added 2>/dev/null || true)
    rule="allow from $PEER_IP to any port $SYNC_PORT proto tcp"
    if ! grep -qxF "ufw $rule" <<<"$added"; then rule=''; fi
  fi
  # 早期版本的脚本在 firewalld 运行时会加这条规则（Ubuntu 默认没有 firewalld）
  if [[ -n $PEER_IP ]] && command -v firewall-cmd >/dev/null 2>&1 &&
    systemctl is-active --quiet firewalld 2>/dev/null; then
    frule="rule family=ipv4 source address=$PEER_IP/32 port port=$SYNC_PORT protocol=tcp accept"
    if ! fw_has_rule "$frule"; then frule=''; fi
  fi
  if [[ -n $FOLDER_PATH && -d $FOLDER_PATH ]]; then
    counts=$(find "$FOLDER_PATH" -path "$FOLDER_PATH/.stversions" -prune -o \
      -type f -name '.syncthing.*.tmp' -printf 't\n' -o -name '*.sync-conflict-*' -printf 'c\n' 2>/dev/null || true)
    ntmp=$(grep -c '^t$' <<<"$counts" || true)
    nconf=$(grep -c '^c$' <<<"$counts" || true)
    if [[ -e $FOLDER_PATH/.stfolder ]]; then fx+=(.stfolder); fi
    if ((ntmp > 0)); then fx+=("$ntmp 个传到一半的临时文件（.syncthing.*.tmp）"); fi
    if [[ -d $FOLDER_PATH/.stversions ]]; then
      vsize=$(du -sh "$FOLDER_PATH/.stversions" 2>/dev/null | cut -f1 || true)
      vsize=${vsize:-?}
    fi
  fi
  for f in "$STATE_FILE" "$SYSCTL_FILE"; do
    if [[ -f $f ]]; then own+=("$f"); fi
  done

  if ((${#units[@]} + ${#files[@]} + ${#cfgs[@]} + ${#own[@]} == 0)) && [[ -z $pkg ]]; then
    info "本机没有找到 Syncthing 服务、本脚本安装的程序或配置，不需要卸载"
    if [[ -n $keep_bin ]]; then info "$keep_bin 不是本脚本安装的，没有处理"; fi
    return 0
  fi

  # ---- 显示计划，确认后再执行 ----
  prog=$(sync_progress 2>/dev/null || true)
  echo
  echo "${C_BLD}=========== 卸载 Syncthing 私网同步 ===========${C_OFF}"
  echo "将执行以下操作："
  if ((${#units[@]})); then echo "  停止并禁用服务    : ${units[*]}"; fi
  if [[ -n $pkg ]]; then echo "  卸载软件包        : $pkg（用 apt 安装的）"; fi
  if ((${#files[@]})); then echo "  删除程序          : ${files[*]}"; fi
  if ((${#cfgs[@]})); then
    echo "  删除配置和数据库  : ${cfgs[*]}"
    echo "                      （包括设备密钥，以后重新安装时设备 ID 会改变）"
  fi
  if [[ -n $rule ]]; then echo "  删除防火墙规则    : ufw $rule"; fi
  if [[ -n $frule ]]; then echo "  删除防火墙规则    : firewalld $frule"; fi
  if ((${#fx[@]})); then
    printf -v out '%s、' "${fx[@]}"
    echo "  清理同步目录      : $FOLDER_PATH 中的 ${out%、}"
  fi
  if ((${#own[@]})); then echo "  删除本脚本的文件  : ${own[*]}"; fi
  if [[ -n $FOLDER_PATH && -d $FOLDER_PATH ]]; then
    if [[ -n $vsize ]]; then
      keep+=("同步目录 $FOLDER_PATH 中的文件（.stversions 稍后单独询问）")
    else
      keep+=("同步目录 $FOLDER_PATH 中的文件")
    fi
  fi
  if ((nconf > 0)); then keep+=("$nconf 个冲突文件（*.sync-conflict-*）"); fi
  if [[ -n $keep_bin ]]; then keep+=("$keep_bin（不是本脚本安装的）"); fi
  if ((${#keep[@]})); then
    echo "保留："
    printf '  %s\n' "${keep[@]}"
  fi
  if [[ -z $FOLDER_PATH ]]; then
    warn "没有找到 $STATE_FILE，不知道同步目录和对端 IP：目录里的 .stfolder、.stversions，以及 ufw 规则，需要手动清理"
  fi
  if [[ -n $prog ]]; then
    while IFS= read -r out; do warn "$out"; done <<<"$prog"
  fi
  echo
  confirm "确认卸载？" N || die "已取消，没有做任何改动"
  if [[ -n $vsize ]] &&
    confirm "同时删除 $FOLDER_PATH/.stversions（$vsize，里面是被删除或覆盖前的旧版本）？" N; then
    del_ver=1
  fi

  # ---- 执行：先停服务，停不下来就不删任何东西 ----
  for u in "${units[@]}"; do
    systemctl stop "$u" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "$u" 2>/dev/null; then
      die "无法停止 $u，没有删除任何文件。查看原因：systemctl status $u"
    fi
  done
  for u in "${units[@]}"; do
    systemctl disable -q "$u" >/dev/null 2>&1 || true
    # 之前运行失败过的服务会一直留在 systemd 的列表里，清掉，免得再次运行时又被找到
    systemctl reset-failed "$u" >/dev/null 2>&1 || true
    # 服务文件已经不在时，disable 删不掉开机自启的链接，这里直接删
    rm -f -- "${UNIT_FILE%/*}"/*.wants/"$u.service"
  done
  if ((${#units[@]})); then ok "已停止并禁用 ${units[*]}"; fi

  if [[ -n $pkg ]]; then
    if DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
      apt-get remove -y -qq -o DPkg::Lock::Timeout=300 "$pkg" >/dev/null 2>&1; then
      ok "已卸载软件包 $pkg"
    else
      warn "卸载软件包 $pkg 失败，请稍后手动执行：apt-get remove $pkg"
    fi
  fi
  if ((${#files[@]})); then
    rm -f -- "${files[@]}"
    ok "已删除 ${files[*]}"
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  if ((${#cfgs[@]})); then
    rm -rf -- "${cfgs[@]}"
    ok "已删除 Syncthing 的配置和数据库"
  fi
  if [[ -n $rule ]]; then
    out=$(LC_ALL=C ufw --force delete allow from "$PEER_IP" to any port "$SYNC_PORT" proto tcp 2>&1 || true)
    if [[ $out == *"Rule deleted"* ]]; then
      ok "已删除 ufw 规则：$rule"
    else
      warn "删除 ufw 规则失败，请手动执行：ufw delete $rule"
    fi
  fi
  if [[ -n $frule ]]; then
    # 运行时和永久规则分别删除，不执行 --reload（reload 会丢掉其他没有持久化的规则）
    firewall-cmd -q --remove-rich-rule="$frule" >/dev/null 2>&1 || true
    firewall-cmd -q --permanent --remove-rich-rule="$frule" >/dev/null 2>&1 || true
    if fw_has_rule "$frule"; then
      warn "删除 firewalld 规则失败，请手动执行：firewall-cmd --remove-rich-rule='$frule'; firewall-cmd --permanent --remove-rich-rule='$frule'"
    else
      ok "已删除 firewalld 规则：$frule"
    fi
  fi
  if ((${#fx[@]})) || [[ -n $del_ver ]]; then
    rm -rf -- "$FOLDER_PATH/.stfolder"
    if ((ntmp > 0)); then
      find "$FOLDER_PATH" -path "$FOLDER_PATH/.stversions" -prune -o \
        -type f -name '.syncthing.*.tmp' -exec rm -f -- {} + 2>/dev/null || true
    fi
    if [[ -n $del_ver ]]; then
      rm -rf -- "$FOLDER_PATH/.stversions"
      fx+=(.stversions)
    fi
    printf -v out '%s、' "${fx[@]}"
    ok "已清理同步目录中的 ${out%、}"
  fi
  if ((${#own[@]})); then
    rm -f -- "${own[@]}"
    ok "已删除 ${own[*]}"
  fi

  echo
  ok "本机卸载完成"
  if [[ -n $FOLDER_PATH && -d $FOLDER_PATH ]]; then
    echo "  - 同步目录 $FOLDER_PATH 中的文件都还在，现在是普通目录"
    printf -v qpath '%q' "$FOLDER_PATH"
    if [[ -n $vsize && -z $del_ver ]]; then
      echo "  - 旧版本还在 $FOLDER_PATH/.stversions，不需要的话可以手动删除"
    fi
    if ((nconf > 0)); then
      echo "  - 冲突文件已保留，查看：find $qpath -name '*.sync-conflict-*'"
    fi
  fi
  if [[ " ${own[*]} " == *" $SYSCTL_FILE "* ]]; then
    echo "  - inotify 监控上限会在服务器重启后恢复为系统默认值，不重启也没有影响"
  fi
  echo "  - 如果在阿里云安全组里为 TCP $SYNC_PORT 单独加过规则，请到控制台删除"
  if [[ -n $PEER_IP ]]; then
    echo "  - $PEER_ROLE（$PEER_IP）也不再同步的话，请在 $PEER_ROLE 上也运行：sudo bash $SELF uninstall"
  fi
}

usage() {
  cat <<EOF
用法：
  sudo bash $SELF            交互式安装与配置（A、B 两台同时运行）
  sudo bash $SELF finalize   仅 B：等首次同步完成后切换为双向
  sudo bash $SELF status     查看连接与同步状态
  sudo bash $SELF uninstall  卸载（同步目录里的文件保留）
EOF
}

main() {
  case ${1:-setup} in
    setup | finalize | status | uninstall) ;;
    -h | --help | help)
      usage
      return 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
  TMPD=$(mktemp -d)
  case ${1:-setup} in
    setup) cmd_setup ;;
    finalize) cmd_finalize ;;
    status) cmd_status ;;
    uninstall) cmd_uninstall ;;
  esac
}

if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi
