#!/usr/bin/env bash
#
# mount-data-disk.sh — 识别、格式化并挂载 ECS 数据盘，并写入 /etc/fstab 实现开机自动挂载
#
# 用法:
#   sudo ./mount-data-disk.sh                     # 自动检测数据盘，挂到 /data
#   sudo ./mount-data-disk.sh /mnt/data           # 指定挂载点
#   sudo ./mount-data-disk.sh /data /dev/nvme0n1  # 指定挂载点和设备
#   sudo ./mount-data-disk.sh --detect            # 只检测，不做任何修改
#
# 判定逻辑:
#   候选数据盘 = 整盘(TYPE=disk) 且 不是系统盘 且 没有分区 且 没有被挂载
#   - 候选盘上没有文件系统 -> 询问确认后格式化为 ext4
#   - 候选盘上已有文件系统 -> 不格式化，直接挂载（保留原有数据）
#
set -euo pipefail

FS_TYPE="ext4"
DETECT_ONLY=0
if [[ "${1:-}" == "--detect" || "${1:-}" == "-n" ]]; then
  DETECT_ONLY=1
  shift
fi
MOUNT_POINT="${1:-/data}"
DEVICE="${2:-}"
OWNER="${SUDO_USER:-root}"

die() { echo "错误: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请用 sudo 运行: sudo $0 $*"

# ---------- 1. 找出系统盘（根分区所在的整盘），后面要排除 ----------
root_src=$(findmnt -n -o SOURCE /)
# -s 逐级向上列出父设备，取第一个 TYPE=disk 的，兼容 分区 / LVM / 加密 等情况
root_disk=$(lsblk -n -s -l -o NAME,TYPE "$root_src" | awk '$2=="disk"{print $1; exit}')
[[ -n "$root_disk" ]] || die "无法确定系统盘，请手动指定设备"

# ---------- 2. 确定数据盘 ----------
is_candidate() {
  local dev=$1
  [[ "$(basename "$dev")" != "$root_disk" ]] || return 1        # 系统盘
  [[ $(lsblk -n -o NAME "$dev" | wc -l) -eq 1 ]] || return 1    # 有分区或子设备
  [[ -z $(lsblk -n -d -o MOUNTPOINT "$dev") ]] || return 1      # 已挂载
  return 0
}

if [[ -z "$DEVICE" ]]; then
  mapfile -t candidates < <(
    lsblk -d -n -p -o NAME,TYPE | awk '$2=="disk"{print $1}' |
      while read -r d; do is_candidate "$d" && echo "$d"; done
  )
  case ${#candidates[@]} in
    0)
      echo "没有找到待挂载的数据盘。当前块设备:"
      lsblk -d -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
      echo "如果上面已有非系统盘且 MOUNTPOINT 不为空，说明早就挂好了，无需再做。"
      die "否则请到阿里云控制台「云盘」页面确认该盘已挂载到本实例"
      ;;
    1)
      DEVICE=${candidates[0]}
      ;;
    *)
      echo "找到多块候选数据盘，请手动指定一块:"
      lsblk -d -o NAME,SIZE,FSTYPE "${candidates[@]}"
      die "用法: sudo $0 $MOUNT_POINT /dev/xxx"
      ;;
  esac
else
  [[ -b "$DEVICE" ]] || die "$DEVICE 不是块设备"
  is_candidate "$DEVICE" || die "$DEVICE 是系统盘、已有分区或已被挂载，拒绝操作"
fi

existing_fs=$(blkid -o value -s TYPE "$DEVICE" 2>/dev/null || true)
echo "==> 系统盘: /dev/$root_disk（已排除）"
echo "==> 数据盘: $DEVICE   大小: $(lsblk -d -n -o SIZE "$DEVICE")   现有文件系统: ${existing_fs:-无}"
echo "==> 挂载点: $MOUNT_POINT"

if (( DETECT_ONLY )); then
  echo "（--detect 模式，未做任何修改）"
  exit 0
fi

# ---------- 3. 格式化（仅当盘上没有文件系统） ----------
NEWLY_FORMATTED=0
if [[ -z "$existing_fs" ]]; then
  echo
  echo "!! $DEVICE 上没有文件系统，将格式化为 $FS_TYPE，该盘上的所有数据会被清空"
  read -r -p "确认请输入 yes: " answer
  [[ "$answer" == "yes" ]] || die "已取消"
  mkfs."$FS_TYPE" "$DEVICE"
  NEWLY_FORMATTED=1
else
  echo "==> $DEVICE 已有 $existing_fs 文件系统，跳过格式化，直接挂载"
  FS_TYPE=$existing_fs
fi

# ---------- 4. 挂载 ----------
if findmnt -n "$MOUNT_POINT" >/dev/null 2>&1; then
  die "$MOUNT_POINT 已经挂载了其他设备: $(findmnt -n -o SOURCE "$MOUNT_POINT")"
fi
mkdir -p "$MOUNT_POINT"
if [[ -n $(ls -A "$MOUNT_POINT") ]]; then
  echo "警告: $MOUNT_POINT 目录非空，挂载后其中原有文件会被遮住（卸载后恢复可见）"
fi
mount -t "$FS_TYPE" "$DEVICE" "$MOUNT_POINT"
if (( NEWLY_FORMATTED )) && [[ "$OWNER" != "root" ]]; then
  chown "$OWNER:$(id -gn "$OWNER")" "$MOUNT_POINT"
fi
echo "==> 已挂载 $DEVICE -> $MOUNT_POINT"

# ---------- 5. 写入 /etc/fstab，开机自动挂载 ----------
uuid=$(blkid -o value -s UUID "$DEVICE")
[[ -n "$uuid" ]] || die "读取 $DEVICE 的 UUID 失败"
fstab_line="UUID=$uuid  $MOUNT_POINT  $FS_TYPE  defaults,nofail  0  2"
if grep -qE "^[^#]*UUID=$uuid[[:space:]]" /etc/fstab; then
  echo "==> /etc/fstab 已有该盘的记录，跳过"
else
  cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
  echo "$fstab_line" >> /etc/fstab
  echo "==> 已写入 /etc/fstab: $fstab_line"
fi
systemctl daemon-reload 2>/dev/null || true
# mount -a 会按 fstab 重新解析一遍，写错了会在这里报错，而不是留到重启时才发现
mount -a

echo
echo "==> 完成。当前状态:"
findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS "$MOUNT_POINT"
df -h "$MOUNT_POINT"
