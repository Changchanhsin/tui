#!/usr/bin/env bash
# ============================================================================
# fdup_tui.sh —— 文件查重工具（TUI 版，基于 tui.sh） powered by deepseed
# ============================================================================
set -uo pipefail
export LC_ALL=${LC_ALL:-C.UTF-8}

VERSION="0.2.0"
CHANGELOG=(
    "0.2.0: 硬链接去重 / 大小过滤 / 系统目录保护 / 排除规则 / 并行MD5"
    "       保留策略 / 会话持久化 / 关于菜单"
    "0.1.x: 保护目录 / 导出脚本 / 批量选择 / 查重结果清理"
    "0.0.1: 初始版本"
)

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tui.sh
source "$SCRIPT_DIR/tui.sh" || { echo "无法加载 $SCRIPT_DIR/tui.sh" >&2; exit 1; }

# --------------------------- 配置 -------------------------------------------
CONFIG_PATH="$SCRIPT_DIR/fdup.conf"
SESSION_DIR=""
SESSION_PATH=""

_fdup_config_write_default() {
    cat > "$CONFIG_PATH" <<'EOF'
# fdup.conf — 文件查重工具配置
# 每行 key=value；# 开头为注释

# 小于该字节数的文件不参与查重（过滤缩略图、.keep、空占位等噪音）
min_dup_size=4096

# 扫描时跳过的目录名（匹配任意路径组件）
exclude_dir=.git
exclude_dir=node_modules
exclude_dir=__pycache__
exclude_dir=.cache
exclude_dir=.venv
exclude_dir=.tox
exclude_dir=target
exclude_dir=build

# 扫描时跳过的文件 glob（按 basename 匹配）
exclude_glob=*.tmp
exclude_glob=*.part
exclude_glob=*.swp
exclude_glob=*~
EOF
}

_fdup_session_path() {
    local base=${XDG_CACHE_HOME:-$HOME/.cache}
    SESSION_DIR="$base/fdup"
    SESSION_PATH="$SESSION_DIR/session.dat"
}

# --------------------------- 状态 -------------------------------------------
declare -a SCAN_DIRS=()
declare -a PROTECT_DIRS=()

declare -a RESULT_PATHS=()
declare -a RESULT_GIDS=()
declare -a RESULT_SIZES=()
declare -a RESULT_FLAGS=()   # 0=可删 1=保护 3=已删 4=系统
declare -a RESULT_TIMES=()   # mtime 秒
RESULT_READY=0

WORKDIR=""
MIN_DUP_SIZE=4096
declare -a EXCLUDE_DIRS=()
declare -a EXCLUDE_GLOBS=()
TUI_REFLAG_CHANGES=0
PURGED_GROUPS=0

# 不可删除的系统目录（硬编码，只读）
FM_SYSTEM_PREFIXES=(
    /bin /sbin /lib /lib32 /lib64 /libx32 /usr /boot /etc
    /dev /proc /sys /run
    /var/lib/dpkg /var/lib/rpm /var/lib/pacman
    /var/lib/apt /var/lib/snapd
)

# --------------------------- 配置文件读/写 ----------------------------------
fdup_config_load() {
    [[ -f $CONFIG_PATH ]] || _fdup_config_write_default

    local line key val
    MIN_DUP_SIZE=4096
    EXCLUDE_DIRS=()
    EXCLUDE_GLOBS=()

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || ${line:0:1} == '#' ]] && continue
        key=${line%%=*}
        val=${line#*=}
        case $key in
            min_dup_size)
                [[ $val =~ ^[0-9]+$ ]] && MIN_DUP_SIZE=$val ;;
            exclude_dir)
                [[ -n $val ]] && EXCLUDE_DIRS+=("$val") ;;
            exclude_glob)
                [[ -n $val ]] && EXCLUDE_GLOBS+=("$val") ;;
        esac
    done < "$CONFIG_PATH"
}

fdup_config_save() {
    {
        printf '# fdup.conf — 文件查重工具配置\n'
        printf '# 每行 key=value；# 开头为注释\n\n'
        printf 'min_dup_size=%d\n\n' "$MIN_DUP_SIZE"
        printf '# 扫描时跳过的目录名\n'
        local e
        for e in "${EXCLUDE_DIRS[@]}"; do printf 'exclude_dir=%s\n' "$e"; done
        printf '\n# 扫描时跳过的文件 glob\n'
        for e in "${EXCLUDE_GLOBS[@]}"; do printf 'exclude_glob=%s\n' "$e"; done
    } > "$CONFIG_PATH"
}

# --------------------------- 工具函数 ---------------------------------------
human() {
    local b=${1:-0} i=0 frac=0
    local -a u=(B KB MB GB TB PB)
    while (( b >= 1024 && i < 5 )); do
        frac=$(( (b % 1024) * 10 / 1024 )); b=$(( b / 1024 )); i=$(( i + 1 ))
    done
    if (( i == 0 )); then printf '%d B' "$b"; else printf '%d.%d %s' "$b" "$frac" "${u[i]}"; fi
}

