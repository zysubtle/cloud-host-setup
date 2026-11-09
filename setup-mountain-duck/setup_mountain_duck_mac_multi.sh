#!/bin/bash
# MacBook：交互配置 Mountain Duck --SFTP/ProxyJump--> 跳板 --> 东京私网。
# 用法：bash ~/Downloads/setup_mountain_duck_mac_multi.sh（不要 sudo）。
# 前提：Mac 能用私钥登录跳板；跳板上的 ssh tokyo 已能登录东京。
# 兼容 macOS 自带 Bash 3.2；不需要 Python、Homebrew、Mosh 或额外辅助文件。
# 只在东京追加受跳板来源限制的公钥；不改 sshd、云安全组、UFW 或原终端登录密钥。
# 配置段、主机公钥、书签按需备份，已有专用私钥复用，公钥授权不重复叠加。
# 参考：https://docs.mountainduck.io/protocols/sftp/
#       https://docs.mountainduck.io/mountainduck/interface/
# .duck 字段依据 Cyberduck Host.java / serializer/HostDictionary.java。
# 修订：所有具名变量显式使用 ${...}，避免旧版 Bash 在中文标点处误判变量边界。
# 修订：quote_sh 不再依赖 ${var//pat/rep} 字面替换串的引号处理（Bash 3.2 与 4.3+ 不同，
#       旧写法在 macOS 自带 Bash 下让远端报 unexpected EOF while looking for matching `'）。
# 修订：Mountain Duck/Cyberduck 校验 ProxyJump 第一跳时按“目标别名”查 known_hosts，
#       因此在东京别名（仅别名，不含 IP）下额外登记跳板主机公钥；OpenSSH 按 IP 查，不受影响。
# 每个 SFTP 别名对应一个书签、一个 UUID 和一段 SSH 配置；原 v1 线路可原位更新。
set -euo pipefail
umask 077

MD_BEGIN='# BEGIN mountain-duck-tokyo-setup-v1'
MD_END='# END mountain-duck-tokyo-setup-v1'
MD_KNOWN_NOTE='# mountain-duck-tokyo-setup: jump host key listed under the Tokyo alias because Mountain Duck checks the ProxyJump hop under the target name'
MD_TMP=''
MD_SETTINGS=''
MD_SSH_DIR=''
MD_CONFIG=''
MD_KNOWN=''
MD_STAMP=''
MD_REMOTE_TEST=''
MD_JUMP_HOST_PUBLIC=''
MD_DIR_WRITABLE=1
MD_LOCK=''
MD_BOOKMARK_DIR=''

say() { printf '%s\n' "$*"; }
die() { printf '\n未完成：%s\n' "$*" >&2; exit 1; }

help_text() {
    cat <<'HELP'
在 Mac 上配置 Mountain Duck 经现有跳板访问东京目录。

执行：bash setup_mountain_duck_mac_multi.sh
无需 sudo；需要已安装 Mountain Duck（未安装也可先生成书签）。
前提：Mac 有可登录跳板的私钥，跳板的现有 SSH 别名（默认 tokyo）能登录东京。

脚本会提问：跳板地址/账号/私钥、东京私网地址/账号、挂载目录等。
默认沿用本会话的 8.222.91.192 -> 172.24.138.35，所有值均可修改。
然后复用/创建 Mac 专用密钥，经原跳板连接追加东京公钥；测试 ProxyJump、SFTP 读写；
成功后写入 ~/.ssh/config，并在 ~/Documents/MountainDuck-Bookmarks/ 生成 .duck 书签。
known_hosts 登记东京公钥，并在东京别名下登记跳板公钥（Mountain Duck 校验跳板时按目标别名查找）。
首次 SSH 主机指纹确认、已有私钥口令和 Mountain Duck 首次连接提示由你本人完成。

已有线路时，回车新增，或输入列出的 SFTP 别名来更新。新增线路会建议空闲别名。
每条线路分别保存输入和书签 UUID。更新旧版线路时可沿用其别名、密钥和书签。
输入 :quit 退出。重试未完成的线路时，选择上次使用的 SFTP 别名。
不修改云安全组、sshd、UFW，不读取或复制跳板上的东京私钥。
本脚本用于已打通的现有跳板链路，不用于初始化两台全新服务器。
HELP
}

