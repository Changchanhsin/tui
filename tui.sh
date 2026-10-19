#!/usr/bin/env bash
# ============================================================================
# tui.sh —— 纯 Bash 文本图形界面引擎（可复用组件库） powered by deepseed
# ----------------------------------------------------------------------------
# 依赖: bash 4.3+ / GNU coreutils (stty, printf)
# 用法:
#     source /path/to/tui.sh
#     tui_init
#     tui_menu "标题" "项1" "项2" ...
#     # 退出前调用 tui_cleanup（或自己 trap EXIT）
#
# 组件:
#     tui_msgbox    TITLE LINE...              消息框
#     tui_confirm   TITLE TEXT                 确认框 (Y/N)
#     tui_input     TITLE PROMPT [DEFAULT]     输入框  -> TUI_RESULT
#     tui_menu      TITLE ITEM...              菜单    -> TUI_RESULT=索引
#     tui_checklist TITLE                      复选表  -> TUI_ITEMS/STATES/LOCKED
#     tui_dirpicker TITLE [PATH]               目录选择器 -> TUI_RESULT
# 辅助:
#     tui_sep       ROW LEFT WIDTH             水平分隔线
#     tui_tail_fit  STRING MAXWIDTH            尾部截断 -> TUI_TRUNC
#
# 说明:
#     - 使用备用屏幕，退出后终端原样恢复
#     - 自动处理中英文混排宽度，框线对齐
#
# ----------------------------------------------------------------------------
# sed -i 's/\r$//' tui.sh
# ============================================================================

[[ -n ${TUI_LOADED:-} ]] && return 0
TUI_LOADED=1

# ------------------------------- 样式 ---------------------------------------
TUI_RST=$'\e[0m'
TUI_BOLD=$'\e[1m'
TUI_DIM=$'\e[2m'
TUI_REV=$'\e[7m'
TUI_FG_RED=$'\e[31m'
TUI_FG_GREEN=$'\e[32m'
TUI_FG_YELLOW=$'\e[33m'
TUI_FG_BLUE=$'\e[34m'
TUI_FG_CYAN=$'\e[36m'
TUI_FG_GRAY=$'\e[37m'

# ============================================================================
# 颜色方案管理
# ============================================================================
# tui.sh 自身所在目录（用于查找 tui.configure）
TUI_SELF_DIR=""
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
    TUI_SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
fi

# 当前生效的颜色转义序列（空 = 使用终端默认）
TUI_C_TEXT=""
TUI_C_BG=""
TUI_C_BORDER=""
TUI_C_TITLE=""
TUI_C_HINT="$TUI_FG_GRAY"
TUI_C_SELECT="$TUI_REV$TUI_FG_CYAN"

TUI_CUR_SCHEME=1
TUI_CFG_COUNT=1
declare -A TUI_SCHEME_NAME=()
declare -A TUI_SCHEME_SYSTEM=()
declare -A TUI_SCHEME_TEXT=()
declare -A TUI_SCHEME_BG=()
declare -A TUI_SCHEME_BORDER=()
declare -A TUI_SCHEME_TITLE=()
declare -A TUI_SCHEME_HINT=()
declare -A TUI_SCHEME_SELECT=()

# 配置文件路径：环境变量 > 脚本目录 > ~/.config/tui/
tui_config_path() {
    if [[ -n ${TUI_CONFIG:-} ]]; then
        printf '%s' "$TUI_CONFIG"; return
    fi
    if [[ -n $TUI_SELF_DIR && -w $TUI_SELF_DIR ]]; then
        printf '%s/tui.configure' "$TUI_SELF_DIR"; return
    fi
    local base=${XDG_CONFIG_HOME:-$HOME/.config}
    printf '%s/tui/tui.configure' "$base"
}