is_protected() {
    local f=$1 p base
    for p in "${PROTECT_DIRS[@]}"; do
        base=${p%/}/
        [[ ${f:0:${#base}} == "$base" ]] && return 0
    done
    return 1
}

is_system_path() {
    local f=$1 p
    for p in "${FM_SYSTEM_PREFIXES[@]}"; do
        [[ $f == "$p" || $f == "$p"/* ]] && return 0
    done
    return 1
}

is_excluded_path() {
    local f=$1 base
    # 目录名组件匹配
    local -a parts
    IFS=/ read -ra parts <<< "${f#/}"
    local part
    for part in "${parts[@]}"; do
        for e in "${EXCLUDE_DIRS[@]}"; do
            [[ $part == "$e" ]] && return 0
        done
    done
    # basename glob 匹配
    base=${f##*/}
    for e in "${EXCLUDE_GLOBS[@]}"; do
        # shellcheck disable=SC2053
        [[ $base == $e ]] && return 0
    done
    return 1
}

cleanup() { [[ -n $WORKDIR && -d $WORKDIR ]] && rm -rf -- "$WORKDIR"; }
_on_exit() { cleanup; tui_cleanup; }

_fdup_write_stats() {
    local w=$1 st=$2 ss=$3 se=$4 sh=$5 kp=$6 ms=$7
    {
        printf 'scan_total=%d\n'    "$st"
        printf 'skip_size=%d\n'     "$ss"
        printf 'skip_exclude=%d\n'  "$se"
        printf 'skip_hardlink=%d\n' "$sh"
        printf 'kept=%d\n'          "$kp"
        printf 'min_size=%d\n'      "$ms"
    } > "$w/stats"
}

# --------------------------- 核心查重 ---------------------------------------
_scan_core() {
    local w=$1 min_size=$MIN_DUP_SIZE
    local P
    P=$(nproc 2>/dev/null || echo 4)
    (( P < 1 )) && P=1
    (( P > 16 )) && P=16

    # 统计
    local scan_total=0 skip_size=0 skip_exclude=0 skip_hardlink=0 kept=0

    echo "扫描文件树..." > "$w/progress"
    find "${SCAN_DIRS[@]}" -type f -printf '%s\t%D\t%i\t%T@\t%p\0' > "$w/list" 2>/dev/null

    # ---- 过滤：排除规则 / 大小 / 硬链接 ----
    echo "过滤候选（排除规则 / 大小 / 硬链接）..." > "$w/progress"
    declare -A dev_ino_count=()
    local entry size dev ino mt path key
    local -a kept_entries=()

    # 第一遍：统计 (dev,inode) 出现次数
    while IFS= read -r -d '' entry; do
        scan_total=$(( scan_total + 1 ))
        size=${entry%%$'\t'*};     entry=${entry#*$'\t'}
        dev=${entry%%$'\t'*};      entry=${entry#*$'\t'}
        ino=${entry%%$'\t'*};      entry=${entry#*$'\t'}
        mt=${entry%%$'\t'*};       path=${entry#*$'\t'}

        if (( size < min_size )); then
            skip_size=$(( skip_size + 1 ))
            continue
        fi
        if is_excluded_path "$path"; then
            skip_exclude=$(( skip_exclude + 1 ))
            continue
        fi

        key="${dev},${ino}"
        dev_ino_count[$key]=$(( ${dev_ino_count[$key]:-0} + 1 ))
        kept_entries+=("$size"$'\t'"$dev"$'\t'"$ino"$'\t'"$mt"$'\t'"$path")
    done < "$w/list"

    # 第二遍：剔除硬链接
    # 只在 inode 有效（非 0/空）且同 (dev,ino) 出现多次时才剔除
    # NTFS/FAT/exFAT 等文件系统 inode 恒为 0，不能当硬链接处理
    : > "$w/filtered"
    local rec skip
    for rec in "${kept_entries[@]}"; do
        size=${rec%%$'\t'*};  rec=${rec#*$'\t'}
        dev=${rec%%$'\t'*};   rec=${rec#*$'\t'}
        ino=${rec%%$'\t'*};   rec=${rec#*$'\t'}
        mt=${rec%%$'\t'*};    path=${rec#*$'\t'}
        key="${dev},${ino}"
        skip=0
        if [[ $ino =~ ^[0-9]+$ ]] && (( ino != 0 )) && (( dev != 0 )); then
            (( ${dev_ino_count[$key]:-0} > 1 )) && skip=1
        fi
        if (( skip )); then
            skip_hardlink=$(( skip_hardlink + 1 ))
            continue
        fi
        kept=$(( kept + 1 ))
        printf '%s\t%s\t%s\t%s\t%s\0' "$size" "$dev" "$ino" "$mt" "$path" >> "$w/filtered"
    done

    # ---- 按大小分组 ----
    echo "统计文件大小..." > "$w/progress"
    declare -A size_count=()
    while IFS= read -r -d '' entry; do
        size=${entry%%$'\t'*}
        size_count[$size]=$(( ${size_count[$size]:-0} + 1 ))
    done < "$w/filtered"

    # ---- 保留大小重复的候选 ----
    echo "筛选候选文件..." > "$w/progress"
    : > "$w/cand"
    while IFS= read -r -d '' entry; do
        size=${entry%%$'\t'*}
        path=${entry#*$'\t'*$'\t'*$'\t'*$'\t'}
        (( ${size_count[$size]:-0} > 1 )) || continue
        printf '%s\0' "$path" >> "$w/cand"
    done < "$w/filtered"

    : > "$w/files.dat"
    if [[ ! -s $w/cand ]]; then
        _fdup_write_stats "$w" "$scan_total" "$skip_size" "$skip_exclude" "$skip_hardlink" "$kept" "$min_size"
        echo "完成" > "$w/progress"; return
    fi

    # ---- 并行计算 MD5 ----
    echo "计算校验和（MD5，${P} 路并行）..." > "$w/progress"
    xargs -0 -r -P "$P" md5sum --zero < "$w/cand" > "$w/hashes" 2>/dev/null

    # ---- 按 MD5 分组 ----
    echo "分组比对..." > "$w/progress"
    declare -A groups=()
    local h p
    while IFS= read -r -d '' rec; do
        h=${rec:0:32}
        p=${rec:34}
        if [[ -n ${groups[$h]+x} ]]; then groups[$h]+=$'\x1f'"$p"; else groups[$h]=$p; fi
    done < "$w/hashes"

    # ---- 建索引：path -> (size, mtime)，供 flag 判定 ----
    declare -A path_size=() path_mtime=()
    while IFS= read -r -d '' entry; do
        size=${entry%%$'\t'*};   entry=${entry#*$'\t'}
        entry=${entry#*$'\t'}    # skip dev
        entry=${entry#*$'\t'}    # skip ino
        mt=${entry%%$'\t'*};     path=${entry#*$'\t'}
        path_size[$path]=$size
        path_mtime[$path]=${mt%.*}
    done < "$w/filtered"

    # ---- 生成结果文件 ----
    echo "生成结果..." > "$w/progress"
    local gid=0 i flag sz mti
    local -a paths
    for h in "${!groups[@]}"; do
        paths=()
        local groupstr=${groups[$h]}
        # 手动以 \x1f 分割，避免 <<< 尾部追加 \n 污染最后一个元素
        while [[ -n $groupstr ]]; do
            if [[ $groupstr == *$'\x1f'* ]]; then
                paths+=("${groupstr%%$'\x1f'*}")
                groupstr=${groupstr#*$'\x1f'}
            else
                paths+=("$groupstr")
                break
            fi
        done
        (( ${#paths[@]} < 2 )) && continue

        gid=$(( gid + 1 ))
        for (( i=0; i<${#paths[@]}; i++ )); do
            p=${paths[i]}
            sz=${path_size[$p]:-0}
            mti=${path_mtime[$p]:-0}
            if is_system_path "$p"; then
                flag=4
            elif is_protected "$p"; then
                flag=1
            else
                flag=0
            fi
            printf '%d\t%d\t%d\t%d\t%s\0' "$gid" "$sz" "$flag" "$mti" "$p" >> "$w/files.dat"
        done
    done

    _fdup_write_stats "$w" "$scan_total" "$skip_size" "$skip_exclude" "$skip_hardlink" "$kept" "$min_size"
    echo "完成" > "$w/progress"
}

# --------------------------- 结果加载 ---------------------------------------
load_results() {
    local file=$1
    RESULT_PATHS=(); RESULT_GIDS=(); RESULT_SIZES=(); RESULT_FLAGS=(); RESULT_TIMES=()
    TUI_ITEMS=(); TUI_STATES=(); TUI_LOCKED=()

    [[ -s $file ]] || return

    local gid size flag mt path prefix size_h
    while IFS=$'\t' read -r -d '' gid size flag mt path; do
        RESULT_GIDS+=("$gid"); RESULT_SIZES+=("$size")
        RESULT_FLAGS+=("$flag"); RESULT_TIMES+=("$mt"); RESULT_PATHS+=("$path")

        size_h=$(human "$size")
        case $flag in
            1) prefix="[保护]" ;;
            3) prefix="[已删]" ;;
            4) prefix="[系统]" ;;
            *) prefix="[可删]" ;;
        esac
        TUI_ITEMS+=("$prefix $size_h  $path")
        TUI_STATES+=(0)
        if (( flag == 0 )); then TUI_LOCKED+=(0); else TUI_LOCKED+=(1); fi
    done < "$file"
}

# --------------------------- 会话保存/加载 ----------------------------------
save_session() {
    _fdup_session_path
    [[ -d $SESSION_DIR ]] || mkdir -p -- "$SESSION_DIR" 2>/dev/null || return
    local tmp="$SESSION_PATH.tmp.$$"

    {
        printf '# fdup session v1\n'
        printf 'version=%s\n' "$VERSION"
        printf 'timestamp=%s\n' "$(date +%s)"
        local d
        for d in "${SCAN_DIRS[@]}"; do printf 'scandir=%s\n' "$d"; done
        for d in "${PROTECT_DIRS[@]}"; do printf 'protectdir=%s\n' "$d"; done
        printf '# end\n'
    } > "$tmp" || return

    local i
    for (( i=0; i<${#RESULT_PATHS[@]}; i++ )); do
        printf '%d\t%d\t%d\t%d\t%s\0' \
            "${RESULT_GIDS[i]}" "${RESULT_SIZES[i]}" "${RESULT_FLAGS[i]}" \
            "${RESULT_TIMES[i]}" "${RESULT_PATHS[i]}" >> "$tmp"
    done
    mv -- "$tmp" "$SESSION_PATH"
}

load_session() {
    _fdup_session_path
    [[ -f $SESSION_PATH ]] || return 1

    SCAN_DIRS=(); PROTECT_DIRS=()
    RESULT_PATHS=(); RESULT_GIDS=(); RESULT_SIZES=(); RESULT_FLAGS=(); RESULT_TIMES=()
    TUI_ITEMS=(); TUI_STATES=(); TUI_LOCKED=()

    local line gid size flag mt path
    # 先读 header
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line == '# end' ]] && break
        case $line in
            scandir=*)   SCAN_DIRS+=("${line#scandir=}") ;;
            protectdir=*) PROTECT_DIRS+=("${line#protectdir=}") ;;
        esac
    done < "$SESSION_PATH"

    # 再读 NUL 分隔的 result 记录（用 tail -c + 偏移不好搞，改用 awk 到 # end 之后）
    # 简化：重新打开文件，跳过头部
    exec 4< "$SESSION_PATH"
    while IFS= read -r -u 4 line; do
        line=${line%$'\r'}
        [[ $line == '# end' ]] && break
    done
    # 后续字节流用 read -d '' 读
    while IFS=$'\t' read -r -u 4 -d '' gid size flag mt path; do
        [[ -z $gid ]] && continue
        RESULT_GIDS+=("$gid"); RESULT_SIZES+=("$size")
        RESULT_FLAGS+=("$flag"); RESULT_TIMES+=("$mt"); RESULT_PATHS+=("$path")
        local prefix size_h; size_h=$(human "$size")
        case $flag in
            1) prefix="[保护]" ;;
            3) prefix="[已删]" ;;
            4) prefix="[系统]" ;;
            *) prefix="[可删]" ;;
        esac
        TUI_ITEMS+=("$prefix $size_h  $path")
        TUI_STATES+=(0)
        if (( flag == 0 )); then TUI_LOCKED+=(0); else TUI_LOCKED+=(1); fi
    done
    exec 4<&-

    RESULT_READY=1
    return 0
}

clear_session() {
    _fdup_session_path
    rm -f -- "$SESSION_PATH" 2>/dev/null
}

# --------------------------- 重新标识 ---------------------------------------
_reflag_results() {
    TUI_REFLAG_CHANGES=0
    (( RESULT_READY )) || return 0
    (( ${#RESULT_PATHS[@]} == 0 )) && return 0

    local i p old new size_h
    for (( i=0; i<${#RESULT_PATHS[@]}; i++ )); do
        old=${RESULT_FLAGS[i]}
        (( old == 3 )) && continue

        p=${RESULT_PATHS[i]}
        size_h=$(human "${RESULT_SIZES[i]}")

        if is_system_path "$p"; then
            new=4; TUI_ITEMS[i]="[系统] $size_h  $p"
        elif is_protected "$p"; then
            new=1; TUI_ITEMS[i]="[保护] $size_h  $p"
        else
            new=0; TUI_ITEMS[i]="[可删] $size_h  $p"
        fi
        RESULT_FLAGS[i]=$new

        if [[ $old != "$new" ]]; then
            TUI_REFLAG_CHANGES=$(( TUI_REFLAG_CHANGES + 1 ))
            TUI_STATES[i]=0
        fi
        if (( new == 0 )); then TUI_LOCKED[i]=0; else TUI_LOCKED[i]=1; fi
    done
}

# --------------------------- 清理空组 ---------------------------------------
_purge_invalid_groups() {
    local -A group_remaining=() group_all_locked=()
    local -a gid_order=()
    local -A seen_gid=()
    local i g

    for (( i=0; i<${#RESULT_GIDS[@]}; i++ )); do
        (( RESULT_FLAGS[i] == 3 )) && continue
        g=${RESULT_GIDS[i]}
        if [[ -z ${seen_gid[$g]:-} ]]; then
            seen_gid[$g]=1
            gid_order+=("$g")
            group_remaining[$g]=""
            group_all_locked[$g]=1
        fi
        group_remaining[$g]+=" $i"
        if (( RESULT_FLAGS[i] != 1 && RESULT_FLAGS[i] != 4 )); then
            group_all_locked[$g]=0
        fi
    done

    local -a new_paths=() new_gids=() new_sizes=() new_flags=() new_times=()
    local -a new_items=() new_states=() new_locked=()
    PURGED_GROUPS=0

    local -a idxs
    local cnt drop j
    for g in "${gid_order[@]}"; do
        idxs=()
        [[ -n ${group_remaining[$g]:-} ]] && read -ra idxs <<< "${group_remaining[$g]}"
        cnt=${#idxs[@]}

        drop=0
        (( cnt <= 1 )) && drop=1
        (( cnt >= 2 )) && (( ${group_all_locked[$g]:-0} == 1 )) && drop=1

        if (( drop )); then
            PURGED_GROUPS=$(( PURGED_GROUPS + 1 ))
            continue
        fi
        for j in "${idxs[@]}"; do
            new_paths+=("${RESULT_PATHS[j]}")
            new_gids+=("${RESULT_GIDS[j]}")
            new_sizes+=("${RESULT_SIZES[j]}")
            new_flags+=("${RESULT_FLAGS[j]}")
            new_times+=("${RESULT_TIMES[j]}")
            new_items+=("${TUI_ITEMS[j]}")
            new_states+=("${TUI_STATES[j]}")
            new_locked+=("${TUI_LOCKED[j]}")
        done
    done

    RESULT_PATHS=("${new_paths[@]}")
    RESULT_GIDS=("${new_gids[@]}")
    RESULT_SIZES=("${new_sizes[@]}")
    RESULT_FLAGS=("${new_flags[@]}")
    RESULT_TIMES=("${new_times[@]}")
    TUI_ITEMS=("${new_items[@]}")
    TUI_STATES=("${new_states[@]}")
    TUI_LOCKED=("${new_locked[@]}")
}

# --------------------------- 保留策略 ---------------------------------------
apply_keep_strategy() {
    if (( ! RESULT_READY )); then tui_msgbox "提示" "请先执行查重。"; return; fi
    if (( ${#RESULT_PATHS[@]} == 0 )); then tui_msgbox "提示" "没有可处理的结果。"; return; fi

    TUI_HEADER=("对每个未受保护的重复组自动勾选，只保留一个副本" \
                "受保护/系统文件所在的组不处理")
    tui_menu "选择保留策略" \
        "保留修改时间最新的" \
        "保留修改时间最旧的" \
        "保留路径最短的" \
        "保留目录层级最浅的" \
        "保留字母序第一个" \
        "← 返回"
    TUI_HEADER=()
    (( $? != 0 )) && return
    local strategy=$TUI_RESULT
    (( strategy == 5 )) && return

    # 按 gid 聚组
    local -A group_members=()
    local -a gid_order=()
    local -A seen=()
    local i g
    for (( i=0; i<${#RESULT_PATHS[@]}; i++ )); do
        (( RESULT_FLAGS[i] == 3 )) && continue
        g=${RESULT_GIDS[i]}
        if [[ -z ${seen[$g]:-} ]]; then seen[$g]=1; gid_order+=("$g"); fi
        group_members[$g]+=" $i"
    done

    local -A path_depth=() path_basename=()
    local p
    for p in "${RESULT_PATHS[@]}"; do
        local tmp=${p//[!\/]/}
        path_depth[$p]=${#tmp}
        path_basename[$p]=${p##*/}
    done

    local total_groups=0 auto_groups=0 skipped_groups=0 picked_files=0
    local -a idxs
    for g in "${gid_order[@]}"; do
        idxs=()
        read -ra idxs <<< "${group_members[$g]}"
        total_groups=$(( total_groups + 1 ))

        # 组内有保护/系统/已删项 -> 跳过
        local has_locked=0
        local j
        for j in "${idxs[@]}"; do
            (( RESULT_FLAGS[j] == 1 || RESULT_FLAGS[j] == 4 || RESULT_FLAGS[j] == 3 )) && has_locked=1
        done
        if (( has_locked )); then
            skipped_groups=$(( skipped_groups + 1 ))
            continue
        fi

        # 按策略排序组成员
        local -a sorted
        case $strategy in
            0) mapfile -t sorted < <(for j in "${idxs[@]}"; do
                    printf '%012d\t%d\n' "${RESULT_TIMES[j]}" "$j"
                done | sort -t $'\t' -k1,1nr | cut -f2) ;;
            1) mapfile -t sorted < <(for j in "${idxs[@]}"; do
                    printf '%012d\t%d\n' "${RESULT_TIMES[j]}" "$j"
                done | sort -t $'\t' -k1,1n  | cut -f2) ;;
            2) mapfile -t sorted < <(for j in "${idxs[@]}"; do
                    printf '%08d\t%d\n' "${#RESULT_PATHS[j]}" "$j"
                done | sort -t $'\t' -k1,1n  | cut -f2) ;;
            3) mapfile -t sorted < <(for j in "${idxs[@]}"; do
                    printf '%08d\t%d\n' "${path_depth[${RESULT_PATHS[j]}]}" "$j"
                done | sort -t $'\t' -k1,1n  | cut -f2) ;;
            4) mapfile -t sorted < <(for j in "${idxs[@]}"; do
                    printf '%s\t%d\n' "${RESULT_PATHS[j]}" "$j"
                done | LC_ALL=C sort -t $'\t' -k1,1 | cut -f2) ;;
        esac

        (( ${#sorted[@]} < 2 )) && continue
        auto_groups=$(( auto_groups + 1 ))
        local k
        for (( k=1; k<${#sorted[@]}; k++ )); do
            j=${sorted[k]}
            (( TUI_LOCKED[j] )) && continue
            if (( TUI_STATES[j] == 0 )); then
                TUI_STATES[j]=1
                picked_files=$(( picked_files + 1 ))
            fi
        done
    done

    tui_msgbox "保留策略已应用" \
        "策略：按选定的排序，每组保留第一个" \
        "处理组数：$auto_groups / 总组数：$total_groups" \
        "跳过组数（含保护/系统文件）：$skipped_groups" \
        "本次勾选：$picked_files 个文件" \
        "可在\"查看结果并选择文件\"里继续调整。"
}

# --------------------------- 导出删除脚本 -----------------------------------
_write_delete_script() {
    local out=$1 count=$2 sort_mode=$3
    shift 3
    local -a indices=("$@")

    {
        printf '#!/usr/bin/env bash\n'
        printf '# ============================================================\n'
        printf '# 文件查重工具 —— 删除脚本\n'
        printf '# 生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# 生成工具: fdup_tui.sh v%s\n' "$VERSION"
        printf '# 条目数量: %d\n' "$count"
        case $sort_mode in
            0) printf '# 排序方式: 按目录\n' ;;
            1) printf '# 排序方式: 按文件大小降序\n' ;;
            *) printf '# 排序方式: 原列表顺序\n' ;;
        esac
        if (( ${#PROTECT_DIRS[@]} > 0 )); then
            printf '# 保护目录（这些目录及其子目录内的文件不应出现在下方）:\n'
            local p
            for p in "${PROTECT_DIRS[@]}"; do printf '#   %s\n' "$p"; done
        fi
        printf '#\n'
        printf '# ⚠ 执行前请逐条核对。rm 无回收站，删除不可撤销。\n'
        printf '# ============================================================\n\n'
        printf 'set -u\n\n'
        printf 'ok=0\nfail=0\nskip=0\n\n'
        printf 'del() {\n'
        printf '    local f=$1\n'
        printf '    if [[ ! -e $f ]]; then\n'
        printf '        printf "[跳过] %%s (不存在)\\n" "$f"\n'
        printf '        skip=$((skip+1))\n'
        printf '        return\n'
        printf '    fi\n'
        printf '    if rm -f -- "$f"; then\n'
        printf '        printf "[删除] %%s\\n" "$f"\n'
        printf '        ok=$((ok+1))\n'
        printf '    else\n'
        printf '        printf "[失败] %%s\\n" "$f" >&2\n'
        printf '        fail=$((fail+1))\n'
        printf '    fi\n'
        printf '}\n\n'

        local prev_dir="" cur_dir i p q
        for i in "${indices[@]}"; do
            p=${RESULT_PATHS[i]}
            if (( sort_mode == 0 )); then
                cur_dir=$(dirname -- "$p")
                if [[ $cur_dir != "$prev_dir" ]]; then
                    printf '\n# --- %s ---\n' "$cur_dir"
                    prev_dir=$cur_dir
                fi
            fi
            printf -v q '%q' "$p"
            printf 'del %s\n' "$q"
        done

        printf '\nprintf "\\n完成: 成功 %%d, 跳过 %%d, 失败 %%d\\n" "$ok" "$skip" "$fail"\n'
    } > "$out"
    return $?
}

export_delete_script() {
    if (( ! RESULT_READY )); then tui_msgbox "提示" "请先执行查重。"; return; fi
    local n=${#TUI_STATES[@]} i
    (( n == 0 )) && { tui_msgbox "提示" "没有可导出的结果。"; return; }

    local n_sel=0
    for (( i=0; i<n; i++ )); do (( TUI_STATES[i] )) && n_sel=$(( n_sel + 1 )); done
    if (( n_sel == 0 )); then
        tui_msgbox "提示" "尚未勾选任何文件。"
        return
    fi

    TUI_HEADER=("已勾选 $n_sel 个文件" "选择脚本中删除条目的排列顺序")
    tui_menu "导出删除脚本" "按目录排序" "按文件大小降序" "按当前列表顺序"
    TUI_HEADER=()
    (( $? != 0 )) && return
    local sort_mode=$TUI_RESULT

    local default_out="$PWD/fdup-delete-$(date +%Y%m%d-%H%M%S).sh"
    tui_input "导出删除脚本" "保存到：" "$default_out" || return
    local out=${TUI_RESULT}
    [[ -z $out ]] && return

    case $out in
        '~')   out=$HOME ;;
        '~/'*) out=$HOME/${out#\~/} ;;
    esac
    [[ $out != /* ]] && out="$PWD/$out"

    local outdir; outdir=$(dirname -- "$out")
    [[ -d $outdir ]] || { tui_msgbox "错误" "目录不存在：$outdir"; return; }
    if [[ -e $out ]]; then
        tui_confirm "覆盖确认" "$out 已存在，是否覆盖？" || return
    fi

    local -a sel_idx=()
    for (( i=0; i<n; i++ )); do (( TUI_STATES[i] )) && sel_idx+=("$i"); done

    local tmp_sort; tmp_sort=$(mktemp) || { tui_msgbox "错误" "临时文件创建失败。"; return; }
    case $sort_mode in
        0) for i in "${sel_idx[@]}"; do printf '%s\t%d\n' "${RESULT_PATHS[i]}" "$i"; done > "$tmp_sort" ;;
        1) for i in "${sel_idx[@]}"; do printf '%020d\t%d\n' "$(( 1000000000000000000 - RESULT_SIZES[i] ))" "$i"; done > "$tmp_sort" ;;
        2) for i in "${sel_idx[@]}"; do printf '%020d\t%d\n' "$i" "$i"; done > "$tmp_sort" ;;
    esac
    mapfile -t sel_idx < <(LC_ALL=C sort -t $'\t' -k1,1 "$tmp_sort" | cut -f2)
    rm -f -- "$tmp_sort"

    if ! _write_delete_script "$out" "$n_sel" "$sort_mode" "${sel_idx[@]}"; then
        tui_msgbox "错误" "写入失败：$out"
        return
    fi
    chmod +x -- "$out" 2>/dev/null

    tui_msgbox "导出成功" \
        "已写入 $n_sel 条删除命令" \
        "文件：$out" \
        "" \
        "请打开该脚本逐条核对，确认无误后再执行。"
}

# --------------------------- 目录与设置菜单 ---------------------------------
add_scan_dir() {
    tui_dirpicker "添加扫描目录" "$PWD" || return
    local d=$TUI_RESULT
    [[ -z $d ]] && return
    [[ -d $d ]] || { tui_msgbox "错误" "目录不存在：$d"; return; }
    local abs; abs=$(realpath -m -- "$d")
    local p
    for p in "${SCAN_DIRS[@]}"; do
        [[ $p == "$abs" ]] && { tui_msgbox "提示" "该目录已在列表中。"; return; }
    done
    SCAN_DIRS+=("$abs")
    RESULT_READY=0
    tui_msgbox "已添加扫描目录" "$abs"
}

add_protect_dir() {
    tui_dirpicker "添加保护目录" "$PWD" || return
    local d=$TUI_RESULT
    [[ -z $d ]] && return
    [[ -d $d ]] || { tui_msgbox "错误" "目录不存在：$d"; return; }
    local abs; abs=$(realpath -m -- "$d")
    local p
    for p in "${PROTECT_DIRS[@]}"; do
        [[ $p == "$abs" ]] && { tui_msgbox "提示" "该目录已在列表中。"; return; }
    done
    PROTECT_DIRS+=("$abs")

    if (( RESULT_READY )); then
        _reflag_results
        tui_msgbox "已添加保护目录" "$abs" "" \
            "已对现有结果重新标识：$TUI_REFLAG_CHANGES 项状态发生变化。"
    else
        tui_msgbox "已添加保护目录" "$abs"
    fi
}

manage_dirs() {
    while :; do
        local -a labels=()
        local i
        for (( i=0; i<${#SCAN_DIRS[@]}; i++ ));    do labels+=("[扫描] ${SCAN_DIRS[i]}");    done
        for (( i=0; i<${#PROTECT_DIRS[@]}; i++ )); do labels+=("[保护] ${PROTECT_DIRS[i]}"); done

        if (( ${#labels[@]} == 0 )); then
            tui_msgbox "目录列表" "尚未添加任何目录。"
            return
        fi
        labels+=("← 返回")

        TUI_HEADER=("选择一项即可移除它" "扫描目录用于查找，保护目录内的文件不会被删")
        tui_menu "目录列表" "${labels[@]}"
        TUI_HEADER=()
        (( $? != 0 )) && return

        local sel=$TUI_RESULT
        local ns=${#SCAN_DIRS[@]} np=${#PROTECT_DIRS[@]}
        (( sel == ns + np )) && return

        local target="${labels[sel]}"
        tui_confirm "移除目录" "确定移除：$target ？" || continue

        if (( sel < ns )); then
            local removed=${SCAN_DIRS[sel]}
            local -a new=()
            for (( i=0; i<ns; i++ )); do (( i == sel )) && continue; new+=("${SCAN_DIRS[i]}"); done
            SCAN_DIRS=("${new[@]}")
            RESULT_READY=0
            tui_msgbox "已移除扫描目录" "$removed" "" \
                "扫描范围已变更，请重新查重（原有结果已失效）。"
        else
            local idx=$(( sel - ns ))
            local removed=${PROTECT_DIRS[idx]}
            local -a new=()
            for (( i=0; i<np; i++ )); do (( i == idx )) && continue; new+=("${PROTECT_DIRS[i]}"); done
            PROTECT_DIRS=("${new[@]}")
            if (( RESULT_READY )); then
                _reflag_results
                tui_msgbox "已移除保护目录" "$removed" "" \
                    "已对现有结果重新标识：$TUI_REFLAG_CHANGES 项状态发生变化。"
            else
                tui_msgbox "已移除保护目录" "$removed"
            fi
        fi
    done
}

settings_menu() {
    while :; do
        TUI_HEADER=("最小大小: $(human $MIN_DUP_SIZE)" \
                    "排除目录: ${#EXCLUDE_DIRS[@]} 个   排除 glob: ${#EXCLUDE_GLOBS[@]} 个")
        tui_menu "设置" \
            "设置最小文件大小" \
            "管理排除目录" \
            "管理排除 glob" \
            "← 返回"
        TUI_HEADER=()
        (( $? != 0 )) && return
        case $TUI_RESULT in
            0) settings_min_size ;;
            1) settings_exclude_dirs ;;
            2) settings_exclude_globs ;;
            3) return ;;
        esac
    done
}

settings_min_size() {
    tui_input "最小文件大小" "字节数（小于此值不参与查重）：" "$MIN_DUP_SIZE" || return
    local v=${TUI_RESULT// /}
    [[ $v =~ ^[0-9]+$ ]] || { tui_msgbox "错误" "请输入非负整数。"; return; }
    MIN_DUP_SIZE=$v
    fdup_config_save
    RESULT_READY=0
    tui_msgbox "已保存" "最小文件大小设为 $(human $MIN_DUP_SIZE)（$MIN_DUP_SIZE 字节）" \
        "" "已有结果已失效，请重新查重。"
}

settings_exclude_dirs() {
    while :; do
        local -a labels=()
        local e
        for e in "${EXCLUDE_DIRS[@]}"; do labels+=("[目录] $e"); done
        labels+=("+ 添加" "← 返回")
        TUI_HEADER=("共 ${#EXCLUDE_DIRS[@]} 个排除目录" "匹配任意路径组件（精确名称）")
        tui_menu "排除目录" "${labels[@]}"
        TUI_HEADER=()
        (( $? != 0 )) && return
        local sel=$TUI_RESULT
        local n=${#EXCLUDE_DIRS[@]}
        if (( sel == n )); then
            tui_input "添加排除目录" "目录名（如 node_modules）：" "" || continue
            local v=${TUI_RESULT// /}
            [[ -z $v ]] && continue
            EXCLUDE_DIRS+=("$v")
            fdup_config_save
            RESULT_READY=0
        elif (( sel == n + 1 )); then
            return
        else
            tui_confirm "移除" "确定移除排除目录：${EXCLUDE_DIRS[sel]} ？" || continue
            local -a new=()
            local i
            for (( i=0; i<n; i++ )); do (( i == sel )) && continue; new+=("${EXCLUDE_DIRS[i]}"); done
            EXCLUDE_DIRS=("${new[@]}")
            fdup_config_save
            RESULT_READY=0
        fi
    done
}

settings_exclude_globs() {
    while :; do
        local -a labels=()
        local e
        for e in "${EXCLUDE_GLOBS[@]}"; do labels+=("[glob] $e"); done
        labels+=("+ 添加" "← 返回")
        TUI_HEADER=("共 ${#EXCLUDE_GLOBS[@]} 个排除 glob" "按 basename 匹配")
        tui_menu "排除 glob" "${labels[@]}"
        TUI_HEADER=()
        (( $? != 0 )) && return
        local sel=$TUI_RESULT
        local n=${#EXCLUDE_GLOBS[@]}
        if (( sel == n )); then
            tui_input "添加排除 glob" "模式（如 *.tmp）：" "" || continue
            local v=${TUI_RESULT// /}
            [[ -z $v ]] && continue
            EXCLUDE_GLOBS+=("$v")
            fdup_config_save
            RESULT_READY=0
        elif (( sel == n + 1 )); then
            return
        else
            tui_confirm "移除" "确定移除排除 glob：${EXCLUDE_GLOBS[sel]} ？" || continue
            local -a new=()
            local i
            for (( i=0; i<n; i++ )); do (( i == sel )) && continue; new+=("${EXCLUDE_GLOBS[i]}"); done
            EXCLUDE_GLOBS=("${new[@]}")
            fdup_config_save
            RESULT_READY=0
        fi
    done
}

# --------------------------- 查重 -------------------------------------------
run_scan() {
    if (( ${#SCAN_DIRS[@]} == 0 )); then
        tui_msgbox "提示" "请先添加至少一个扫描目录。"; return
    fi

    [[ -n $WORKDIR && -d $WORKDIR ]] && rm -rf -- "$WORKDIR"
    WORKDIR=$(mktemp -d) || { tui_msgbox "错误" "无法创建临时目录。"; return; }

    _scan_core "$WORKDIR" >/dev/null 2>&1 &
    local pid=$!

    tui_size
    local w=72 h=6 top left
    (( w > TUI_COLS - 2 )) && w=$(( TUI_COLS - 2 ))
    top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
    left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1

    local inner=$(( w - 4 ))
    local col=$(( left + 2 ))
    local row_step=$(( top + 1 ))
    local row_hint=$(( top + 3 ))

    tui_box "$top" "$left" "$h" "$w" "文件查重"
    tui_puts_pad "$row_hint" "$col" "$inner" "$TUI_FG_GRAY" \
        "  | 请稍候，长目录可能需要一些时间..."
    tui_hide_cursor

    local -a spin=('|' '/' '-' '\')
    local i=0 last_step=$'\x01' step
    local spin_col=$(( col + 2 ))

    while kill -0 "$pid" 2>/dev/null; do
        step="处理中..."
        [[ -f "$WORKDIR/progress" ]] && step=$(<"$WORKDIR/progress")
        if [[ $step != "$last_step" ]]; then
            tui_puts_pad "$row_step" "$col" "$inner" "" "$step"
            last_step=$step
        fi
        tui_at "$row_hint" "$spin_col"
        printf '%s' "${spin[i]}"
        i=$(( (i + 1) % 4 ))
        sleep 0.12
    done
    wait "$pid"

    tui_puts_pad "$row_step" "$col" "$inner" "$TUI_FG_GREEN" "完成"
    tui_puts_pad "$row_hint" "$col" "$inner" "$TUI_FG_GRAY" "  已完成。"

    load_results "$WORKDIR/files.dat"
    RESULT_READY=1

    # ---- 读取统计 ----
    local scan_total=0 skip_size=0 skip_exclude=0 skip_hardlink=0 kept=0 stat_min=$MIN_DUP_SIZE
    if [[ -f $WORKDIR/stats ]]; then
        local sk sv
        while IFS='=' read -r sk sv; do
            case $sk in
                scan_total)    scan_total=$sv ;;
                skip_size)     skip_size=$sv ;;
                skip_exclude)  skip_exclude=$sv ;;
                skip_hardlink) skip_hardlink=$sv ;;
                kept)          kept=$sv ;;
                min_size)      stat_min=$sv ;;
            esac
        done < "$WORKDIR/stats"
    fi
    local skip_total=$(( skip_size + skip_exclude + skip_hardlink ))

    local n=${#RESULT_PATHS[@]} deletable=0 groups=0 last=-1 k
    for (( k=0; k<n; k++ )); do
        (( RESULT_FLAGS[k] == 0 )) && deletable=$(( deletable + 1 ))
        if (( RESULT_GIDS[k] != last )); then groups=$(( groups + 1 )); last=${RESULT_GIDS[k]}; fi
    done

    if (( n > 0 )); then
        save_session
    fi

    local extra=""
    if (( ${#PROTECT_DIRS[@]} == 0 )); then
        extra="（未设置保护目录：所有副本均可选）"
    fi

    local skip_detail="小于 $(human "$stat_min"): $skip_size / 排除规则: $skip_exclude / 硬链接: $skip_hardlink"

    tui_msgbox "查重完成" \
        "扫描文件总数：$scan_total" \
        "按规则忽略：$skip_total（$skip_detail）" \
        "参与查重：$kept" \
        "发现重复组：$groups" \
        "重复候选文件：$n" \
        "其中可删除：$deletable" \
        "$extra"
}

# --------------------------- 结果选择与删除 ---------------------------------
select_files() {
    if (( ! RESULT_READY )); then tui_msgbox "提示" "请先执行查重。"; return; fi
    if (( ${#TUI_ITEMS[@]} == 0 )); then tui_msgbox "提示" "没有可显示的结果。"; return; fi
    tui_checklist "选择要删除的文件" || return
}

batch_select() {
    if (( ! RESULT_READY )); then tui_msgbox "提示" "请先执行查重。"; return; fi

    local -A gid_has_protect=()
    local i
    for (( i=0; i<${#RESULT_GIDS[@]}; i++ )); do
        if (( RESULT_FLAGS[i] == 1 || RESULT_FLAGS[i] == 4 )); then
            gid_has_protect[${RESULT_GIDS[i]}]=1
        fi
    done

    if (( ${#gid_has_protect[@]} == 0 )); then
        if (( ${#PROTECT_DIRS[@]} == 0 )); then
            tui_msgbox "提示" \
                "尚未设置保护目录，无可批量选择的对象。" \
                "请先在\"添加保护目录\"中指定保护目录。"
        else
            tui_msgbox "提示" \
                "没有发现含有保护文件的重复组。" \
                "保护目录内的文件均未找到重复副本。"
        fi
        return
    fi

    local count=0
    for (( i=0; i<${#RESULT_PATHS[@]}; i++ )); do
        (( ${TUI_LOCKED[i]:-0} )) && continue
        [[ -n ${gid_has_protect[${RESULT_GIDS[i]}]:-} ]] || continue
        if (( ${TUI_STATES[i]:-0} == 0 )); then
            TUI_STATES[i]=1
            count=$(( count + 1 ))
        fi
    done

    if (( count == 0 )); then
        tui_msgbox "提示" "没有新的可勾选文件。"
    else
        tui_msgbox "已批量勾选" \
            "共勾选 $count 个保护目录外的重复副本。" \
            "这些副本所在组内均至少有一个保护文件。" \
            "返回主菜单可继续调整。"
    fi
}

do_delete() {
    if (( ! RESULT_READY )); then tui_msgbox "提示" "请先执行查重。"; return; fi
    local i count=0
    for (( i=0; i<${#TUI_STATES[@]}; i++ )); do (( TUI_STATES[i] )) && count=$(( count + 1 )); done
    if (( count == 0 )); then tui_msgbox "提示" "没有勾选任何文件。"; return; fi

    tui_confirm "确认删除" "确定删除 $count 个文件？此操作不可撤销。" || return

    local ok=0 fail=0
    for (( i=0; i<${#TUI_STATES[@]}; i++ )); do
        (( TUI_STATES[i] )) || continue
        if rm -f -- "${RESULT_PATHS[i]}" 2>/dev/null; then
            ok=$(( ok + 1 ))
            RESULT_FLAGS[i]=3
            TUI_STATES[i]=0
            TUI_LOCKED[i]=1
            TUI_ITEMS[i]="[已删] ${RESULT_PATHS[i]}"
        else
            fail=$(( fail + 1 ))
        fi
    done

    _purge_invalid_groups
    save_session

    local extra=""
    (( PURGED_GROUPS > 0 )) && extra="已移除 $PURGED_GROUPS 个不再重复的组。"

    tui_msgbox "完成" \
        "成功删除 $ok 个，失败 $fail 个。" \
        "$extra"
}

# --------------------------- 关于 -------------------------------------------
about_dialog() {
    local -a lines=(
        "文件查重工具 fdup_tui.sh"
        "版本: $VERSION"
        ""
        "基于 tui.sh 文本图形界面引擎"
        "纯 Bash 实现，不依赖第三方程序"
        ""
        "变更记录:"
    )
    local c
    for c in "${CHANGELOG[@]}"; do lines+=("  $c"); done

    tui_msgbox "关于" "${lines[@]}"
}

# --------------------------- 退出确认 ---------------------------------------
confirm_exit() {
    if (( ! RESULT_READY )) || (( ${#RESULT_PATHS[@]} == 0 )); then
        return 0
    fi

    local i n_sel=0
    local -A gid_alive=()
    for (( i=0; i<${#RESULT_PATHS[@]}; i++ )); do
        (( RESULT_FLAGS[i] == 3 )) && continue
        gid_alive[${RESULT_GIDS[i]}]=1
        (( TUI_STATES[i] )) && n_sel=$(( n_sel + 1 ))
    done
    local n_dup=${#gid_alive[@]}
    (( n_dup == 0 )) && return 0

    local text
    if (( n_sel > 0 )); then
        text="有 $n_sel 个文件已勾选未处理，共 $n_dup 组重复待处理。确定退出？"
    else
        text="当前有 $n_dup 组重复结果尚未处理，确定退出？"
    fi

    tui_confirm "确认退出" "$text"
}

# --------------------------- 主菜单 -----------------------------------------
main_menu() {
    TUI_HEADER=(
        "扫描目录: ${#SCAN_DIRS[@]}    保护目录: ${#PROTECT_DIRS[@]}    最小大小: $(human $MIN_DUP_SIZE)"
    )
    if (( RESULT_READY )); then
        local sel=0 i
        for (( i=0; i<${#TUI_STATES[@]}; i++ )); do (( TUI_STATES[i] )) && sel=$(( sel + 1 )); done
        TUI_HEADER+=("结果: ${#TUI_ITEMS[@]} 个文件，已勾选 $sel 个")
    else
        TUI_HEADER+=("结果: 尚未执行查重")
    fi

    tui_menu "文件查重工具 V$VERSION" \
        "添加扫描目录" \
        "添加保护目录" \
        "查看 / 移除目录" \
        "开始查重" \
        "查看结果并选择文件" \
        "批量选择保护目录外的可删文件" \
        "按策略自动选择保留项" \
        "执行删除" \
        "导出删除脚本" \
        "设置" \
        "关于" \
        "退出"
}

# --------------------------- 启动时恢复会话 ---------------------------------
try_restore_session() {
    _fdup_session_path
    [[ -f $SESSION_PATH ]] || return 1

    # 先试探性加载，看有没有数据
    load_session || return 1
    (( ${#RESULT_PATHS[@]} == 0 )) && { clear_session; RESULT_READY=0; return 1; }

    local n_dup_groups=0
    local -A g=()
    local i
    for (( i=0; i<${#RESULT_PATHS[@]}; i++ )); do
        (( RESULT_FLAGS[i] == 3 )) && continue
        g[${RESULT_GIDS[i]}]=1
    done
    n_dup_groups=${#g[@]}

    local ts
    ts=$(grep '^timestamp=' "$SESSION_PATH" 2>/dev/null | head -1)
    ts=${ts#timestamp=}
    local when="未知时间"
    if [[ $ts =~ ^[0-9]+$ ]]; then
        when=$(date -d "@$ts" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$ts")
    fi

    if tui_confirm "恢复上次查重结果" \
        "$when 的查重结果：$n_dup_groups 组重复，共 ${#RESULT_PATHS[@]} 个文件。是否恢复？"
    then
        return 0
    else
        SCAN_DIRS=(); PROTECT_DIRS=()
        RESULT_PATHS=(); RESULT_GIDS=(); RESULT_SIZES=(); RESULT_FLAGS=(); RESULT_TIMES=()
        TUI_ITEMS=(); TUI_STATES=(); TUI_LOCKED=()
        RESULT_READY=0
        clear_session
        return 1
    fi
}

main() {
    fdup_config_load
    _fdup_session_path

    tui_init
    trap '_on_exit' EXIT
    trap '_on_exit; exit 130' INT TERM

    try_restore_session || true

    while :; do
        if main_menu; then
            case $TUI_RESULT in
                0) add_scan_dir ;;
                1) add_protect_dir ;;
                2) manage_dirs ;;
                3) run_scan ;;
                4) select_files ;;
                5) batch_select ;;
                6) apply_keep_strategy ;;
                7) do_delete ;;
                8) export_delete_script ;;
                9) settings_menu ;;
                10) about_dialog ;;
                11) confirm_exit && break ;;
            esac
        else
            break
        fi
    done
}

main "$@"