has_control() { [[ $1 =~ [[:cntrl:]] ]]; }
valid_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ && $1 != root ]]; }
valid_alias() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,40}$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_ip() {
    local input=$1 a b c d
    [[ ${input} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r a b c d <<< "${input}"
    [[ ${#a} -le 3 && ${#b} -le 3 && ${#c} -le 3 && ${#d} -le 3 ]] || return 1
    ((10#${a} >= 1 && 10#${a} < 224 && 10#${a} != 127 && 10#${b} <= 255 && 10#${c} <= 255 && 10#${d} <= 255))
}
private_ip() {
    valid_ip "$1" || return 1
    local a b rest
    IFS=. read -r a b rest <<< "$1"
    ((10#${a} == 10 || (10#${a} == 172 && 10#${b} >= 16 && 10#${b} <= 31) || (10#${a} == 192 && 10#${b} == 168)))
}
valid_remote_dir() {
    [[ $1 == /* || $1 == '~' || $1 == '~/'* ]] || return 1
    ! has_control "$1" && [[ $1 != *'*'* && $1 != *'?'* && $1 != *'['* && $1 != *']'* ]]
}

trim_path_edges() {
    # 只处理边缘空白；保留目录中间的空格，也允许用户明确选择保留边缘空白。
    # NBSP 和全角空格常由复制粘贴带入；用 UTF-8 字节写法兼容 macOS Bash 3.2。
    local value=$1 edge previous
    while :; do
        previous=${value}
        for edge in ' ' $'\t' $'\r' $'\302\240' $'\343\200\200'; do
            case ${value} in "${edge}"*) value=${value#"${edge}"} ;; esac
            case ${value} in *"${edge}") value=${value%"${edge}"} ;; esac
        done
        [[ ${value} == "${previous}" ]] && break
    done
    printf '%s' "${value}"
}

ask() {
    local label=$1 fallback=${2:-} answer
    printf '%s' "${label}" >&2
    [[ -z ${fallback} ]] || printf ' [%s]' "${fallback}" >&2
    printf '：' >&2
    IFS= read -r answer < /dev/tty || die '交互终端已关闭；修复后可重跑。'
    [[ ${answer} != :quit ]] || die '已按你的输入退出。'
    [[ -n ${answer} ]] || answer=${fallback}
    printf '%s' "${answer}"
}

ask_checked() {
    local label=$1 fallback=$2 validator=$3 value
    while :; do
        value=$(ask "${label}" "${fallback}") || return 1
        if "${validator}" "${value}"; then printf '%s' "${value}"; return 0; fi
        printf '输入格式无效，请重新填写。\n' >&2
    done
}

yes() {
    local answer
    answer=$(ask "$1 (y/n)" "${2:-y}") || return 1
    case ${answer} in y|Y|yes|YES|是) return 0 ;; *) return 1 ;; esac
}

ask_remote_directory() {
    local fallback=$1 value cleaned
    while :; do
        value=$(ask '要挂载的东京目录（绝对路径或 ~/ 开头）' "${fallback}") || return 1
        cleaned=$(trim_path_edges "${value}")
        if [[ ${cleaned} != "${value}" ]]; then
            printf '检测到目录首尾空白，去除后为：%s\n' "${cleaned}" >&2
            if yes '是否去除目录首尾的空白（保留中间空格）'; then value=${cleaned}; fi
        fi
        if valid_remote_dir "${value}"; then printf '%s' "${value}"; return 0; fi
        printf '请输入有效目录；不支持相对路径、控制字符或通配符。\n' >&2
    done
}

show_preview() {
    printf '\n'; say '配置预览：'
    say "  Mac -> ${JUMP_USER}@${JUMP_IP}:${JUMP_PORT} -> ${TOKYO_USER}@${TOKYO_IP}:${TOKYO_PORT}"
    say "  东京目录：${REMOTE_DIR}；书签别名：${TOKYO_ALIAS}"
    say "  使用跳板现有的 ssh ${OLD_TOKYO_ALIAS} 完成首次授权。"
}

quote_sh() {
    # 替换串必须放在变量里：Bash 4.3+ 会对 ${var//pat/rep} 的字面替换串做引号去除，
    # macOS 自带的 Bash 3.2 不会，字面量写法在 3.2 下把 ' 变成 \'\\'\'，远端 bash 随即报引号不匹配。
    local quote="'" escaped="'\\''"
    printf "'%s'" "${1//${quote}/${escaped}}"
}
quote_config() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "${value}"
}
quote_sftp() {
    local value=$1
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '"%s"' "${value}"
}
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}
expand_local() {
    local value=$1
    case ${value} in '~/'*) value="${HOME}/${value:2}" ;; esac
    # 路径按文本处理，不使用 eval；包含空格时可直接输入完整路径。
    [[ ${value} == /* ]] || value="${PWD}/${value}"
    printf '%s' "${value}"
}

read_setting() {
    local key=$1 fallback=$2 value='' file
    for file in "${MD_TMP}/installed-defaults" "${MD_SETTINGS}"; do
        [[ -f ${file} && ! -L ${file} ]] || continue
        value=$(awk -F '\t' -v k="${key}" '$1==k {sub(/^[^\t]*\t/, ""); print; exit}' "${file}")
        [[ -z ${value} ]] || break
    done
    printf '%s' "${value:-${fallback}}"
}

strip_managed() {
    awk -v begin="${MD_BEGIN}" -v end="${MD_END}" '
        $0==begin { if (inside || seen) exit 41; inside=1; seen=1; next }
        $0==end { if (!inside) exit 42; inside=0; skipblank=1; next }
        inside { next }
        skipblank { skipblank=0; if ($0=="") next }
        { print }
        END { if (inside) exit 43 }
    ' "$1"
}

alias_taken() {
    awk -v wanted="$1" '
        tolower($1)=="host" || tolower($1) ~ /^host=/ {
            sub(/^[ \t]*[Hh][Oo][Ss][Tt][ \t]*=[ \t]*/, "Host ")
            for(i=2;i<=NF;i++) if(tolower($i)==wanted) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "${MD_TMP}/base-config"
}

alias_free() {
    local name=$1 path="${MD_BOOKMARK_DIR}/$1.duck"
    [[ ${name} != "${TOKYO_ALIAS:-}" && ! -e ${path} && ! -L ${path} ]] &&
        ! alias_taken "${name}" && ! grep -qxF -- "${name}" "${MD_TMP}/profiles"
}

free_alias() {
    local base=$1 name=$1 number=2
    while ! alias_free "${name}"; do
        name="${base:0:32}-${number}"
        number=$((number + 1))
    done
    printf '%s' "${name}"
}

choose_alias() {
    local label=$1 initial value
    initial=$(free_alias "$2")
    while :; do
        value=$(ask_checked "${label}" "${initial}" valid_alias) || return 1
        if alias_free "${value}"; then printf '%s' "${value}"; return 0; fi
        printf '别名 %s 已占用，请换一个。\n' "${value}" >&2
        initial=$(free_alias "${value}")
    done
}

bookmark_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

managed_hosts() {
    awk -v begin="${MD_BEGIN}" -v end="${MD_END}" '
        $0==begin {inside=1; next} $0==end {inside=0}
        inside && $1=="Host" {host=$2}
        inside && $1=="ProxyJump" {print host, $2}
    ' "${MD_TMP}/original-config"
}

load_installed_defaults() {
    local jump=$1 side host
    for side in jump tokyo; do
        if [[ ${side} == jump ]]; then host=${jump}; else host=${TOKYO_ALIAS}; fi
        printf '%s_alias\t%s\n' "${side}" "${host}"
        ssh -G -F "${MD_TMP}/original-config" "${host}" | awk -v p="${side}" '
            $1=="hostname" {print p "_ip\t" $2} $1=="port" {print p "_port\t" $2}
            $1=="user" {print p "_user\t" $2}
            $1=="identityfile" && !found {found=1; sub(/^[^ ]+ /,""); print p "_key\t" $0}
        ' || return 1
    done > "${MD_TMP}/installed-defaults"
}

select_bookmark() {
    local input='' legacy_alias legacy_jump file name prefix='# BEGIN mountain-duck-tokyo-setup-v2 '
    local original="${MD_TMP}/original-config"
    MD_SETTINGS="${MD_SSH_DIR}/mountain_duck_tokyo_settings.tsv"
    # v1 先保存输入，再测试和写 config。失败的上次输入可能指向另一台跳板。
    # 已安装线路的身份取自实际的 v1 配置段。
    # 替换单条线路前，先检查所有脚本标记，防止残缺或嵌套的段吞掉相邻书签。
    awk -v legacy="${MD_BEGIN}" -v legacy_end="${MD_END}" -v begin="${prefix}" \
        -v end='# END mountain-duck-tokyo-setup-v2 ' '
        $0==legacy || index($0,begin)==1 {
            if (closing!="" || seen[$0]++) exit 1
            if ($0==legacy) closing=legacy_end
            else {
                name=substr($0,length(begin)+1)
                if (name!~/^[a-z][a-z0-9_-]*$/ || length(name)>41) exit 1
                print name
                closing=end name
            }
            next
        }
        $0==legacy_end || index($0,end)==1 {if ($0!=closing) exit 1; closing=""}
        END {if (closing!="") exit 1}
    ' "${original}" > "${MD_TMP}/installed-profiles" || die '已有脚本管理段格式异常，未覆盖。'
    managed_hosts > "${MD_TMP}/legacy-hosts"
    if grep -qxF -- "${MD_BEGIN}" "${original}"; then
        read -r legacy_alias legacy_jump < "${MD_TMP}/legacy-hosts" &&
            valid_alias "${legacy_alias}" && valid_alias "${legacy_jump}" || die '无法识别旧版 SSH 配置段里的别名。'
    else
        legacy_alias=$(read_setting tokyo_alias '')
    fi
    {
        if valid_alias "${legacy_alias}"; then printf '%s\n' "${legacy_alias}"; fi
        cat "${MD_TMP}/installed-profiles"
        for file in "${MD_SSH_DIR}"/mountain_duck_profile_*.tsv; do
            [[ -f ${file} && ! -L ${file} ]] || continue
            name=${file##*/mountain_duck_profile_}; printf '%s\n' "${name%.tsv}"
        done
    } | LC_ALL=C sort -u > "${MD_TMP}/profiles"
    cp "${original}" "${MD_TMP}/base-config"
    if [[ -s ${MD_TMP}/profiles ]]; then
        say '可更新或重试的书签（SFTP 别名）：'
        sed 's/^/  /' "${MD_TMP}/profiles"
        while :; do
            input=$(ask '回车新增书签；更新或重试请输入上面已有的别名' '+') || return 1
            [[ ${input} != '+' ]] || break
            if valid_alias "${input}" && grep -qxF -- "${input}" "${MD_TMP}/profiles"; then break; fi
            say '请输入列出的 SFTP 别名，或输入 + 新增。'
        done
    fi
    if [[ -z ${input} || ${input} == '+' ]]; then
        TOKYO_ALIAS=''
        TOKYO_ALIAS=$(choose_alias '新书签的 Mac SFTP 别名' tokyo-files) || return 1
        say "新增书签：${TOKYO_ALIAS}"
    else
        TOKYO_ALIAS=${input}
        say "更新书签：${TOKYO_ALIAS}"
    fi
    if [[ ${TOKYO_ALIAS} == "${legacy_alias}" ]]; then
        if [[ -s ${MD_TMP}/legacy-hosts ]]; then
            load_installed_defaults "${legacy_jump}" || die '无法读取旧版 SSH 线路。'
        fi
    else
        MD_BEGIN="${prefix}${TOKYO_ALIAS}"
        MD_END="# END mountain-duck-tokyo-setup-v2 ${TOKYO_ALIAS}"
        MD_SETTINGS="${MD_SSH_DIR}/mountain_duck_profile_${TOKYO_ALIAS}.tsv"
        if [[ ! -f ${MD_SETTINGS} ]] && grep -qxF -- "${MD_BEGIN}" "${original}"; then
            local target jump
            read -r target jump <<< "$(managed_hosts)"
            [[ ${target} == "${TOKYO_ALIAS}" ]] && valid_alias "${jump}" || die '无法识别当前书签的 SSH 配置段。'
            load_installed_defaults "${jump}" || die '无法读取已有 SSH 线路。'
        fi
    fi
    strip_managed "${original}" > "${MD_TMP}/base-config" || die '当前书签的 SSH 配置段格式异常，未覆盖。'
    if alias_taken "${TOKYO_ALIAS}"; then die "其他 SSH 配置也使用 ${TOKYO_ALIAS}，请先核对。"; fi
    load_bookmark_uuid "${input}"
}

load_bookmark_uuid() {
    local input=$1 file="${MD_BOOKMARK_DIR}/${TOKYO_ALIAS}.duck" installed_uuid
    BOOKMARK_UUID=$(read_setting uuid '')
    if [[ -e ${file} || -L ${file} ]]; then
        [[ -n ${input} && ${input} != '+' ]] || die "同名书签刚刚出现，请重跑：${file}"
        [[ -f ${file} && ! -L ${file} ]] || die "书签文件路径异常：${file}"
        cp "${file}" "${MD_TMP}/original.duck"
        [[ $(bookmark_value Hostname "${file}") == "${TOKYO_ALIAS}" ]] || die "现有同名书签指向其他主机：${file}"
        installed_uuid=$(bookmark_value UUID "${file}") || die "无法读取已有书签 UUID：${file}"
        [[ -n ${installed_uuid} ]] || die '已有书签的 UUID 为空。'
        if [[ -n ${BOOKMARK_UUID} && ${installed_uuid} != "${BOOKMARK_UUID}" ]]; then
            die "已有书签与保存的 UUID 不同，请核对：${file}"
        fi
        BOOKMARK_UUID=${installed_uuid}
        if [[ -s ${MD_TMP}/installed-defaults ]]; then
            printf 'remote_dir\t%s\nnickname\t%s\n' "$(bookmark_value Path "${file}")" "$(bookmark_value Nickname "${file}")" >> "${MD_TMP}/installed-defaults"
        fi
    fi
    [[ -n ${BOOKMARK_UUID} ]] || BOOKMARK_UUID=$(uuidgen)
}

choose_private_key() {
    local fallback=$1 path
    while :; do
        path=$(ask '登录跳板的现有私钥路径；留空可打开文件选择器' "${fallback}") || return 1
        if [[ -z ${path} ]]; then
            path=$(/usr/bin/osascript -e 'POSIX path of (choose file with prompt "选择目前用于登录跳板机的私钥（不是 .pub 文件）")') || continue
        fi
        path=$(expand_local "${path}")
        if [[ -f ${path} && ${path} != *.pub ]] && ! has_control "${path}" && [[ ${path} != *'$'* && ${path} != *'%'* ]]; then
            printf '%s' "${path}"; return 0
        fi
        printf '请填写实际私钥文件；支持含空格的绝对路径或 ~/ 开头的路径，不支持 $、%% 或控制字符。\n' >&2
        fallback=''
    done
}

replace_file() {
    local src=$1 dest=$2 candidate
    [[ ! -L ${dest} && ( ! -e ${dest} || -f ${dest} ) ]] || die "不是普通文件，未覆盖：${dest}"
    if [[ -f ${dest} ]] && cmp -s "${src}" "${dest}"; then chmod 600 "${dest}"; return; fi
    [[ ! -f ${dest} ]] || cp -p "${dest}" "${dest}.bak.md-${MD_STAMP}"
    candidate=$(mktemp "$(dirname "${dest}")/.md-write.XXXXXX")
    cat "${src}" > "${candidate}"
    chmod 600 "${candidate}"
    mv -f "${candidate}" "${dest}"
}

render_config() {
    {
        printf '%s\n' "${MD_BEGIN}"
        printf 'Host %s\n    HostName %s\n    User %s\n    Port %s\n' "${JUMP_ALIAS}" "${JUMP_IP}" "${JUMP_USER}" "${JUMP_PORT}"
        printf '    IdentityFile %s\n' "$(quote_config "${JUMP_KEY}")"
        printf '    IdentitiesOnly yes\n    PreferredAuthentications publickey\n    ForwardAgent no\n'
        printf '    ServerAliveInterval 30\n    ServerAliveCountMax 3\n\n'
        printf 'Host %s\n    HostName %s\n    User %s\n    Port %s\n' "${TOKYO_ALIAS}" "${TOKYO_IP}" "${TOKYO_USER}" "${TOKYO_PORT}"
        printf '    IdentityFile %s\n' "$(quote_config "${TOKYO_KEY}")"
        printf '    IdentitiesOnly yes\n    PreferredAuthentications publickey\n    ForwardAgent no\n'
        printf '    ProxyJump %s\n    ServerAliveInterval 30\n    ServerAliveCountMax 3\n' "${JUMP_ALIAS}"
        printf '    UserKnownHostsFile %s\n' "$(quote_config "${MD_KNOWN}")"
        # 恢复原文件顶部全局设置的匹配范围。
        printf 'Host *\n%s\n\n' "${MD_END}"
        cat "${MD_TMP}/base-config"
    } > "${MD_TMP}/config"
    chmod 600 "${MD_TMP}/config"
}

ssh_jump() {
    ssh -F "${MD_TMP}/config" -o ConnectTimeout=12 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=ask "${JUMP_ALIAS}" "$@"
}
ssh_tokyo_old() {
    # 可选第 2 个参数：在同一条跳板连接里、转到东京之前先在跳板本机执行的命令（不增加口令询问）。
    local remote=$1 before=${2:-}
    ssh_jump "${before}ssh -T -o ConnectTimeout=12 -o ConnectionAttempts=1 $(quote_sh "${OLD_TOKYO_ALIAS}") $(quote_sh "${remote}")"
}
ssh_tokyo_new() {
    ssh -F "${MD_TMP}/config" -o ConnectTimeout=12 -o ConnectionAttempts=1 \
        -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 "${TOKYO_ALIAS}" "$@"
}

ensure_key() {
    [[ ! -L ${TOKYO_KEY} ]] || die '专用私钥是符号链接，已停止。'
    if [[ ! -e ${TOKYO_KEY} ]]; then
        [[ ! -e ${TOKYO_KEY}.pub ]] || die '只有公钥但缺少私钥，请先检查原文件。'
        [[ -d $(dirname "${TOKYO_KEY}") ]] || die '专用私钥的父目录不存在。'
        printf '\n'; say '生成 Mac 专用密钥；口令由 ssh-keygen 自己询问，脚本不会读取或保存口令。'
        ssh-keygen -t ed25519 -f "${TOKYO_KEY}" -C mountain-duck
    else
        say '复用已有 Mac 专用密钥。'
    fi
    [[ -f ${TOKYO_KEY} ]] || die '专用私钥不是普通文件。'
    chmod 600 "${TOKYO_KEY}"
    say '检查专用密钥的公钥；如有口令，此时可能询问。'
    ssh-keygen -y -f "${TOKYO_KEY}" > "${MD_TMP}/derived.pub"
    TOKYO_PUBLIC=$(awk 'NR==1 {print $1 " " $2}' "${MD_TMP}/derived.pub")
    [[ ${TOKYO_PUBLIC} == ssh-ed25519\ * ]] || die '本脚本的东京专用密钥应为 Ed25519；已有密钥未覆盖。'
    ssh-keygen -lf "${MD_TMP}/derived.pub"
    if [[ -e ${TOKYO_KEY}.pub ]]; then
        [[ -f ${TOKYO_KEY}.pub && ! -L ${TOKYO_KEY}.pub ]] || die '专用公钥路径异常。'
        [[ $(awk 'NR==1 {print $1 " " $2}' "${TOKYO_KEY}.pub") == "${TOKYO_PUBLIC}" ]] || die '专用公钥与私钥不匹配，未覆盖。'
    else
        printf '%s mountain-duck\n' "${TOKYO_PUBLIC}" > "${TOKYO_KEY}.pub"
        chmod 600 "${TOKYO_KEY}.pub"
    fi
}

probe_server() {
    local probe
    probe=$(cat <<'REMOTE'
set -eu
printf '__MD_CONNECTION__=%s\n' "${SSH_CONNECTION}"
printf '__MD_USER__=%s\n' "$(id -un)"
printf '__MD_HOME__=%s\n' "${HOME}"
printf '__MD_HOSTKEY__='
cat /etc/ssh/ssh_host_ed25519_key.pub
REMOTE
)
    # 同一条已验证的跳板连接里顺带读取跳板自己的 Ed25519 主机公钥，供 Mountain Duck 兼容条目使用。
    local jump_read="if test -r /etc/ssh/ssh_host_ed25519_key.pub; then printf '__MD_JUMPKEY__='; cat /etc/ssh/ssh_host_ed25519_key.pub; fi; "
    ssh_tokyo_old "${probe}" "${jump_read}" < /dev/null > "${MD_TMP}/server-probe"
    MD_CONNECTION=$(sed -n 's/^__MD_CONNECTION__=//p' "${MD_TMP}/server-probe")
    MD_ACTUAL_USER=$(sed -n 's/^__MD_USER__=//p' "${MD_TMP}/server-probe")
    MD_SERVER_HOME=$(sed -n 's/^__MD_HOME__=//p' "${MD_TMP}/server-probe")
    MD_HOST_PUBLIC=$(sed -n 's/^__MD_HOSTKEY__=//p' "${MD_TMP}/server-probe" | awk '{print $1 " " $2}')
    MD_JUMP_HOST_PUBLIC=$(sed -n 's/^__MD_JUMPKEY__=//p' "${MD_TMP}/server-probe" | awk 'NR==1 && $1=="ssh-ed25519" {print $1 " " $2}')
    local source source_port destination dest_port extra
    read -r source source_port destination dest_port extra <<< "${MD_CONNECTION}"
    valid_ip "${source:-}" && valid_port "${source_port:-}" && valid_ip "${destination:-}" && valid_port "${dest_port:-}" || die '未能读取有效的东京 SSH 连接来源。'
    [[ -z ${extra:-} && ${destination} == "${TOKYO_IP}" && ${dest_port} == "${TOKYO_PORT}" && ${MD_ACTUAL_USER} == "${TOKYO_USER}" ]] || die '跳板原有别名实际连接的服务器、端口或账号与填写值不符；未添加新公钥。'
    MD_JUMP_SOURCE=${source}
    [[ ${MD_SERVER_HOME} == /* ]] && ! has_control "${MD_SERVER_HOME}" || die '服务器 home 路径无效。'
    [[ ${MD_HOST_PUBLIC} == ssh-ed25519\ * ]] || die '未能读取东京的 Ed25519 主机公钥。'
    printf '%s\n' "${MD_HOST_PUBLIC}" > "${MD_TMP}/server-host.pub"
    printf '东京主机公钥指纹：'
    ssh-keygen -lf "${MD_TMP}/server-host.pub"
    say "通过原有连接确认：东京账号 ${MD_ACTUAL_USER}，SSH 来源 ${MD_JUMP_SOURCE}。"
    check_jump_key
}

check_jump_key() {
    # Mac known_hosts 若已记录跳板的 Ed25519 公钥，读取值必须与之一致，否则不写兼容条目。
    local jump_pattern known
    if [[ -z ${MD_JUMP_HOST_PUBLIC} ]]; then
        say '未能读取跳板的 Ed25519 主机公钥；Mountain Duck 首次连接时可能把跳板指纹当作东京指纹询问。'
        return 0
    fi
    [[ -f ${MD_KNOWN} ]] || return 0
    jump_pattern=${JUMP_IP}
    [[ ${JUMP_PORT} == 22 ]] || jump_pattern="[${JUMP_IP}]:${JUMP_PORT}"
    known=$(ssh-keygen -F "${jump_pattern}" -f "${MD_KNOWN}" 2>/dev/null | awk '$2=="ssh-ed25519" {print $2 " " $3}' || true)
    if [[ -n ${known} ]] && ! grep -qxF -- "${MD_JUMP_HOST_PUBLIC}" <<< "${known}"; then
        say '注意：跳板 /etc/ssh 中的 Ed25519 公钥与 Mac known_hosts 的跳板记录不一致，未写入 Mountain Duck 兼容条目。'
        MD_JUMP_HOST_PUBLIC=''
    fi
}

trust_server() {
    local host pattern alias_pattern existing current line
    pattern=${TOKYO_IP}
    alias_pattern=${TOKYO_ALIAS}
    [[ ${TOKYO_PORT} == 22 ]] || pattern="[${TOKYO_IP}]:${TOKYO_PORT}"
    [[ ${TOKYO_PORT} == 22 ]] || alias_pattern="[${TOKYO_ALIAS}]:${TOKYO_PORT}"
    if [[ -e ${MD_KNOWN} ]]; then
        [[ -f ${MD_KNOWN} && ! -L ${MD_KNOWN} ]] || die 'known_hosts 不是普通文件。'
        for host in "${pattern}" "${alias_pattern}"; do
            existing=$(ssh-keygen -F "${host}" -f "${MD_KNOWN}" 2>/dev/null || true)
            current=$(printf '%s\n' "${existing}" | awk '$2=="ssh-ed25519" {print $2 " " $3}')
            while IFS= read -r line; do
                if [[ -z ${line} || ${line} == "${MD_HOST_PUBLIC}" ]]; then continue; fi
                # 别名下的跳板公钥是本脚本（或 Mountain Duck 自己）写入的兼容条目，属预期。
                if [[ ${host} == "${alias_pattern}" && -n ${MD_JUMP_HOST_PUBLIC} && ${line} == "${MD_JUMP_HOST_PUBLIC}" ]]; then continue; fi
                die 'Mac 已有主机公钥与通过原有链路读取的公钥不一致；未覆盖，请先核对服务器身份。'
            done <<< "${current}"
        done
        cat "${MD_KNOWN}" > "${MD_TMP}/known-hosts"
    else
        : > "${MD_TMP}/known-hosts"
    fi
    line="${pattern},${alias_pattern} ${MD_HOST_PUBLIC}"
    if ! grep -qxF -- "${line}" "${MD_TMP}/known-hosts"; then
        printf '\n%s\n' "${line}" >> "${MD_TMP}/known-hosts"
    fi
    # Mountain Duck/Cyberduck 校验跳板那一跳时用的是目标别名（tokyo-files），不是跳板 IP；
    # 只登记在别名下，OpenSSH 按东京 IP 查找时仍只接受东京自己的公钥。
    if [[ -n ${MD_JUMP_HOST_PUBLIC} ]]; then
        line="${alias_pattern} ${MD_JUMP_HOST_PUBLIC}"
        if ! grep -qxF -- "${line}" "${MD_TMP}/known-hosts"; then
            printf '\n%s\n%s\n' "${MD_KNOWN_NOTE}" "${line}" >> "${MD_TMP}/known-hosts"
        fi
    fi
    replace_file "${MD_TMP}/known-hosts" "${MD_KNOWN}"
}

authorize_key() {
    local remote
    remote=$(cat <<'REMOTE'
set -eu
umask 077
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"
auth="${HOME}/.ssh/authorized_keys"
test ! -L "${auth}"
line=$(cat)
test -n "${line}"
if test -f "${auth}" && grep -qxF -- "${line}" "${auth}"; then
    printf '__MD_AUTH__=EXISTING\n'
else
    if test -f "${auth}"; then cp -p "${auth}" "${auth}.bak.md-$(date +%Y%m%d-%H%M%S)-$$"; fi
    printf '\n%s\n' "${line}" >> "${auth}"
    printf '__MD_AUTH__=ADDED\n'
fi
chmod 600 "${auth}"
REMOTE
)
    printf 'from="%s",no-agent-forwarding %s mountain-duck\n' "${MD_JUMP_SOURCE}" "${TOKYO_PUBLIC}" > "${MD_TMP}/authorized-line"
    local result
    result=$(ssh_tokyo_old "${remote}" < "${MD_TMP}/authorized-line")
    case ${result} in
        *'__MD_AUTH__=ADDED'*) say "已追加到东京 ~/.ssh/authorized_keys（仅允许来自 ${MD_JUMP_SOURCE}；原文件已备份）。" ;;
        *'__MD_AUTH__=EXISTING'*) say '东京已有这把 Mac 专用公钥，未重复追加。' ;;
        *) die '未能确认东京 authorized_keys 的写入结果。' ;;
    esac
}

check_directory() {
    local remote result dir
    dir=$(quote_sh "${REMOTE_DIR}")
    # 先输出登录标记，再报告来源与目录状态，以便区分“新密钥/ProxyJump 登录失败”和“目录问题”。
    remote="printf '__MD_LOGIN__=OK\\n'; set -- \${SSH_CONNECTION}; printf '__MD_SOURCE__=%s\\n' \"\$1\"; if test -d ${dir} && test -r ${dir} && test -x ${dir}; then if test -w ${dir}; then printf '__MD_DIR__=RW\\n'; else printf '__MD_DIR__=RO\\n'; fi; else printf '__MD_DIR__=MISSING\\n'; fi"
    result=$(ssh_tokyo_new "${remote}" < /dev/null) || true
    if [[ ${result} != *'__MD_LOGIN__=OK'* ]]; then
        say '用 Mac 专用密钥经 ProxyJump 登录东京失败（原因见上方 ssh 报错）。常见原因：'
        say '  - 报 administratively prohibited / open failed：跳板 sshd 禁止 TCP 转发（AllowTcpForwarding）；'
        say '  - 报 Permission denied (publickey)：东京未接受新公钥（如 sshd 的 AuthorizedKeysFile 不是默认位置）。'
        die 'ProxyJump 登录未成功；Mac 正式 SSH 配置尚未写入，东京已追加的公钥保留。'
    fi
    [[ $'\n'${result}$'\n' == *$'\n'"__MD_SOURCE__=${MD_JUMP_SOURCE}"$'\n'* ]] || die "经 ProxyJump 到达东京的来源与跳板原有连接（${MD_JUMP_SOURCE}）不同，from= 限制会拒绝 Mountain Duck；请核对跳板网络。"
    case ${result} in
        *'__MD_DIR__=RW'*) MD_DIR_WRITABLE=1; return 0 ;;
        *'__MD_DIR__=RO'*)
            say "东京账号 ${TOKYO_USER} 能读取 ${REMOTE_DIR}，但没有写权限。"
            if yes '仍然继续（只做读取验证；在 Mountain Duck 里将无法新建、修改或删除文件）' n; then
                MD_DIR_WRITABLE=0
                return 0
            fi
            die "如需写入，请在东京由管理员为 ${TOKYO_USER} 授予该目录写权限（调整属主或 ACL）后重跑；已有授权保留。" ;;
    esac
    say "东京目录 ${REMOTE_DIR} 不存在，或 ${TOKYO_USER} 无法进入/读取它。"
    if ! yes '仅当目录不存在时，尝试用东京普通账号创建该目录' n; then
        die '请核对目录或权限后重跑；已有授权保留。'
    fi
    remote="set -eu; mkdir -p -- ${dir}; test -d ${dir}; test -r ${dir}; test -x ${dir}; test -w ${dir}"
    ssh_tokyo_new "${remote}" < /dev/null || die '无法创建/访问该目录。脚本不会用 sudo 改动项目权限。'
    MD_DIR_WRITABLE=1
}

test_sftp() {
    local uuid remote_name
    if ((MD_DIR_WRITABLE == 0)); then
        # 只读目录：验证 SFTP 子系统可用、能进入目录即可，不尝试写入。
        printf 'cd %s\npwd\nbye\n' "$(quote_sftp "${REMOTE_DIR}")" > "${MD_TMP}/sftp-batch"
        sftp -F "${MD_TMP}/config" -oBatchMode=no -oStrictHostKeyChecking=yes \
            -oHostKeyAlgorithms=ssh-ed25519 -oConnectTimeout=12 -b "${MD_TMP}/sftp-batch" "${TOKYO_ALIAS}" < /dev/null \
            || die 'SFTP 只读验证未成功；Mac 正式 SSH 配置尚未写入。请检查东京的 sftp 子系统，以及登录脚本是否向非交互会话输出文字。'
        say 'SFTP 只读验证成功（未写入测试文件）。'
        return 0
    fi
    uuid=$(uuidgen)
    remote_name=".mountain-duck-test-${uuid}"
    MD_REMOTE_TEST="${REMOTE_DIR}/${remote_name}"
    printf 'Mountain Duck SFTP verification %s\n' "${uuid}" > "${MD_TMP}/upload.txt"
    {
        printf 'cd %s\npwd\n' "$(quote_sftp "${REMOTE_DIR}")"
        printf 'put %s %s\n' "$(quote_sftp "${MD_TMP}/upload.txt")" "$(quote_sftp "${remote_name}")"
        printf 'get %s %s\n' "$(quote_sftp "${remote_name}")" "$(quote_sftp "${MD_TMP}/download.txt")"
        printf 'rm %s\nbye\n' "$(quote_sftp "${remote_name}")"
    } > "${MD_TMP}/sftp-batch"
    # BatchMode=no 在 -b 前传入，保留加密私钥在 /dev/tty 询问口令的能力。
    if ! sftp -F "${MD_TMP}/config" -oBatchMode=no -oStrictHostKeyChecking=yes \
        -oHostKeyAlgorithms=ssh-ed25519 -oConnectTimeout=12 -b "${MD_TMP}/sftp-batch" "${TOKYO_ALIAS}"; then
        say 'SFTP 测试失败，尝试清理这次唯一的测试文件。'
        ssh_tokyo_new "rm -f -- $(quote_sh "${MD_REMOTE_TEST}")" || say "测试文件未能清理：${MD_REMOTE_TEST}"
        MD_REMOTE_TEST=''
        die 'SFTP 未验证成功；Mac 正式 SSH 配置尚未写入。请检查目录写权限与磁盘空间，以及东京登录脚本（如 ~/.bashrc）是否向非交互会话输出文字。'
    fi
    MD_REMOTE_TEST=''
    cmp -s "${MD_TMP}/upload.txt" "${MD_TMP}/download.txt" || die 'SFTP 下载内容与上传内容不一致。'
    say 'SFTP 上传、下载及文件内容核对成功，测试文件已删除。'
}

create_bookmark() {
    local destination=$1 nickname=$2 uuid=$3
    cat > "${destination}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Protocol</key><string>sftp</string>
    <key>Hostname</key><string>$(xml_escape "${TOKYO_ALIAS}")</string>
    <key>Port</key><string>$(xml_escape "${TOKYO_PORT}")</string>
    <key>Username</key><string>$(xml_escape "${TOKYO_USER}")</string>
    <key>Nickname</key><string>$(xml_escape "${nickname}")</string>
    <key>UUID</key><string>$(xml_escape "${uuid}")</string>
    <key>Path</key><string>$(xml_escape "${REMOTE_DIR}")</string>
    <key>Private Key File</key><string>$(xml_escape "${TOKYO_KEY}")</string>
    <key>Readonly</key><string>false</string>
</dict>
</plist>
XML
    chmod 600 "${destination}"
}

save_settings() {
    {
        printf 'jump_ip\t%s\njump_user\t%s\njump_port\t%s\njump_key\t%s\n' "${JUMP_IP}" "${JUMP_USER}" "${JUMP_PORT}" "${JUMP_KEY}"
        printf 'tokyo_ip\t%s\ntokyo_user\t%s\ntokyo_port\t%s\n' "${TOKYO_IP}" "${TOKYO_USER}" "${TOKYO_PORT}"
        printf 'old_alias\t%s\nremote_dir\t%s\ntokyo_key\t%s\n' "${OLD_TOKYO_ALIAS}" "${REMOTE_DIR}" "${TOKYO_KEY}"
        printf 'jump_alias\t%s\ntokyo_alias\t%s\nnickname\t%s\nuuid\t%s\n' "${JUMP_ALIAS}" "${TOKYO_ALIAS}" "${NICKNAME}" "${BOOKMARK_UUID}"
    } > "${MD_TMP}/settings"
    replace_file "${MD_TMP}/settings" "${MD_SETTINGS}"
}

cleanup() {
    local status=$?
    if ((status != 0)); then
        printf '\n配置未全部完成；已有密钥和东京已追加的公钥保留，可修复后重跑。\n' >&2
        if [[ -n ${MD_REMOTE_TEST} ]]; then printf '若这次测试被中断，请检查并删除临时文件：%s\n' "${MD_REMOTE_TEST}" >&2; fi
    fi
    [[ -z ${MD_TMP} ]] || rm -rf "${MD_TMP}"
    if [[ -n ${MD_LOCK} ]]; then rm -f "${MD_LOCK}/pid"; rmdir "${MD_LOCK}"; fi
}

main() {
    case ${1:-} in -h|--help) help_text; return ;; '') ;; *) die '未知参数，请使用 --help。' ;; esac
    [[ $(uname -s) == Darwin ]] || die '此脚本应在 Mac 本地执行。'
    ((EUID != 0)) || die '请以 Mac 当前用户运行，不要使用 sudo。'
    [[ -r /dev/tty ]] || die '请在 Mac Terminal/Ghostty 等本地交互终端运行。'
    local tool key_default candidate actual key_input lock_dir owner nick_default bookmark
    for tool in ssh ssh-keygen sftp awk sed grep cmp uuidgen plutil; do
        command -v "${tool}" >/dev/null || die "缺少 macOS 系统工具：${tool}"
    done
    MD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/md-tokyo.XXXXXX")
    chmod 700 "${MD_TMP}"
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    MD_STAMP="$(date +%Y%m%d-%H%M%S)-$$"
    MD_SSH_DIR="${HOME}/.ssh"
    [[ ! -L ${MD_SSH_DIR} && ( ! -e ${MD_SSH_DIR} || -d ${MD_SSH_DIR} ) ]] || die '~/.ssh 不是普通目录。'
    mkdir -p "${MD_SSH_DIR}"
    chmod 700 "${MD_SSH_DIR}"
    MD_CONFIG="${MD_SSH_DIR}/config"
    MD_KNOWN="${MD_SSH_DIR}/known_hosts"
    MD_BOOKMARK_DIR="${HOME}/Documents/MountainDuck-Bookmarks"
    [[ ! -L ${MD_BOOKMARK_DIR} && ( ! -e ${MD_BOOKMARK_DIR} || -d ${MD_BOOKMARK_DIR} ) ]] || die '书签输出路径不是普通目录。'
    # 并行配置会读写同一个 config 和 known_hosts；从选名到提交只允许一个安装进程。
    lock_dir="${MD_SSH_DIR}/.mountain-duck-setup.lock"
    if ! mkdir "${lock_dir}" 2>/dev/null; then
        owner=$(cat "${lock_dir}/pid" 2>/dev/null || true)
        if [[ ${owner} =~ ^[0-9]+$ ]] && kill -0 "${owner}" 2>/dev/null; then
            die "另一个配置进程（PID ${owner}）正在运行，请等它结束。"
        fi
        die "无法取得配置锁；如上次被强制终止，请在确认没有配置进程后移除 ${lock_dir}。"
    fi
    MD_LOCK=${lock_dir}
    printf '%s\n' "$$" > "${MD_LOCK}/pid"
    [[ ! -L ${MD_CONFIG} && ( ! -e ${MD_CONFIG} || -f ${MD_CONFIG} ) ]] || die '~/.ssh/config 不是普通文件。'
    if [[ -f ${MD_CONFIG} ]]; then cat "${MD_CONFIG}" > "${MD_TMP}/original-config"; else : > "${MD_TMP}/original-config"; fi
    say 'Mountain Duck 经跳板访问东京：交互配置。输入 :quit 可退出。'
    say '请准备当前登录跳板所用的 Mac 私钥；私钥内容和口令不会发送到服务器。'
    select_bookmark
    JUMP_IP=$(ask_checked '跳板公网 IPv4' "$(read_setting jump_ip 8.222.91.192)" valid_ip)
    JUMP_USER=$(ask_checked '跳板账号' "$(read_setting jump_user ecs-user)" valid_user)
    JUMP_PORT=$(ask_checked '跳板现有 SSH 端口' "$(read_setting jump_port 22)" valid_port)
    JUMP_PORT=$((10#${JUMP_PORT}))
    key_default=$(read_setting jump_key '')
    if [[ -z ${key_default} ]]; then
        for candidate in "${HOME}/.ssh/jump.pem" "${HOME}/.ssh/id_ed25519" "${HOME}/.ssh/id_rsa"; do
            if [[ -f ${candidate} ]]; then key_default=${candidate}; break; fi
        done
    fi
    JUMP_KEY=$(choose_private_key "${key_default}")
    TOKYO_IP=$(ask_checked '东京私网 IPv4' "$(read_setting tokyo_ip 172.24.138.35)" private_ip)
    TOKYO_USER=$(ask_checked '东京账号' "$(read_setting tokyo_user ecs-user)" valid_user)
    TOKYO_PORT=$(ask_checked '东京现有 SSH 端口' "$(read_setting tokyo_port 22)" valid_port)
    TOKYO_PORT=$((10#${TOKYO_PORT}))
    OLD_TOKYO_ALIAS=$(ask_checked '跳板上已验证可登录东京的 SSH 别名' "$(read_setting old_alias tokyo)" valid_alias)
    REMOTE_DIR=$(ask_remote_directory "$(read_setting remote_dir /home/ecs-user)")
    key_input=$(ask 'Mac 上东京专用私钥位置（不存在时创建）' "$(read_setting tokyo_key "${HOME}/.ssh/tokyo_mountain_duck")")
    TOKYO_KEY=$(expand_local "${key_input}")
    ! has_control "${TOKYO_KEY}" && [[ ${TOKYO_KEY} != *'$'* && ${TOKYO_KEY} != *'%'* && ${TOKYO_KEY} != *.pub ]] || die '专用私钥路径无效。'
    [[ ${JUMP_KEY} != "${TOKYO_KEY}" ]] || die '请为东京使用一把独立的 Mac 专用密钥。'
    JUMP_ALIAS=$(choose_alias 'Mac 上用于 Mountain Duck 的跳板别名' "$(read_setting jump_alias jump-md)")
    [[ ${JUMP_ALIAS} != "${TOKYO_ALIAS}" ]] || die '两个别名不能相同。'
    nick_default='东京文件夹'
    if [[ -s ${MD_TMP}/profiles ]]; then nick_default=${TOKYO_ALIAS}; fi
    NICKNAME=$(ask 'Mountain Duck 书签昵称' "$(read_setting nickname "${nick_default}")")
    [[ -n ${NICKNAME} ]] && ! has_control "${NICKNAME}" || die '书签昵称无效。'
    show_preview
    yes '开始配置' || die '已取消。'
    # 保存本次输入，连接或安装步骤失败时重跑可直接使用这些默认值。
    save_settings

    ensure_key
    render_config
    ssh -F "${MD_TMP}/config" -G "${TOKYO_ALIAS}" > "${MD_TMP}/effective"
    actual=$(awk '$1=="proxyjump" {print $2}' "${MD_TMP}/effective")
    [[ ${actual} == "${JUMP_ALIAS}" ]] || die 'ProxyJump 未按预期生效。'
    printf '\n'; say '通过现有跳板读取东京身份及真实连接来源；首次跳板指纹请与已有可信记录/控制台核对。'
    probe_server
    case ${REMOTE_DIR} in '~') REMOTE_DIR=${MD_SERVER_HOME} ;; '~/'*) REMOTE_DIR="${MD_SERVER_HOME}/${REMOTE_DIR:2}" ;; esac
    trust_server
    printf '\n'; say '在东京追加受跳板来源限制的 Mac 公钥……'
    authorize_key
    printf '\n'; say '使用 Mac 专用密钥，经 ProxyJump 检查东京目录……'
    check_directory
    printf '\n'
    if ((MD_DIR_WRITABLE)); then say '测试一个很小的 SFTP 文件上传/下载，随后删除……'; else say '只读目录：测试 SFTP 能否进入该目录……'; fi
    test_sftp

    # 在测试期间若用户或其他程序编辑了正式 config，则停止以免覆盖并发变更。
    if [[ -f ${MD_CONFIG} ]]; then
        cmp -s "${MD_CONFIG}" "${MD_TMP}/original-config" || die '测试期间 ~/.ssh/config 被其他程序修改，请重跑以合并最新内容。'
    else
        [[ ! -s ${MD_TMP}/original-config ]] || die '原 ~/.ssh/config 在测试期间被移除，请先检查。'
    fi
    mkdir -p "${MD_BOOKMARK_DIR}"
    bookmark="${MD_BOOKMARK_DIR}/${TOKYO_ALIAS}.duck"
    if [[ -f ${MD_TMP}/original.duck ]]; then
        [[ ! -L ${bookmark} ]] && cmp -s "${MD_TMP}/original.duck" "${bookmark}" || die '测试期间书签发生变化，请重跑。'
    elif [[ -e ${bookmark} || -L ${bookmark} ]]; then
        die '测试期间出现同名书签，请重跑。'
    fi
    create_bookmark "${MD_TMP}/bookmark.duck" "${NICKNAME}" "${BOOKMARK_UUID}"
    plutil -lint "${MD_TMP}/bookmark.duck" >/dev/null
    replace_file "${MD_TMP}/config" "${MD_CONFIG}"
    replace_file "${MD_TMP}/bookmark.duck" "${bookmark}"
    save_settings
    printf '\n'; say 'SSH 和 SFTP 配置已完成。'
    say "书签：${bookmark}"
    say "服务器在这条连接上看到的来源是跳板 ${MD_JUMP_SOURCE}。"
    if ((MD_DIR_WRITABLE == 0)); then say "注意：${TOKYO_USER} 对 ${REMOTE_DIR} 没有写权限，Mountain Duck 里只能读取。"; fi
    say '原有 config/known_hosts/书签内容发生变化时均已保留 .bak.md-时间戳 备份。'
    say 'Mountain Duck 若询问私钥口令，可选择存入钥匙串；目录 Path 只是挂载起点，不是账号权限隔离。'
    local app
    for app in '/Applications/Mountain Duck.app' "${HOME}/Applications/Mountain Duck.app"; do
        if [[ -d ${app}/Contents/_MASReceipt ]]; then
            say "注意：${app} 是 App Store 版。该版本不读 ~/.ssh/known_hosts，每个主机名只存一份指纹；"
            say '      经跳板时两跳都按东京别名校验，可能反复提示指纹变化，建议改用 mountainduck.io 官网版本。'
            break
        fi
    done
    say '如希望按需访问，可在书签中选择 Online 模式。'
    if yes '现在用 Mountain Duck 打开这份书签'; then
        if ! open -a 'Mountain Duck' "${bookmark}"; then
            say "未能打开 Mountain Duck。安装/启动后可执行：open -a 'Mountain Duck' $(quote_sh "${bookmark}")"
        fi
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