tui_config_write_default() {
    local path=$1 dir
    dir=${path%/*}
    [[ -d $dir ]] || mkdir -p -- "$dir" 2>/dev/null
    cat > "$path" <<'EOF'
# tui.configure — TUI 界面配色方案
#
# 每行 key=value。颜色值 = SGR 参数（不含 ESC[ 和结尾 m），分号分隔。
# 例如 "1;37" 表示粗体白，"7;36" 表示反显青。
# 留空表示"跟随系统/终端"。
#
# 字段含义:
#   text    客户区文字前景
#   bg      客户区背景
#   border  边框前景
#   title   标题文字前景
#   hint    提示/功能区文字前景
#   select  选中项样式（通常是反显 + 强调色）
#
# current = 启动时使用的方案编号
# 运行时按数字键 1-9 或 Ctrl+1..9 即时切换

current=1
count=1

scheme.1.name=System
scheme.1.system=1
EOF
}

tui_config_load() {
    local path=$1 line key val idx field i
    TUI_CFG_COUNT=0
    TUI_CUR_SCHEME=1
    TUI_SCHEME_NAME=(); TUI_SCHEME_SYSTEM=()
    TUI_SCHEME_TEXT=(); TUI_SCHEME_BG=()
    TUI_SCHEME_BORDER=(); TUI_SCHEME_TITLE=()
    TUI_SCHEME_HINT=(); TUI_SCHEME_SELECT=()

    [[ -f $path ]] || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ -z $line || ${line:0:1} == '#' ]] && continue
        key=${line%%=*}
        val=${line#*=}
        case $key in
            current) TUI_CUR_SCHEME=$val ;;
            count)   TUI_CFG_COUNT=$val ;;
            scheme.*)
                idx=${key#scheme.}
                field=${idx#*.}
                idx=${idx%%.*}
                [[ $idx =~ ^[1-9]$ ]] || continue
                case $field in
                    name)   TUI_SCHEME_NAME[$idx]=$val ;;
                    system) TUI_SCHEME_SYSTEM[$idx]=$val ;;
                    text)   TUI_SCHEME_TEXT[$idx]=$val ;;
                    bg)     TUI_SCHEME_BG[$idx]=$val ;;
                    border) TUI_SCHEME_BORDER[$idx]=$val ;;
                    title)  TUI_SCHEME_TITLE[$idx]=$val ;;
                    hint)   TUI_SCHEME_HINT[$idx]=$val ;;
                    select) TUI_SCHEME_SELECT[$idx]=$val ;;
                esac ;;
        esac
    done < "$path"

    # 补全：有 name 才算一个有效方案；无 name 的填默认
    local cnt=0
    for i in 1 2 3 4 5 6 7 8 9; do
        if [[ -n ${TUI_SCHEME_NAME[$i]:-} ]]; then
            cnt=$(( cnt + 1 ))
        fi
    done
    (( cnt == 0 )) && { TUI_CFG_COUNT=1; TUI_SCHEME_NAME[1]="System"; TUI_SCHEME_SYSTEM[1]=1; cnt=1; }
    TUI_CFG_COUNT=$cnt
    (( TUI_CUR_SCHEME < 1 || TUI_CUR_SCHEME > 9 )) && TUI_CUR_SCHEME=1
    return 0
}

# 只重写 current= 行
tui_config_save() {
    local path=$1 n=$2
    [[ -f $path && -w $path ]] || return 1
    if grep -q '^current=' "$path" 2>/dev/null; then
        sed -i "s/^current=.*/current=$n/" "$path"
    else
        printf 'current=%d\n' "$n" >> "$path"
    fi
}

# SGR 参数 -> 完整转义序列；空参数返回空
tui_sgr() {
    local p=$1
    [[ -z $p ]] && return
    printf '\e[%sm' "$p"
}

tui_apply_scheme() {
    local n=$1
    [[ -n ${TUI_SCHEME_NAME[$n]:-} ]] || return 1

    if [[ ${TUI_SCHEME_SYSTEM[$n]:-0} == 1 ]]; then
        TUI_C_TEXT=""
        TUI_C_BG=""
        TUI_C_BORDER=""
        TUI_C_TITLE=""
        TUI_C_HINT="$TUI_FG_GRAY"
        TUI_C_SELECT="$TUI_REV$TUI_FG_CYAN"
    else
        TUI_C_TEXT=$(tui_sgr "${TUI_SCHEME_TEXT[$n]:-}")
        TUI_C_BG=$(tui_sgr "${TUI_SCHEME_BG[$n]:-}")
        TUI_C_BORDER=$(tui_sgr "${TUI_SCHEME_BORDER[$n]:-}")
        TUI_C_TITLE=$(tui_sgr "${TUI_SCHEME_TITLE[$n]:-}")
        TUI_C_HINT=$(tui_sgr "${TUI_SCHEME_HINT[$n]:-}")
        TUI_C_SELECT=$(tui_sgr "${TUI_SCHEME_SELECT[$n]:-}")
        # 背景追加到所有"客户区"样式上：内容行、提示行、边框、标题
        # SELECT 不加：反显（SGR 7）本身就是交换前后景，再叠加背景会语义混乱
        if [[ -n $TUI_C_BG ]]; then
            TUI_C_TEXT+="$TUI_C_BG"
            TUI_C_HINT+="$TUI_C_BG"
            TUI_C_BORDER+="$TUI_C_BG"
            TUI_C_TITLE+="$TUI_C_BG"
        fi
    fi
    TUI_CUR_SCHEME=$n
    return 0
}

# 若当前 TUI_KEY 是方案切换键，则应用并返回 0；否则返回 1。
# 使用后调用方应重新计算布局、清屏、全量重绘。
tui_check_scheme_key() {
    local n=""
    case $TUI_KEY in
        [1-9])          n=$TUI_KEY ;;
        SCHEME_[1-9])   n=${TUI_KEY#SCHEME_} ;;
        *) return 1 ;;
    esac
    (( n > TUI_CFG_COUNT )) && return 1
    (( n == TUI_CUR_SCHEME )) && return 1
    tui_apply_scheme "$n" || return 1
    return 0
}

# ----------------------------- 全局状态 -------------------------------------
TUI_ROWS=24
TUI_COLS=80
TUI_INITED=0
TUI_ORIG_STTY=""
TUI_TTY=""

TUI_RESULT=""      # 通用返回值
TUI_W=0            # tui_strwidth 的结果
TUI_TRUNC=""       # tui_trunc 的结果
TUI_KEY=""         # 最近一次按键 (UP/DOWN/LEFT/RIGHT/ENTER/ESC/SPACE/...)
TUI_RESIZED=0      # WINCH 标记，非 0 时 tui_readkey 返回 RESIZE

declare -a TUI_HEADER=()   # tui_menu 可选头部行
declare -a TUI_ITEMS=()    # tui_checklist 输入项
declare -a TUI_STATES=()   # tui_checklist 勾选状态 0/1
declare -a TUI_LOCKED=()   # tui_checklist 锁定标记 0/1（1 = 不可勾选）

# ---------------------------------------------------------------------------
# 内部工具
# ---------------------------------------------------------------------------
_tui_detect_tty() {
    if [[ -r /dev/tty && -w /dev/tty ]]; then TUI_TTY=/dev/tty; else TUI_TTY=/dev/stdin; fi
}

# 码点 -> 显示宽度 (TUI_CW = 1 或 2)
_tui_cp2w() {
    local cp=$1
    if (( (cp >= 0x1100 && cp <= 0x115F) || (cp >= 0x2E80 && cp <= 0x303E) ||
           (cp >= 0x3041 && cp <= 0x33FF) || (cp >= 0x3400 && cp <= 0x4DBF) ||
           (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xA000 && cp <= 0xA4CF) ||
           (cp >= 0xAC00 && cp <= 0xD7A3) || (cp >= 0xF900 && cp <= 0xFAFF) ||
           (cp >= 0xFE10 && cp <= 0xFE19) || (cp >= 0xFE30 && cp <= 0xFE6F) ||
           (cp >= 0xFF00 && cp <= 0xFF60) || (cp >= 0xFFE0 && cp <= 0xFFE6) ||
           (cp >= 0x1F300 && cp <= 0x1F64F) || (cp >= 0x20000 && cp <= 0x3FFFD) )); then
        TUI_CW=2
    else
        TUI_CW=1
    fi
}

# ---------------------------------------------------------------------------
# 初始化 / 清理 / 尺寸
# ---------------------------------------------------------------------------
tui_init() {
    (( TUI_INITED )) && return 0
    _tui_detect_tty
    TUI_ORIG_STTY=$(stty -g < "$TUI_TTY" 2>/dev/null || true)
    stty -echo -icanon min 1 time 0 < "$TUI_TTY" 2>/dev/null || true
    printf '\e[?1049h\e[2J\e[H\e[?25l'
    trap 'TUI_RESIZED=1' WINCH      # ← 新增：终端尺寸变化标记
    TUI_INITED=1
    tui_size

    # 载入颜色方案配置；不存在时生成默认文件
    local cfg; cfg=$(tui_config_path)
    [[ -f $cfg ]] || tui_config_write_default "$cfg"
    tui_config_load "$cfg"
    tui_apply_scheme "${TUI_CUR_SCHEME:-1}" || tui_apply_scheme 1
}

