# ---------- 通用菜单 ----------
# 选中：返回 0，序号（从 0 起）写入 REPLY。
# 退出：回车 / 0 / q / Ctrl-D，返回 1。
termius_menu() {
    local title=$1
    shift

    local -a opts=("$@")
    local choice raw i

    printf '\n%s\n' "$title"
    for i in "${!opts[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${opts[i]}"
    done
    printf '  0) 退出\n'

    while :; do
        if ! IFS= read -r -p '输入编号，或回车退出：' raw; then
            printf '\n'
            return 1
        fi

        choice=$raw

        # 清理方向键等可能产生的终端转义序列。
        while [[ $choice =~ $'\e'\[[0-9\;?]*[~A-Za-z] ]]; do
            choice=${choice/"${BASH_REMATCH[0]}"/}
        done
        choice=${choice//[$'\r\t\e ']/}

        case $choice in
            ''|0|q|Q) return 1 ;;
        esac

        for i in "${!opts[@]}"; do
            if [[ $choice == "$((i + 1))" ]]; then
                REPLY=$i
                return 0
            fi
        done

        printf '编号无效（收到：%q），请重选。\n' "$raw"
    done
}

# ---------- 选择工作目录 ----------
termius_choose_directory() {
    local root='/data'
    local path
    local -a dirs=() names=()

    if [[ $root != /* || ! -d $root || ! -r $root || ! -x $root ]]; then
        printf '扫描目录无法访问：%q\n' "$root"
        return 1
    fi

    # 保留原来的扫描范围：一级子目录，包括隐藏目录。
    while IFS= read -r -d '' path; do
        dirs+=("$path")
    done < <(
        unset GLOBIGNORE
        set +f
        shopt -u failglob
        shopt -s nullglob dotglob

        for path in "${root%/}"/*; do
            if [[ -d $path ]]; then
                printf '%s\0' "$path"
            fi
        done
    )

    if [[ -z ${dirs[0]+present} ]]; then
        printf '没有可选子目录，保持在 shell。\n'
        return 1
    fi

    for path in "${dirs[@]}"; do
        names+=("$(printf '%q' "${path##*/}")")
    done

    while :; do
        termius_menu \
            "请选择工作目录（扫描：$(printf '%q' "$root")）：" \
            "${names[@]}" || return 1

        # 使用物理路径，避免同一目录的符号链接产生不同会话。
        if builtin cd -P -- "${dirs[REPLY]}"; then
            printf '已进入：%q\n' "$PWD"
            return 0
        fi

        printf '目录无法进入，请重选。\n'
    done
}

# ---------- 接回或恢复 Claude ----------
termius_launch_claude() {
    local executable digest session pane dead
    # 只传 PATH。不再传 CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1：它会把渲染器
    # 强制成经典模式，盖过 ~/.claude/settings.json 的 tui 设置；渲染器交给 /tui 决定。
    local -a tmux_env=(
        -e "PATH=$PATH"
    )

    for executable in tmux claude sha256sum; do
        if ! type -P -- "$executable" >/dev/null 2>&1; then
            printf '未找到可执行文件：%s，保持在 shell。\n' "$executable"
            return 1
        fi
    done

    # 每个目录使用固定的专用 tmux 会话。
    # 不再扫描其他窗格，也不按窗口活动时间判断历史会话。
    digest=$(printf '%s' "$PWD" | command sha256sum) || return 1
    session="termius-claude-${digest%% *}"

    if command tmux has-session -t "=$session" 2>/dev/null; then
        pane=$(command tmux display-message \
            -p -t "=$session" '#{pane_id}') || return 1

        dead=$(command tmux display-message \
            -p -t "$pane" '#{pane_dead}') || return 1

        # 兼容开启 remain-on-exit 后留下的已退出窗格。
        if [[ $dead == 1 ]]; then
            printf '原 Claude 进程已退出，正在恢复最近历史会话……\n'

            # 不使用 -k，避免终止仍在运行的进程。
            command tmux respawn-pane \
                -t "$pane" \
                -c "$PWD" \
                "${tmux_env[@]}" \
                claude --continue || return 1
        else
            printf '正在接回该目录的 Claude 会话……\n'
        fi
    else
        printf '正在恢复该目录最近的 Claude 历史会话……\n'

        # 先后台创建，再接回或切换，避免嵌套 tmux。
        command tmux new-session \
            -d \
            -s "$session" \
            -c "$PWD" \
            "${tmux_env[@]}" \
            claude --continue || return 1
    fi

    if [[ -n ${TMUX:-} ]]; then
        command tmux switch-client -t "=$session"
    else
        command tmux attach-session -t "=$session"
    fi
}

# 选择目录后直接进入 Claude，不再显示工具或会话类型菜单。
clear; { termius_choose_directory && termius_launch_claude; } || :
