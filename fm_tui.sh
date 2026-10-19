#!/usr/bin/env bash
# ============================================================================
# fm_tui.sh —— 文件管理器（基于 tui.sh） powered by deepseed
# ----------------------------------------------------------------------------
# 功能:
#   1) 浏览目录：进入/退出、查看文件列表
#   2) 打开文件：左侧十六进制 / 右侧 ASCII，不可显示字符用 '.' 表示
#   3) 退出时输出 `cd <dir>`，配合 eval 可让当前 shell 跟随进入该目录
#
# 用法:
#   直接运行:           ./fm_tui.sh [起始目录]
#   让终端跟随进入:      eval "$(./fm_tui.sh [起始目录])"
#
# 按键:
#   浏览    ↑↓ 选择  PgUp/PgDn 翻页  Home/End 首末
#           →/Enter 进入目录 或 打开文件
#           ←/Backspace 返回上级
#           h 切换隐藏文件   r 刷新   q/Esc 退出
#   查看    ↑↓ 滚动   PgUp/PgDn 翻页   Home/End 首尾   q/Esc 返回
# ============================================================================
set -uo pipefail
export LC_ALL=${LC_ALL:-C.UTF-8}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=tui.sh
source "$SCRIPT_DIR/tui.sh" || { echo "无法加载 $SCRIPT_DIR/tui.sh" >&2; exit 1; }

# ----------------------------- 全局状态 -------------------------------------
CURRENT_DIR=""
SHOW_HIDDEN=0

# ----------------------------- 工具函数 -------------------------------------
human() {
    local b=${1:-0} i=0 frac=0
    local -a u=(B KB MB GB TB PB)
    while (( b >= 1024 && i < 5 )); do
        frac=$(( (b % 1024) * 10 / 1024 )); b=$(( b / 1024 )); i=$(( i + 1 ))
    done
    if (( i == 0 )); then printf '%d B' "$b"; else printf '%d.%d %s' "$b" "$frac" "${u[i]}"; fi
}

_fm_on_exit() { tui_cleanup; }