tui_cleanup() {
    (( TUI_INITED )) || return 0
    local cfg; cfg=$(tui_config_path)
    [[ -f $cfg ]] && tui_config_save "$cfg" "$TUI_CUR_SCHEME"
    trap - WINCH
    printf '\e[?25h\e[?1049l'
    [[ -n $TUI_ORIG_STTY ]] && stty "$TUI_ORIG_STTY" < "$TUI_TTY" 2>/dev/null
    TUI_INITED=0
}

tui_size() {
    local s=""
    [[ -n $TUI_TTY ]] && s=$(stty size < "$TUI_TTY" 2>/dev/null || true)
    if [[ -n $s ]]; then
        TUI_ROWS=${s% *}; TUI_COLS=${s#* }
    else
        TUI_ROWS=${LINES:-24}; TUI_COLS=${COLUMNS:-80}
    fi
    (( TUI_ROWS < 10 )) && TUI_ROWS=10
    (( TUI_COLS < 40 )) && TUI_COLS=40
}

# ---------------------------------------------------------------------------
# 输出原语
# ---------------------------------------------------------------------------
tui_at() { printf '\e[%d;%dH' "$1" "$2"; }
tui_clear() { printf '\e[2J\e[H'; }
tui_show_cursor() { printf '\e[?25h'; }
tui_hide_cursor() { printf '\e[?25l'; }

# 计算字符串显示宽度 -> TUI_W
tui_strwidth() {
    local s=${1:-}
    local w=0 i n=${#s} ch cp
    for (( i=0; i<n; i++ )); do
        ch=${s:i:1}
        printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
        _tui_cp2w "$cp"
        w=$(( w + TUI_CW ))
    done
    TUI_W=$w
}

# 按显示宽度截断 -> TUI_TRUNC
tui_trunc() {
    local s=${1:-} max=${2:-0}
    local w=0 i n=${#s} ch cp out=""
    for (( i=0; i<n; i++ )); do
        ch=${s:i:1}
        printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
        _tui_cp2w "$cp"
        (( w + TUI_CW > max )) && break
        out+=$ch
        w=$(( w + TUI_CW ))
    done
    TUI_TRUNC=$out
}

# ---------------------------------------------------------------------------
# 绘制
# ---------------------------------------------------------------------------
# tui_box TOP LEFT HEIGHT WIDTH [TITLE]
tui_box() {
    local top=$1 left=$2 h=$3 w=$4 title=${5:-}
    local i tw=0 inner=$(( w - 2 ))

    # 清空矩形（用客户区背景铺底）
    local blanks tmp buf
    printf -v blanks '%*s' "$w" ''
    printf -v buf '\e[%d;%dH%s%s%s' "$top" "$left" "$TUI_C_TEXT" "$blanks" "$TUI_RST"
    for (( i=1; i<h; i++ )); do
        printf -v tmp '\e[1B\e[%dG%s%s%s' "$left" "$TUI_C_TEXT" "$blanks" "$TUI_RST"
        buf+=$tmp
    done
    printf '%s' "$buf"

    # 上边框
    tui_at "$top" "$left"
    if [[ -n $title ]]; then
        tui_strwidth "$title"; tw=$TUI_W
        if (( tw + 2 + 5 > w )); then
            tui_trunc "$title" $(( w - 7 )); title=$TUI_TRUNC
            tui_strwidth "$title"; tw=$TUI_W
        fi
        local tail_bar="" k
        for (( k=0; k < w - tw - 7; k++ )); do tail_bar+="─"; done
        printf '%s┌─[ %s%s%s ]%s┐%s' \
            "$TUI_C_BORDER" \
            "$TUI_RST$TUI_C_TITLE" "$title" \
            "$TUI_RST$TUI_C_BORDER" \
            "$tail_bar" "$TUI_RST"
    else
        local bar=""
        for (( k=0; k<inner; k++ )); do bar+="─"; done
        printf '%s┌%s┐%s' "$TUI_C_BORDER" "$bar" "$TUI_RST"
    fi

    # 左右边框
    for (( i=1; i<h-1; i++ )); do
        printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
            $(( top + i )) "$left" "$TUI_C_BORDER" "$TUI_RST" \
            $(( top + i )) $(( left + w - 1 )) "$TUI_C_BORDER" "$TUI_RST"
    done

    # 下边框
    local bar2=""
    for (( i=0; i<inner; i++ )); do bar2+="─"; done
    printf '\e[%d;%dH%s└%s┘%s' $(( top + h - 1 )) "$left" "$TUI_C_BORDER" "$bar2" "$TUI_RST"
}

# 画一条水平分隔线：├───...───┤
# tui_sep ROW LEFT WIDTH
tui_sep() {
    local row=$1 left=$2 w=$3
    local bar
    printf -v bar '%*s' $(( w - 2 )) ''
    bar=${bar// /─}
    printf '\e[%d;%dH%s├%s┤%s' "$row" "$left" "$TUI_C_BORDER" "$bar" "$TUI_RST"
}

# 在滚动区域内向下插入 1 行（内容整体上移，底部露出空行）
# tui_scroll_region_down TOP BOTTOM COL
tui_scroll_region_down() {
    local top=$1 bottom=$2 col=$3
    printf '\e[%d;%dr' "$top" "$bottom"
    printf '\e[%d;%dH' "$top" "$col"
    printf '\e[M'
    printf '\e[r'
}

# 在滚动区域内向上插入 1 行（内容整体下移，顶部露出空行）
# tui_scroll_region_up TOP BOTTOM COL
tui_scroll_region_up() {
    local top=$1 bottom=$2 col=$3
    printf '\e[%d;%dr' "$top" "$bottom"
    printf '\e[%d;%dH' "$top" "$col"
    printf '\e[L'
    printf '\e[r'
}

# 从尾部截断以适应宽度，前面加省略号
# tui_tail_fit STRING MAXWIDTH  ->  TUI_TRUNC
tui_tail_fit() {
    local s=$1 max=$2
    local n=${#s} start=0
    (( max < 2 )) && { TUI_TRUNC=""; return; }
    while (( start < n )); do
        tui_strwidth "${s:start}"
        (( TUI_W <= max - 1 )) && break
        start=$(( start + 1 ))
    done
    if (( start == 0 )); then
        TUI_TRUNC=$s
    else
        TUI_TRUNC="…${s:start}"
    fi
}

# tui_puts ROW COL TEXT
tui_puts() { tui_at "$1" "$2"; printf '%s' "$3"; }

# tui_puts_styled ROW COL STYLE TEXT
tui_puts_styled() { tui_at "$1" "$2"; printf '%s%s%s' "$3" "$4" "$TUI_RST"; }

# 在指定行、指定宽度内写一段"左对齐 + 补空格"的字符串（清背景）
# tui_puts_pad ROW COL WIDTH STYLE TEXT
tui_puts_pad() {
    local r=$1 c=$2 width=$3 style=$4 text=$5
    tui_trunc "$text" "$width"
    local t=$TUI_TRUNC tw
    tui_strwidth "$t"; tw=$TUI_W
    local pad=$(( width - tw )); (( pad < 0 )) && pad=0
    printf '\e[%d;%dH%s%s%s%*s%s' \
        "$r" "$c" "$TUI_C_TEXT" "$style" "$t" "$pad" '' "$TUI_RST"
}

# ---------------------------------------------------------------------------
# 读取按键 -> TUI_KEY
# ---------------------------------------------------------------------------
tui_readkey() {
    local k c1 c2 c3

    # SIGWINCH 挂起时优先返回 RESIZE
    if (( ${TUI_RESIZED:-0} )); then
        TUI_RESIZED=0
        TUI_KEY=RESIZE
        return
    fi

    if ! IFS= read -rsn1 k < "$TUI_TTY"; then
        if (( ${TUI_RESIZED:-0} )); then
            TUI_RESIZED=0
            TUI_KEY=RESIZE
            return
        fi
        TUI_KEY=EOF
        return
    fi

    if [[ $k == $'\e' ]]; then
        IFS= read -rsn1 -t 0.1 c1 < "$TUI_TTY" || c1=""
        if [[ -z $c1 ]]; then TUI_KEY=ESC; return; fi
        if [[ $c1 == '[' || $c1 == 'O' ]]; then
            IFS= read -rsn1 -t 0.1 c2 < "$TUI_TTY" || c2=""
            case $c2 in
                A) TUI_KEY=UP ;;
                B) TUI_KEY=DOWN ;;
                C) TUI_KEY=RIGHT ;;
                D) TUI_KEY=LEFT ;;
                H) TUI_KEY=HOME ;;
                F) TUI_KEY=END ;;
                [0-9])
                    # 读完整 CSI 序列直到 '~'
                    local ext=$c2 c3
                    IFS= read -rsn1 -t 0.1 c3 < "$TUI_TTY" || c3=""
                    while [[ -n $c3 && $c3 != '~' ]]; do
                        ext+="$c3"
                        IFS= read -rsn1 -t 0.1 c3 < "$TUI_TTY" || c3=""
                    done
                    case $ext in
                        1|7) TUI_KEY=HOME ;;
                        4|8) TUI_KEY=END ;;
                        5)   TUI_KEY=PGUP ;;
                        6)   TUI_KEY=PGDN ;;
                        27\;5\;4[9]|27\;5\;5[0-7])
                            # xterm 风格 Ctrl+1..9: \e[27;5;49~ .. \e[27;5;57~
                            local d=${ext##*;}
                            TUI_KEY="SCHEME_$(( d - 48 ))"
                            ;;
                        *) TUI_KEY=UNKNOWN ;;
                    esac
                    ;;
                *) TUI_KEY=UNKNOWN ;;
            esac
        else
            TUI_KEY=UNKNOWN
        fi
        return
    fi

    case $k in
        '')              TUI_KEY=ENTER ;;
        ' ')             TUI_KEY=SPACE ;;
        $'\x7f'|$'\x08') TUI_KEY=BACKSPACE ;;
        $'\t')           TUI_KEY=TAB ;;
        $'\x0c')         TUI_KEY=REFRESH ;;   # Ctrl-L
        *)               TUI_KEY=$k ;;
    esac
}