# ============================================================================
# 十六进制查看器
# ============================================================================
_hex_view() {
    local file=$1
    local size
    size=$(stat -c %s -- "$file" 2>/dev/null) || size=0

    if (( size == 0 )); then
        tui_msgbox "空文件" "文件为空：$file"
        return
    fi

    local mode="hex"         # hex | text
    local bpl=16             # hex 每行字节数
    local start=0            # 当前模式下起始行
    local hcol=0             # 文本模式水平偏移（字节）
    local title
    local w h top left inner col view
    local sep_row hint_row item_top

    # 文本模式行索引
    local lines_dat=""
    local -a line_offsets=()
    local -a line_texts=()
    local n_lines=0
    local text_loaded=0

    _hex_total_lines() {
        if [[ $mode == text ]]; then
            echo "$n_lines"
        else
            echo $(( (size + bpl - 1) / bpl ))
        fi
    }

    # ---- 文本行索引：一行一条 "起始字节偏移 \t 行内容" ，NUL 分隔 ----
    _load_text_lines() {
        (( text_loaded )) && return
        lines_dat=$(mktemp 2>/dev/null) || { n_lines=0; text_loaded=1; return; }

        # 关键：先把不可显示字节（除 \t \n 和可打印 ASCII 之外）全部替换成 '.'
        #   - 每个字节一对一替换，行内长度不变，offset 仍精确对应源文件
        #   - 保证 awk / read / bash 只处理可打印字符，不会因 NUL 或非法 UTF-8 崩溃
        tr -c '\11\12\40-\176' '.' < "$file" 2>/dev/null \
          | LC_ALL=C awk '
                BEGIN { off = 0 }
                { printf "%d\t%s\0", off, $0; off += length($0) + 1 }
            ' > "$lines_dat" 2>/dev/null

        line_offsets=()
        line_texts=()
        local rec off
        while IFS= read -r -d '' rec; do
            off=${rec%%$'\t'*}
            # 双保险：offset 必须是纯数字，否则丢弃该记录
            [[ $off =~ ^[0-9]+$ ]] || continue
            line_offsets+=("$off")
            line_texts+=("${rec#*$'\t'}")
        done < "$lines_dat"
        n_lines=${#line_offsets[@]}
        text_loaded=1
    }

    _cleanup_lines() {
        [[ -n $lines_dat && -f $lines_dat ]] && rm -f -- "$lines_dat"
    }

    _hex_layout() {
        tui_size
        w=80
        (( w > TUI_COLS - 2 )) && w=$(( TUI_COLS - 2 ))
        (( w < 60 )) && w=60
        # 上框(1) + 内容(view) + 分隔线(1) + 提示(1) + 下框(1)
        local fixed=4
        local max_view=$(( TUI_ROWS - 2 - fixed ))
        (( max_view < 3 )) && max_view=3
        view=$max_view
        h=$(( fixed + view ))
        (( h > TUI_ROWS - 2 )) && h=$(( TUI_ROWS - 2 ))
        top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
        left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1
        inner=$(( w - 2 ))
        col=$(( left + 1 ))
        item_top=$(( top + 1 ))
        sep_row=$(( top + view + 1 ))
        hint_row=$(( top + view + 2 ))
    }

    _hex_render_row() {
        local screen_row=$1 line_idx=$2
        local total; total=$(_hex_total_lines)
        if (( line_idx < 0 || line_idx >= total )); then
            tui_puts_pad "$screen_row" "$col" "$inner" "" ""
            return
        fi
        local line=""

        if [[ $mode == hex ]]; then
            local offset=$(( line_idx * bpl ))
            local -a nums=()
            mapfile -t nums < <(od -An -tu1 -v -w"$bpl" -j "$offset" -N "$bpl" "$file" 2>/dev/null \
                                | tr -s ' \t' '\n' | grep -E '^[0-9]+$')
            local len=${#nums[@]}
            local hex="" ascii="" n hn c j
            for n in "${nums[@]}"; do
                printf -v hn '%02x' "$n"
                hex+="$hn "
                if (( n >= 32 && n < 127 )); then
                    printf -v c "\\x$hn"
                    ascii+="$c"
                else
                    ascii+="."
                fi
            done
            for (( j=len; j<bpl; j++ )); do
                hex+="   "
                ascii+=" "
            done
            printf -v line '%08x  %s |%s|' "$offset" "$hex" "$ascii"
        else
            # 文本模式：从第 hcol 字节开始取，每字节原样显示或替换成 '.'
            local src=${line_texts[line_idx]:-}
            local srclen=${#src}
            local want=$(( inner - 1 ))
            local avail=$(( srclen - hcol ))
            (( avail < 0 )) && avail=0
            local take=$want
            (( take > avail )) && take=$avail
            local chunk=${src:hcol:take}
            local ascii="" i ch cp
            for (( i=0; i<${#chunk}; i++ )); do
                ch=${chunk:i:1}
                printf -v cp '%d' "'$ch" 2>/dev/null || cp=63
                if (( cp >= 32 && cp < 127 )); then
                    ascii+=$ch
                else
                    ascii+="."
                fi
            done
            printf -v line ' %s' "$ascii"
        fi
        tui_puts_pad "$screen_row" "$col" "$inner" "" "$line"
    }

    _hex_render_hint() {
        local total; total=$(_hex_total_lines)
        local end_line=$(( start + view ))
        (( end_line > total )) && end_line=$total
        local pct=0
        (( total > 0 )) && pct=$(( end_line * 100 / total ))
        (( pct > 100 )) && pct=100
        local sw
        [[ $mode == hex ]] && sw="T 文本" || sw="H 十六进制"
        local status
        if [[ $mode == hex ]]; then
            status="  $(( start + 1 ))-$end_line / $total (${pct}%)  ↑↓ PgUp/PgDn Home/End $sw r 刷新 q 返回"
        else
            status="  行 $(( start + 1 ))-$end_line/$total (${pct}%) 列 $hcol  ↑↓ PgUp/PgDn ←→ 水平 Home/End $sw r 刷新 q 返回"
        fi
        tui_puts_pad "$hint_row" "$col" "$inner" "$TUI_FG_GRAY" "$status"
    }

    _hex_render_content() {
        local k
        for (( k=0; k<view; k++ )); do
            _hex_render_row $(( item_top + k )) $(( start + k ))
        done
    }

    _hex_render_all() {
        local total; total=$(_hex_total_lines)
        (( start < 0 )) && start=0
        (( start + view > total )) && start=$(( total - view ))
        (( start < 0 )) && start=0

        if [[ $mode == hex ]]; then
            title="HEX: $(basename -- "$file")"
        else
            title="TEXT: $(basename -- "$file")"
        fi

        tui_box "$top" "$left" "$h" "$w" "$title"
        _hex_render_content
        tui_sep "$sep_row" "$left" "$w"
        _hex_render_hint
    }

    # ---- 单步硬件滚动（hex / text 通用） ---------------------------------
    _hex_scroll_up_one() {
        tui_scroll_region_up "$item_top" "$(( item_top + view - 1 ))" "$col"
        _hex_render_row "$item_top" "$start"
        printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
            "$item_top" "$left" "$TUI_C_BORDER" "$TUI_RST" \
            "$item_top" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
        _hex_render_hint
    }
    _hex_scroll_down_one() {
        tui_scroll_region_down "$item_top" "$(( item_top + view - 1 ))" "$col"
        _hex_render_row "$(( item_top + view - 1 ))" "$(( start + view - 1 ))"
        printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
            "$(( item_top + view - 1 ))" "$left" "$TUI_C_BORDER" "$TUI_RST" \
            "$(( item_top + view - 1 ))" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
        _hex_render_hint
    }

    # ---- 模式切换（保留字节偏移） ----------------------------------------
    _hex_switch_to_text() {
        _load_text_lines
        local byte_off=$(( start * 16 ))
        if (( n_lines == 0 )); then
            start=0
        else
            local lo=0 hi=$(( n_lines - 1 )) found=0
            while (( lo <= hi )); do
                local mid=$(( (lo + hi) / 2 ))
                local moff=${line_offsets[mid]:-0}
                if [[ $moff =~ ^[0-9]+$ ]] && (( moff <= byte_off )); then
                    found=$mid; lo=$(( mid + 1 ))
                else
                    hi=$(( mid - 1 ))
                fi
            done
            start=$found
        fi
        mode="text"
        hcol=0
    }

    _hex_switch_to_hex() {
        local byte_off=0
        (( n_lines > 0 && start < n_lines )) && byte_off=${line_offsets[start]:-0}
        mode="hex"
        bpl=16
        start=$(( byte_off / bpl ))
        hcol=0
    }

    # ---- 主循环 ----------------------------------------------------------
    _hex_layout
    tui_clear
    _hex_render_all

    local old total
    while :; do
        tui_readkey
        old=$start
        case $TUI_KEY in
            q|Q|ESC)
                _cleanup_lines
                return ;;

            UP)
                (( start > 0 )) && start=$(( start - 1 )) ;;

            DOWN)
                total=$(_hex_total_lines)
                (( start + view < total )) && start=$(( start + 1 )) ;;

            LEFT)
                if [[ $mode == text ]] && (( hcol > 0 )); then
                    hcol=$(( hcol - 1 ))
                    _hex_render_content
                    _hex_render_hint
                fi
                continue ;;

            RIGHT)
                if [[ $mode == text ]]; then
                    hcol=$(( hcol + 1 ))
                    _hex_render_content
                    _hex_render_hint
                fi
                continue ;;

            PGUP)
                start=$(( start - view )); (( start < 0 )) && start=0 ;;

            PGDN)
                total=$(_hex_total_lines)
                start=$(( start + view ))
                (( start + view > total )) && start=$(( total - view ))
                (( start < 0 )) && start=0 ;;

            HOME)
                start=0
                [[ $mode == text ]] && hcol=0
                _hex_render_all
                continue ;;

            END)
                total=$(_hex_total_lines)
                start=$(( total - view )); (( start < 0 )) && start=0
                _hex_render_all
                continue ;;

            t|T)
                if [[ $mode == hex ]]; then
                    # 若文件很大，先提示（阈值 20 MB）
                    if (( size > 20 * 1024 * 1024 )); then
                        tui_confirm "文件较大" \
                            "该文件超过 20 MB，文本模式加载可能较慢，是否继续？" \
                            || continue
                    fi
                    _hex_switch_to_text
                    tui_clear
                    _hex_render_all
                fi
                continue ;;

            h|H)
                if [[ $mode == text ]]; then
                    _hex_switch_to_hex
                    tui_clear
                    _hex_render_all
                fi
                continue ;;

            r|R|REFRESH|RESIZE)
                _hex_layout
                tui_clear
                _hex_render_all
                continue ;;

            *) continue ;;
        esac
        (( old == start )) && continue

        if   (( start == old - 1 )); then _hex_scroll_up_one
        elif (( start == old + 1 )); then _hex_scroll_down_one
        else                               _hex_render_all
        fi
    done
}

# ============================================================================
# 目录浏览
# ============================================================================
_browse() {
    local cur=0 offset=0
    local -a paths=()
    local -a items=()
    local n=0
    local title=""
    local hint="  ↑↓ 选择  PgUp/PgDn 翻页  Home/End 首末  →/Enter 进入  ←/Backspace 上级  h 隐藏文件  r 刷新  q/Esc 退出"

    local w h top left inner col view
    local item_top sep_row hint_row

    _browse_load() {
        paths=()
        items=()

        if [[ $CURRENT_DIR != / ]]; then
            paths+=("$CURRENT_DIR/..")
            items+=("[..] 上级目录/")
        fi

        local entry name sz
        while IFS= read -r -d '' entry; do
            name=${entry##*/}
            (( ! SHOW_HIDDEN )) && [[ $name == .* ]] && continue
            paths+=("$entry")
            items+=("[D ] $name/")
        done < <(find "$CURRENT_DIR" -mindepth 1 -maxdepth 1 -type d \
                    -printf '%p\0' 2>/dev/null | LC_ALL=C sort -z)

        while IFS= read -r -d '' entry; do
            name=${entry##*/}
            (( ! SHOW_HIDDEN )) && [[ $name == .* ]] && continue
            sz=$(stat -c %s -- "$entry" 2>/dev/null || echo 0)
            paths+=("$entry")
            items+=("[F ] $name  ($(human "$sz"))")
        done < <(find "$CURRENT_DIR" -mindepth 1 -maxdepth 1 -type f \
                    -printf '%p\0' 2>/dev/null | LC_ALL=C sort -z)

        n=${#paths[@]}
        (( cur >= n )) && cur=$(( n - 1 ))
        (( cur < 0 )) && cur=0
    }

    _browse_layout() {
        tui_size
        local maxw=70
        (( maxw + 4 > TUI_COLS - 2 )) && maxw=$(( TUI_COLS - 6 ))
        w=$(( maxw + 4 ))
        # 上框(1) + 内容(view) + 分隔线(1) + 提示(1) + 下框(1)
        local fixed=4
        local max_view=$(( TUI_ROWS - 2 - fixed ))
        (( max_view < 1 )) && max_view=1
        view=$n
        (( view > max_view )) && view=$max_view
        (( view < 1 )) && view=1
        h=$(( fixed + view ))
        (( h > TUI_ROWS - 2 )) && h=$(( TUI_ROWS - 2 ))
        top=$(( (TUI_ROWS - h) / 2 )); (( top < 1 )) && top=1
        left=$(( (TUI_COLS - w) / 2 )); (( left < 1 )) && left=1
        inner=$(( w - 2 ))
        col=$(( left + 1 ))
        item_top=$(( top + 1 ))
        sep_row=$(( top + view + 1 ))
        hint_row=$(( top + view + 2 ))
        (( cur < offset ))         && offset=$cur
        (( cur >= offset + view )) && offset=$(( cur - view + 1 ))
        (( offset < 0 )) && offset=0
    }

    _browse_draw_item() {
        local srow=$1 idx=$2 sel=$3
        local st=""
        (( sel )) && st="$TUI_C_SELECT"
        tui_puts_pad $(( item_top + srow )) "$col" "$inner" "$st" " ${items[idx]}"
    }

    _browse_full() {
        tui_box "$top" "$left" "$h" "$w" "$title"
        local k idx
        if (( n == 0 )); then
            tui_puts_pad "$item_top" "$col" "$inner" "$TUI_C_HINT" "  (空目录)"
        else
            for (( k=0; k<view; k++ )); do
                idx=$(( offset + k ))
                if (( idx >= n )); then
                    tui_puts_pad $(( item_top + k )) "$col" "$inner" "" ""
                else
                    _browse_draw_item "$k" "$idx" "$(( idx == cur ))"
                fi
            done
        fi
        tui_sep "$sep_row" "$left" "$w"
        tui_puts_pad "$hint_row" "$col" "$inner" "$TUI_C_HINT" "$hint"
    }
    _browse_scroll_down() {
        # old -> cur 向下越界 1 行
        _browse_draw_item "$(( $1 - offset ))" "$1" 0
        tui_scroll_region_down "$item_top" "$(( item_top + view - 1 ))" "$col"
        offset=$3
        _browse_draw_item "$(( view - 1 ))" "$2" 1
        printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
            "$(( item_top + view - 1 ))" "$left" "$TUI_C_BORDER" "$TUI_RST" \
            "$(( item_top + view - 1 ))" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
    }
    _browse_scroll_up() {
        _browse_draw_item "$(( $1 - offset ))" "$1" 0
        tui_scroll_region_up "$item_top" "$(( item_top + view - 1 ))" "$col"
        offset=$3
        _browse_draw_item 0 "$2" 1
        printf '\e[%d;%dH%s│%s\e[%d;%dH%s│%s' \
            "$item_top" "$left" "$TUI_C_BORDER" "$TUI_RST" \
            "$item_top" "$(( left + w - 1 ))" "$TUI_C_BORDER" "$TUI_RST"
    }

    local reload=1
    local old new_offset choice
    while :; do
        if (( reload )); then
            title="$CURRENT_DIR"
            (( SHOW_HIDDEN )) && title="$title  [显示隐藏]"
            _browse_load
            _browse_layout
            tui_clear
            _browse_full
            reload=0
        fi

        tui_readkey
        if tui_check_scheme_key; then
            _browse_layout
            tui_clear
            _browse_full
            continue
        fi
        old=$cur
        case $TUI_KEY in
            ESC|q|Q)
                return ;;

            UP)
                (( cur > 0 )) && cur=$(( cur - 1 )) ;;

            DOWN)
                (( cur < n - 1 )) && cur=$(( cur + 1 )) ;;

            PGUP)
                cur=$(( cur - view )); (( cur < 0 )) && cur=0 ;;

            PGDN)
                cur=$(( cur + view )); (( cur >= n )) && cur=$(( n - 1 ))
                (( cur < 0 )) && cur=0 ;;

            HOME) cur=0 ;;
            END)  cur=$(( n - 1 )); (( cur < 0 )) && cur=0 ;;

            BACKSPACE|LEFT)
                if [[ $CURRENT_DIR != / ]]; then
                    CURRENT_DIR=$(realpath -m -- "$CURRENT_DIR/..")
                    cur=0; offset=0; reload=1
                fi ;;

            ENTER|RIGHT)
                (( n == 0 )) && continue
                choice="${paths[cur]}"
                if [[ -d $choice ]]; then
                    CURRENT_DIR=$(realpath -m -- "$choice")
                    cur=0; offset=0; reload=1
                else
                    _hex_view "$choice"
                    _browse_layout
                    tui_clear
                    _browse_full
                fi ;;

            h|H)
                SHOW_HIDDEN=$(( 1 - SHOW_HIDDEN ))
                cur=0; offset=0; reload=1 ;;

            r|R|REFRESH|RESIZE)
                _browse_layout
                tui_clear
                _browse_full ;;

            *) continue ;;
        esac
        (( reload )) && continue
        (( old == cur )) && continue

        new_offset=$offset
        (( cur < offset ))         && new_offset=$cur
        (( cur >= offset + view )) && new_offset=$(( cur - view + 1 ))
        (( new_offset < 0 )) && new_offset=0

        if (( new_offset == offset )); then
            _browse_draw_item "$(( old - offset ))" "$old" 0
            _browse_draw_item "$(( cur - offset ))" "$cur" 1
        elif (( cur == old + 1 && new_offset == offset + 1 )); then
            _browse_scroll_down "$old" "$cur" "$new_offset"
        elif (( cur == old - 1 && new_offset == offset - 1 )); then
            _browse_scroll_up "$old" "$cur" "$new_offset"
        else
            offset=$new_offset
            _browse_full
        fi
    done
}