# ---------------------------------------------------------------------------
# 组件
# ---------------------------------------------------------------------------
tui_msgbox() {
    local title=$1; shift
    local -a lines=("$@")
    (( ${#lines[@]} == 0 )) && lines=("")

    local maxw=0 w h top left i
    for l in "${lines[@]}"; do
        tui_strwidth "$l"; (( TUI_W > maxw )) && maxw=$TUI_W
    done
    tui_strwidth "$title"; (( TUI_W + 4 > maxw )) && maxw=$(( TUI_W + 4 ))
    (( maxw < 30 )) && maxw=30
    w=$(( maxw + 4 )); (( w > TUI_COLS - 2 )) && w=$(( TUI_COLS - 2 ))
    # 上框(1) + 内容(n) + 分隔线(1) + 提示(1) + 下框(1)
    h=$(( ${#lines[@]} + 4 ))

    top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
    left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1

    local sep_row=$(( top + ${#lines[@]} + 1 ))
    local hint_row=$(( sep_row + 1 ))

    tui_box "$top" "$left" "$h" "$w" "$title"
    for (( i=0; i<${#lines[@]}; i++ )); do
        tui_puts_pad $(( top + 1 + i )) $(( left + 2 )) $(( w - 4 )) "" "${lines[i]}"
    done
    tui_sep "$sep_row" "$left" "$w"
    tui_puts_pad "$hint_row" $(( left + 2 )) $(( w - 4 )) "$TUI_C_HINT" "按任意键继续"
    tui_readkey
}

tui_confirm() {
    local title=$1 text=$2
    local w=50 h=5 top left
    tui_strwidth "$text";  (( TUI_W + 4 > w )) && w=$(( TUI_W + 4 ))
    tui_strwidth "$title"; (( TUI_W + 4 > w )) && w=$(( TUI_W + 4 ))
    (( w > TUI_COLS - 2 )) && w=$(( TUI_COLS - 2 ))
    top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
    left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1

    # 上框(1) + 文本(1) + 分隔线(1) + 提示(1) + 下框(1)
    local sep_row=$(( top + 2 ))
    local hint_row=$(( top + 3 ))

    tui_box "$top" "$left" "$h" "$w" "$title"
    tui_puts_pad $(( top + 1 )) $(( left + 2 )) $(( w - 4 )) "" "$text"
    tui_sep "$sep_row" "$left" "$w"
    tui_puts_pad "$hint_row" $(( left + 2 )) $(( w - 4 )) "$TUI_C_HINT" "[Y] 是    [N] 否"

    while :; do
        tui_readkey
        case $TUI_KEY in
            y|Y) return 0 ;;
            n|N|ESC|ENTER) return 1 ;;
        esac
    done
}

tui_input() {
    local title=$1 prompt=$2 default=${3:-}
    local w=60 h=7 top left
    (( w > TUI_COLS - 2 )) && w=$(( TUI_COLS - 2 ))
    top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
    left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1

    # 上框(1) + 提示(1) + 空行(1) + 输入(1) + 分隔线(1) + 提示(1) + 下框(1)
    local input_row=$(( top + 3 ))
    local sep_row=$(( top + 4 ))
    local hint_row=$(( top + 5 ))

    tui_box "$top" "$left" "$h" "$w" "$title"
    tui_puts $(( top + 1 )) $(( left + 2 )) "$prompt"
    tui_sep "$sep_row" "$left" "$w"
    tui_puts_pad "$hint_row" $(( left + 2 )) $(( w - 4 )) "$TUI_C_HINT" "Enter 确认  Esc 取消"

    local buf=$default
    local col=$(( left + 2 )) maxw=$(( w - 4 ))
    local newbuf

    while :; do
        tui_puts_pad "$input_row" "$col" "$maxw" "$TUI_REV" "$buf"
        tui_strwidth "$buf"
        tui_at "$input_row" $(( col + TUI_W ))
        tui_show_cursor
        tui_readkey
        tui_hide_cursor

        case $TUI_KEY in
            ENTER) TUI_RESULT=$buf; return 0 ;;
            ESC)   TUI_RESULT=""; return 1 ;;
            BACKSPACE) (( ${#buf} > 0 )) && buf=${buf%?} ;;
            SPACE) buf+=" " ;;
            UNKNOWN|UP|DOWN|LEFT|RIGHT|HOME|END|TAB|EOF) ;;
            *)
                newbuf="$buf$TUI_KEY"
                tui_strwidth "$newbuf"
                (( TUI_W <= maxw )) && buf=$newbuf
                ;;
        esac
    done
}

# 菜单：TUI_HEADER 可选（头部说明行）
tui_menu() {
    local title=$1; shift
    local -a items=("$@")
    local n=${#items[@]}
    (( n == 0 )) && { TUI_RESULT=""; return 1; }

    local nh=${#TUI_HEADER[@]}
    local cur=0 offset=0 maxw=0 w h top left i

    for it in "${items[@]}";      do tui_strwidth "  $it"; (( TUI_W > maxw )) && maxw=$TUI_W; done
    for it in "${TUI_HEADER[@]}"; do tui_strwidth "  $it"; (( TUI_W > maxw )) && maxw=$TUI_W; done
    tui_strwidth "$title"; (( TUI_W + 4 > maxw )) && maxw=$(( TUI_W + 4 ))
    (( maxw < 70 )) && maxw=70
    (( maxw + 4 > TUI_COLS - 2 )) && maxw=$(( TUI_COLS - 6 ))
    w=$(( maxw + 4 ))

    # 行布局: 上框(1) + header(nh) + 分隔线(nh?1:0) + 选项(view)
    #        + 分隔线(1) + 提示(1) + 下框(1)
    local has_header_sep=0
    (( nh > 0 )) && has_header_sep=1
    local fixed=$(( nh + has_header_sep + 4 ))

    local view max_view inner col item_top header_sep_row hint_sep_row hint_row

    _tui_menu_recalc() {
        max_view=$(( TUI_ROWS - 2 - fixed ))
        (( max_view < 1 )) && max_view=1
        view=$n
        (( view > max_view )) && view=$max_view
        h=$(( fixed + view ))
        top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
        left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1
        inner=$(( w - 2 ))
        col=$(( left + 1 ))

        local r=$(( top + 1 ))
        if (( nh > 0 )); then
            r=$(( r + nh ))
            header_sep_row=$r
            r=$(( r + 1 ))
        else
            header_sep_row=-1
        fi
        item_top=$r
        r=$(( r + view ))
        hint_sep_row=$r
        hint_row=$(( r + 1 ))

        (( cur < offset ))         && offset=$cur
        (( cur >= offset + view )) && offset=$(( cur - view + 1 ))
        (( offset < 0 )) && offset=0
    }

    _tui_menu_draw_item() {
        local idx=$1 sel=$2 srow=$3 st=""
        (( sel )) && st="$TUI_C_SELECT"
        tui_puts_pad $(( item_top + srow )) "$col" "$inner" "$st" "  ${items[idx]}"
    }

    local hint="  ↑↓ 选择  PgUp/PgDn 翻页  Home/End 首末  r 刷新  Enter 确认  Esc 返回"

    _tui_menu_full() {
        local k idx rr
        tui_box "$top" "$left" "$h" "$w" "$title"
        if (( nh > 0 )); then
            rr=$(( top + 1 ))
            for (( k=0; k<nh; k++ )); do
                tui_puts_pad "$rr" "$col" "$inner" "$TUI_C_TEXT" "  ${TUI_HEADER[k]}"
                rr=$(( rr + 1 ))
            done
            tui_sep "$header_sep_row" "$left" "$w"
        fi
        for (( k=0; k<view; k++ )); do
            idx=$(( offset + k ))
            (( idx >= n )) && break
            _tui_menu_draw_item "$idx" "$(( idx == cur ))" "$k"
        done
        tui_sep "$hint_sep_row" "$left" "$w"
        tui_puts_pad "$hint_row" "$col" "$inner" "$TUI_C_HINT" "$hint"
    }

    _tui_menu_recalc
    _tui_menu_full

        local old new_offset
    while :; do
        tui_readkey
        if tui_check_scheme_key; then
            tui_size
            tui_clear
            _tui_menu_recalc
            _tui_menu_full
            continue
        fi
        old=$cur
        case $TUI_KEY in
            UP)    (( cur > 0 )) && cur=$(( cur - 1 )) ;;
            DOWN)  (( cur < n - 1 )) && cur=$(( cur + 1 )) ;;
            PGUP)  cur=$(( cur - view )); (( cur < 0 )) && cur=0 ;;
            PGDN)  cur=$(( cur + view )); (( cur >= n )) && cur=$(( n - 1 )) ;;
            HOME)  cur=0 ;;
            END)   cur=$(( n - 1 )) ;;
            r|R|REFRESH|RESIZE)
                tui_size
                tui_clear
                _tui_menu_recalc
                _tui_menu_full
                continue ;;
            ENTER) TUI_RESULT=$cur; return 0 ;;
            ESC)   TUI_RESULT=""; return 1 ;;
            *) continue ;;
        esac
        (( old == cur )) && continue

        new_offset=$offset
        (( cur < offset ))         && new_offset=$cur
        (( cur >= offset + view )) && new_offset=$(( cur - view + 1 ))
        (( new_offset < 0 )) && new_offset=0

        if (( new_offset == offset )); then
            # 光标在可视区内移动：只重绘两行
            _tui_menu_draw_item "$old" 0 "$(( old - offset ))"
            _tui_menu_draw_item "$cur" 1 "$(( cur - offset ))"
        elif (( cur == old + 1 && new_offset == offset + 1 )); then
            # 单步向下：硬件滚动 + 补底部一行 + 补边框
            _tui_menu_draw_item "$old" 0 "$(( old - offset ))"
            tui_scroll_region_down "$item_top" "$(( item_top + view - 1 ))" "$col"
            offset=$new_offset
            _tui_menu_draw_item "$cur" 1 "$(( view - 1 ))"
            printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
                "$(( item_top + view - 1 ))" "$left" "$TUI_C_BORDER" "$TUI_RST" \
                "$(( item_top + view - 1 ))" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
        elif (( cur == old - 1 && new_offset == offset - 1 )); then
            # 单步向上：硬件滚动 + 补顶部一行 + 补边框
            _tui_menu_draw_item "$old" 0 "$(( old - offset ))"
            tui_scroll_region_up "$item_top" "$(( item_top + view - 1 ))" "$col"
            offset=$new_offset
            _tui_menu_draw_item "$cur" 1 0
            printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
                "$item_top" "$left" "$TUI_C_BORDER" "$TUI_RST" \
                "$item_top" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
        else
            # 翻页 / 跳转：全量重绘
            offset=$new_offset
            _tui_menu_full
        fi
    done
}