# ============================================================================
# 入口
# ============================================================================
main() {
    local start_dir
    start_dir=$(realpath -m -- "${1:-$PWD}") || exit 1
    [[ -d $start_dir ]] || { echo "目录不存在: $start_dir" >&2; exit 1; }

    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        echo "本程序需要在交互式终端中运行" >&2
        exit 1
    fi

    # 保存原始 stdout，把 TUI 输出定向到 /dev/tty
    exec 3>&1
    exec 1>/dev/tty

    tui_init
    trap '_fm_on_exit' EXIT
    trap '_fm_on_exit; exit 130' INT TERM

    CURRENT_DIR=$start_dir
    SHOW_HIDDEN=0

    _browse

    tui_cleanup

    # 恢复原始 stdout
    exec 1>&3 3>&-

    if [[ -t 1 ]]; then
        # 直接运行：只给出提示
        printf '\n[文件管理器] 已退出。当前浏览目录:\n'
        printf '  %s\n' "$CURRENT_DIR"
        printf '如需让此终端切换到该目录，请改用:\n'
        printf '  eval "$(%s)"\n' "$0"
    else
        # 被 $(...) 捕获：输出 cd 命令，供 eval 使用
        printf 'cd %q\n' "$CURRENT_DIR"
    fi
}

main "$@"