# 复选表：读取/回写 TUI_ITEMS / TUI_STATES / TUI_LOCKED
tui_checklist() {
    local title=$1
    local n=${#TUI_ITEMS[@]}
    (( n == 0 )) && return 1

    local cur=0 offset=0 maxw=0 w h top left i

    for it in "${TUI_ITEMS[@]}"; do
        tui_strwidth "  [x] $it"; (( TUI_W > maxw )) && maxw=$TUI_W
    done
    tui_strwidth "$title"; (( TUI_W + 4 > maxw )) && maxw=$(( TUI_W + 4 ))
    (( maxw < 50 )) && maxw=50
    (( maxw + 4 > TUI_COLS - 2 )) && maxw=$(( TUI_COLS - 6 ))
    w=$(( maxw + 4 ))

    # 行布局: 上框(1) + 选项(view) + 分隔线(1) + 提示(1) + 下框(1)
    local fixed=4
    local view max_view inner col item_top hint_sep_row hint_row

    _tui_cl_recalc() {
        max_view=$(( TUI_ROWS - 4 - fixed ))
        (( max_view < 1 )) && max_view=1
        view=$n
        (( view > max_view )) && view=$max_view
        h=$(( fixed + view ))
        (( h > TUI_ROWS - 2 )) && h=$(( TUI_ROWS - 2 ))
        top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
        left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1
        inner=$(( w - 2 ))
        col=$(( left + 1 ))
        item_top=$(( top + 1 ))
        hint_sep_row=$(( top + view + 1 ))
        hint_row=$(( top + view + 2 ))
        (( cur < offset ))         && offset=$cur
        (( cur >= offset + view )) && offset=$(( cur - view + 1 ))
        (( offset < 0 )) && offset=0
    }

    _tui_cl_draw() {
        local srow=$1 idx=$2 sel=$3
        local mark=" " locked line st=""
        (( TUI_STATES[idx] )) && mark="x"
        locked=${TUI_LOCKED[idx]:-0}
        if (( locked )); then
            line="  [-] ${TUI_ITEMS[idx]}"
            st="$TUI_FG_GRAY"
        else
            line="  [$mark] ${TUI_ITEMS[idx]}"
        fi
        (( sel )) && st="$TUI_C_SELECT"
        tui_puts_pad $(( item_top + srow )) "$col" "$inner" "$st" "$line"
    }

    local hint="  空格=勾选  a=全选  n=全不选  PgUp/PgDn Home/End  r=刷新  Enter=确认  Esc=返回"

    _tui_cl_full() {
        local k idx
        tui_box "$top" "$left" "$h" "$w" "$title"
        for (( k=0; k<view; k++ )); do
            idx=$(( offset + k ))
            (( idx >= n )) && break
            _tui_cl_draw "$k" "$idx" "$(( idx == cur ))"
        done
        tui_sep "$hint_sep_row" "$left" "$w"
        tui_puts_pad "$hint_row" "$col" "$inner" "$TUI_C_HINT" "$hint"
    }

    _tui_cl_recalc
    _tui_cl_full

        local old new_offset
    while :; do
        tui_readkey
        if tui_check_scheme_key; then
            tui_size
            tui_clear
            _tui_cl_recalc
            _tui_cl_full
            continue
        fi
        old=$cur
        case $TUI_KEY in
            UP)    (( cur > 0 )) && cur=$(( cur - 1 )) ;;
            DOWN)  (( cur < n - 1 )) && cur=$(( cur + 1 )) ;;
            PGUP)  cur=$(( cur - view )); (( cur < 0 )) && cur=0 ;;
            PGDN)  cur=$(( cur + view )); (( cur >= n )) && cur=$(( n - 1 )) ;;
            HOME)  cur=0 ;;
            END)   cur=$(( n - 1 )) ;;
            SPACE)
                if (( ! ${TUI_LOCKED[cur]:-0} )); then
                    TUI_STATES[cur]=$(( 1 - ${TUI_STATES[cur]:-0} ))
                fi
                _tui_cl_draw "$(( cur - offset ))" "$cur" 1
                continue ;;
            a|A)
                for (( i=0; i<n; i++ )); do
                    (( ${TUI_LOCKED[i]:-0} )) && continue
                    TUI_STATES[i]=1
                done
                _tui_cl_full
                continue ;;
            n|N)
                for (( i=0; i<n; i++ )); do
                    (( ${TUI_LOCKED[i]:-0} )) && continue
                    TUI_STATES[i]=0
                done
                _tui_cl_full
                continue ;;
            r|R|REFRESH|RESIZE)
                tui_size
                tui_clear
                _tui_cl_recalc
                _tui_cl_full
                continue ;;
            ENTER) return 0 ;;
            ESC)   return 1 ;;
            *) continue ;;
        esac
        (( old == cur )) && continue

        new_offset=$offset
        (( cur < offset ))         && new_offset=$cur
        (( cur >= offset + view )) && new_offset=$(( cur - view + 1 ))
        (( new_offset < 0 )) && new_offset=0

        if (( new_offset == offset )); then
            _tui_cl_draw "$(( old - offset ))" "$old" 0
            _tui_cl_draw "$(( cur - offset ))" "$cur" 1
        elif (( cur == old + 1 && new_offset == offset + 1 )); then
            _tui_cl_draw "$(( old - offset ))" "$old" 0
            tui_scroll_region_down "$item_top" "$(( item_top + view - 1 ))" "$col"
            offset=$new_offset
            _tui_cl_draw "$(( view - 1 ))" "$cur" 1
            printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
                "$(( item_top + view - 1 ))" "$left" "$TUI_C_BORDER" "$TUI_RST" \
                "$(( item_top + view - 1 ))" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
        elif (( cur == old - 1 && new_offset == offset - 1 )); then
            _tui_cl_draw "$(( old - offset ))" "$old" 0
            tui_scroll_region_up "$item_top" "$(( item_top + view - 1 ))" "$col"
            offset=$new_offset
            _tui_cl_draw 0 "$cur" 1
            printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
                "$item_top" "$left" "$TUI_C_BORDER" "$TUI_RST" \
                "$item_top" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
        else
            offset=$new_offset
            _tui_cl_full
        fi
    done
}

# ---------------------------------------------------------------------------
# 目录选择器：输入框 + 候选列表联动
#   tui_dirpicker TITLE [INITIAL_PATH]
#   成功返回 0，路径写入 TUI_RESULT；取消返回 1
#
# 按键:
#   输入框焦点  ↑↓/Tab 进入列表，Enter 确认，Esc 取消，普通键编辑
#   列表焦点    ↑↓ 移动，PgUp/PgDn 翻页，Home/End 首末，
#               Enter 选中填回输入框，Tab/顶到头再 ↑ 回输入框
#   r / Ctrl-L  重绘整屏
# ---------------------------------------------------------------------------
tui_dirpicker() {
    local title=$1
    local initial=${2:-$PWD}

    if command -v realpath >/dev/null 2>&1; then
        initial=$(realpath -m -- "$initial")
    else
        [[ $initial != /* ]] && initial="$PWD/$initial"
    fi

    local input="$initial"
    local focus=0          # 0=输入框, 1=列表
    local cur=0
    local offset=0
    local -a cands=()
    local n_cand=0

    # ------------------------------ 候选计算 -----------------------------
    _tui_dp_compute() {
        local inp=$1 d b
        if [[ -z $inp ]]; then
            d=$PWD; b=""
        elif [[ -d $inp && $inp != */ ]]; then
            d=$inp; b=""
        elif [[ -d $inp ]]; then
            d=${inp%/}
            [[ -z $d ]] && d=/
            b=""
        else
            d=$(dirname -- "$inp")
            b=$(basename -- "$inp")
            [[ $d == "." ]] && d=$PWD
        fi

        cands=()
        if [[ ! -d $d ]]; then
            n_cand=0; cur=0; offset=0
            return
        fi

        local show_hidden=0
        [[ $b == .* ]] && show_hidden=1

        local entry name
        while IFS= read -r -d '' entry; do
            name=${entry##*/}
            [[ -z $name ]] && continue
            [[ $name == "$b"* ]] || continue
            (( show_hidden )) || [[ $name != .* ]] || continue
            cands+=("$entry/")
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type d \
                    -printf '%p\0' 2>/dev/null | LC_ALL=C sort -z)

        while IFS= read -r -d '' entry; do
            name=${entry##*/}
            [[ -z $name ]] && continue
            [[ $name == "$b"* ]] || continue
            (( show_hidden )) || [[ $name != .* ]] || continue
            cands+=("$entry")
        done < <(find "$d" -mindepth 1 -maxdepth 1 -type f \
                    -printf '%p\0' 2>/dev/null | LC_ALL=C sort -z)

        n_cand=${#cands[@]}
        (( cur >= n_cand )) && cur=$(( n_cand - 1 ))
        (( cur < 0 )) && cur=0
    }

    # ------------------------------ 布局 ---------------------------------
    local w h top left inner col
    local view max_view
    local input_row sep1_row list_top sep2_row hint_row
    local hint="  输入路径或 ↑↓ 选  Tab 切换  Enter 确认  Esc 取消"

    _tui_dp_layout() {
        local maxw=64
        (( maxw + 4 > TUI_COLS - 2 )) && maxw=$(( TUI_COLS - 6 ))
        w=$(( maxw + 4 ))
        local fixed=6
        max_view=$(( TUI_ROWS - 4 - fixed ))
        (( max_view < 1 )) && max_view=1
        view=$n_cand
        (( view > max_view )) && view=$max_view
        (( view < 1 )) && view=1
        h=$(( fixed + view ))
        (( h > TUI_ROWS - 2 )) && h=$(( TUI_ROWS - 2 ))
        top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
        left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1
        inner=$(( w - 2 ))
        col=$(( left + 1 ))
        input_row=$(( top + 1 ))
        sep1_row=$(( top + 2 ))
        list_top=$(( top + 3 ))
        sep2_row=$(( list_top + view ))
        hint_row=$(( sep2_row + 1 ))

        (( cur < offset ))         && offset=$cur
        (( cur >= offset + view )) && offset=$(( cur - view + 1 ))
        (( offset < 0 )) && offset=0
    }

    # ------------------------------ 绘制 ---------------------------------
    _tui_dp_draw_input() {
        local text="路径: ${input}"
        local maxw=$(( inner - 1 ))
        tui_tail_fit "$text" "$maxw"
        local disp=$TUI_TRUNC
        tui_strwidth "$disp"
        local dw=$TUI_W
        local pad=$(( inner - dw - 1 ))
        (( pad < 0 )) && pad=0
        if (( focus == 0 )); then
            printf '\e[%d;%dH%s%*s\e[7m \e[0m' \
                "$input_row" "$col" "$disp" "$pad" ''
        else
            printf '\e[%d;%dH%s%*s ' "$input_row" "$col" "$disp" "$pad" ''
        fi
    }

    _tui_dp_draw_row() {
        local srow=$1 idx=$2 sel=$3 st=""
        (( sel )) && st="$TUI_C_SELECT"
        tui_puts_pad $(( list_top + srow )) "$col" "$inner" "$st" \
            "  ${cands[idx]}"
    }

    _tui_dp_draw_list() {
        local k idx
        for (( k=0; k<view; k++ )); do
            idx=$(( offset + k ))
            if (( idx >= n_cand )); then
                if (( k == 0 )); then
                    tui_puts_pad $(( list_top + k )) "$col" "$inner" \
                        "$TUI_C_HINT" "  (无匹配项)"
                else
                    tui_puts_pad $(( list_top + k )) "$col" "$inner" "" ""
                fi
            else
                _tui_dp_draw_row "$k" "$idx" "$(( idx == cur && focus == 1 ))"
            fi
        done
    }

    _tui_dp_redraw_content() {
        _tui_dp_draw_input
        _tui_dp_draw_list
    }

    _tui_dp_draw_full() {
        tui_clear                                    # ← 新增
        tui_box "$top" "$left" "$h" "$w" "$title"
        _tui_dp_redraw_content
        tui_sep "$sep1_row" "$left" "$w"
        tui_sep "$sep2_row" "$left" "$w"
        tui_puts_pad "$hint_row" "$col" "$inner" "$TUI_C_HINT" "$hint"
    }

    # ------------------------------ 事件 ---------------------------------
    _tui_dp_compute "$input"
    _tui_dp_layout
    _tui_dp_draw_full

    local old new_offset
    while :; do
        tui_readkey
        if (( focus == 1 )) && tui_check_scheme_key; then
            tui_size
            tui_clear
            _tui_dp_layout
            _tui_dp_draw_full
            continue
        fi
        case $TUI_KEY in
            ESC)
                TUI_RESULT=""; return 1 ;;

            ENTER)
                if (( focus == 1 )) && (( n_cand > 0 )); then
                    input=${cands[cur]}
                    _tui_dp_compute "$input"
                    _tui_dp_layout
                    _tui_dp_draw_full
                else
                    TUI_RESULT=$input; return 0
                fi ;;

            TAB)
                if (( focus == 0 )); then
                    (( n_cand > 0 )) && focus=1
                else
                    focus=0
                fi
                _tui_dp_redraw_content ;;

            BACKSPACE)
                if (( focus == 0 )) && (( ${#input} > 0 )); then
                    input=${input%?}
                    _tui_dp_compute "$input"
                    _tui_dp_layout
                    _tui_dp_draw_full
                fi ;;

            SPACE)
                if (( focus == 0 )); then
                    input+=" "
                    _tui_dp_compute "$input"
                    _tui_dp_layout
                    _tui_dp_draw_full
                fi ;;

            UP)
                if (( focus == 0 )); then
                    (( n_cand > 0 )) && focus=1
                    _tui_dp_redraw_content
                elif (( cur > 0 )); then
                    old=$cur; cur=$(( cur - 1 ))
                    new_offset=$offset
                    (( cur < offset )) && new_offset=$cur
                    (( new_offset < 0 )) && new_offset=0
                    if (( new_offset == offset )); then
                        _tui_dp_draw_row "$(( old - offset ))" "$old" 0
                        _tui_dp_draw_row "$(( cur - offset ))" "$cur" 1
                    elif (( new_offset == offset - 1 )); then
                        _tui_dp_draw_row "$(( old - offset ))" "$old" 0
                        tui_scroll_region_up "$list_top" "$(( list_top + view - 1 ))" "$col"
                        offset=$new_offset
                        _tui_dp_draw_row 0 "$cur" 1
                        printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
                            "$list_top" "$left" "$TUI_C_BORDER" "$TUI_RST" \
                            "$list_top" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
                    else
                        offset=$new_offset
                        _tui_dp_draw_list
                    fi
                else
                    focus=0
                    _tui_dp_redraw_content
                fi ;;

            DOWN)
                if (( focus == 0 )); then
                    (( n_cand > 0 )) && focus=1
                    _tui_dp_redraw_content
                elif (( cur < n_cand - 1 )); then
                    old=$cur; cur=$(( cur + 1 ))
                    new_offset=$offset
                    (( cur >= offset + view )) && new_offset=$(( cur - view + 1 ))
                    (( new_offset < 0 )) && new_offset=0
                    if (( new_offset == offset )); then
                        _tui_dp_draw_row "$(( old - offset ))" "$old" 0
                        _tui_dp_draw_row "$(( cur - offset ))" "$cur" 1
                    elif (( new_offset == offset + 1 )); then
                        _tui_dp_draw_row "$(( old - offset ))" "$old" 0
                        tui_scroll_region_down "$list_top" "$(( list_top + view - 1 ))" "$col"
                        offset=$new_offset
                        _tui_dp_draw_row "$(( view - 1 ))" "$cur" 1
                        printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
                            "$(( list_top + view - 1 ))" "$left" "$TUI_C_BORDER" "$TUI_RST" \
                            "$(( list_top + view - 1 ))" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
                    else
                        offset=$new_offset
                        _tui_dp_draw_list
                    fi
                fi ;;

            PGUP)
                if (( focus == 1 )) && (( n_cand > 0 )); then
                    old=$cur
                    cur=$(( cur - view )); (( cur < 0 )) && cur=0
                    if (( cur != old )); then
                        (( cur < offset )) && offset=$cur
                        (( offset < 0 )) && offset=0
                        _tui_dp_draw_list
                    fi
                fi ;;

            PGDN)
                if (( focus == 1 )) && (( n_cand > 0 )); then
                    old=$cur
                    cur=$(( cur + view )); (( cur >= n_cand )) && cur=$(( n_cand - 1 ))
                    if (( cur != old )); then
                        new_offset=$offset
                        (( cur >= offset + view )) && new_offset=$(( cur - view + 1 ))
                        (( new_offset < 0 )) && new_offset=0
                        offset=$new_offset
                        _tui_dp_draw_list
                    fi
                fi ;;

            HOME)
                if (( focus == 1 )) && (( n_cand > 0 )); then
                    cur=0; offset=0
                    _tui_dp_draw_list
                fi ;;

            END)
                if (( focus == 1 )) && (( n_cand > 0 )); then
                    cur=$(( n_cand - 1 ))
                    offset=$(( cur - view + 1 )); (( offset < 0 )) && offset=0
                    _tui_dp_draw_list
                fi ;;

            r|R|REFRESH|RESIZE)
                tui_size
                tui_clear
                _tui_dp_layout
                _tui_dp_draw_full ;;

            UNKNOWN|LEFT|RIGHT|EOF)
                ;;

            *)
                if (( focus == 0 )); then
                    input+=$TUI_KEY
                    _tui_dp_compute "$input"
                    _tui_dp_layout
                    _tui_dp_draw_full
                fi ;;
        esac
    done
}
