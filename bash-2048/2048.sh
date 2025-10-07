#!/usr/bin/env bash

# 2048 :  bash edition
#  - toggleable backgrounds for performance (ENABLE_BG=0 to disable)
#  - full grid centering (both horizontal and vertical)
#  - top bar with background and "cool" text (toggleable)
#  - size percentage to control how much terminal width the grid uses (SIZE_PCT)
#  - incremental redraws only (no full-screen reprint unless needed)
#  - SIGWINCH-aware, adjustable aspect, gaps, padding, draw delay
#
# Env / runtime options:
#   ENABLE_BG   : 1 (default) draw colored backgrounds; 0 to disable (faster)
#   TOPBAR_BG   : 1 (default) draw topbar with background; 0 disables topbar bg
#   SIZE_PCT    : percent of terminal width to dedicate to the board area (default 80)
#   ASPECT      : tile height ~= CELL_W * ASPECT (default 0.5)
#   PAD         : outer padding (cols/rows) default 4
#   GAP         : inner gap between tiles (cols/rows) default 1
#   DRAW_DELAY  : optional seconds to sleep between painting rows of a tile (default 0)
#
# usage: ENABLE_BG=0 SIZE_PCT=70 ./2048.sh
#
# Dependencies: bash 4+, tput, awk (commonly present), od (for seeding)
#
set -u
shopt -s expand_aliases

ROWS=4
COLS=4
SIZE=$((ROWS * COLS))
TARGET=2048

# tunables (overridable by env)
ENABLE_BG=${ENABLE_BG:-1}
TOPBAR_BG=${TOPBAR_BG:-1}
SIZE_PCT=${SIZE_PCT:-80}
ASPECT=${ASPECT:-0.5}
PAD=${PAD:-4}
GAP=${GAP:-1}
DRAW_DELAY=${DRAW_DELAY:-0}

# runtime layout (computed)
CELL_W=7
CELL_H=1
TOPBAR_LINES=3 # topbar height (title + score + controls)
HEADER_LINES=$TOPBAR_LINES

declare -a board
declare -a prev_board

score=0
moved=0
won=0
FULL_REDRAW=1

# seed RANDOM
if [[ -r /dev/urandom ]]; then
  seed=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
  if [[ -n "$seed" ]]; then
    RANDOM=$((seed % 32768))
  fi
fi

cleanup() {
  tput cnorm >/dev/null 2>&1 || true
  stty sane >/dev/null 2>&1 || true
  printf '\e[0m'
  clear
}
trap cleanup EXIT

hide_cursor() { tput civis >/dev/null 2>&1 || true; }
show_cursor() { tput cnorm >/dev/null 2>&1 || true; }

# compute layout: SIZE_PCT controls fraction of terminal width used for board
adjust_layout() {
  local term_cols term_rows usable_w region_w avail_w desired_h max_h new_w
  term_cols=$(tput cols 2>/dev/null || echo 80)
  term_rows=$(tput lines 2>/dev/null || echo 24)

  # region width (integer)
  region_w=$((term_cols * SIZE_PCT / 100))
  if ((region_w < 10)); then region_w=10; fi

  # maximum width per cell given cols, pad and gaps
  avail_w=$((region_w - 2 * PAD - (COLS - 1) * GAP))
  if ((avail_w < COLS * 3)); then
    CELL_W=3
  else
    CELL_W=$((avail_w / COLS))
  fi
  if ((CELL_W < 3)); then CELL_W=3; fi

  # compute desired height based on ASPECT
  desired_h=$(awk -v w=$CELL_W -v a=$ASPECT 'BEGIN{h=int(w*a); if(h<1) h=1; print h}')
  max_h=$(((term_rows - TOPBAR_LINES - 2 * PAD - (ROWS - 1) * GAP) / ROWS))
  if ((max_h < 1)); then max_h=1; fi

  if ((desired_h > max_h)); then
    new_w=$(awk -v maxh=$max_h -v a=$ASPECT 'BEGIN{w=int(maxh / a); if(w<3) w=3; print w}')
    if ((new_w < CELL_W)); then
      CELL_W=$new_w
      desired_h=$(awk -v w=$CELL_W -v a=$ASPECT 'BEGIN{h=int(w*a); if(h<1) h=1; print h}')
    fi
  fi
  CELL_H=$desired_h

  BOARD_W=$((COLS * CELL_W + (COLS - 1) * GAP))
  BOARD_H=$((ROWS * CELL_H + (ROWS - 1) * GAP))

  TERM_COLS=$term_cols
  TERM_ROWS=$term_rows

  # center board horizontally and vertically (excluding topbar area)
  local available_vert=$((TERM_ROWS - TOPBAR_LINES))
  if ((available_vert < BOARD_H)); then
    ORIGIN_ROW=$((TOPBAR_LINES + 1))
  else
    ORIGIN_ROW=$((TOPBAR_LINES + 1 + (available_vert - BOARD_H) / 2))
  fi

  if ((TERM_COLS <= BOARD_W)); then
    ORIGIN_COL=1
  else
    ORIGIN_COL=$((1 + (TERM_COLS - BOARD_W) / 2))
  fi

  FULL_REDRAW=1
}

# color helpers
tile_colors_bg_idx() {
  local v=$1
  case $v in
  0) echo 236 ;;
  2) echo 230 ;;
  4) echo 223 ;;
  8) echo 216 ;;
  16) echo 208 ;;
  32) echo 202 ;;
  64) echo 196 ;;
  128) echo 129 ;;
  256) echo 127 ;;
  512) echo 99 ;;
  1024) echo 69 ;;
  2048) echo 33 ;;
  4096) echo 27 ;;
  8192) echo 21 ;;
  *)
    local idx=16
    while ((v > 1)); do
      v=$((v >> 1))
      idx=$((idx + 2))
      if ((idx > 200)); then
        idx=200
        break
      fi
    done
    echo $idx
    ;;
  esac
}

tile_fg_for_bg() {
  local bg=$1
  if ((bg >= 200)); then
    echo 16
  else
    echo 231
  fi
}

# move cursor (1-based)
move_to() { printf '\e[%d;%dH' "$1" "$2"; }

# clear rect by writing spaces (no color)
clear_rect() {
  local r=$1 c=$2 h=$3 w=$4 y
  for ((y = 0; y < h; y++)); do
    move_to $((r + y)) "$c"
    printf '%*s' "$w" ''
  done
}

# draw topbar: full width banner, with optional background and cool text
draw_topbar() {
  local bg_seq reset_seq fg_seq title controls score_line term_w row
  term_w=$TERM_COLS
  title="  2 0 4 8   —   bash  edition   "
  controls="  Controls: w a s d  h j k l  or  arrows    r restart    q quit  "
  score_line="  Score: ${score}  "
  reset_seq="\e[0m"

  if [[ "${ENABLE_BG:-1}" -eq 1 && "${TOPBAR_BG:-1}" -eq 1 ]]; then
    # pick a pleasant bg and fg
    bg_seq="\e[48;5;24m"
    fg_seq="\e[38;5;231m"
  else
    bg_seq=""
    fg_seq=""
  fi

  # row 1: title centered with bg
  row=1
  move_to $row 1
  printf '%b' "${bg_seq}"
  # fill entire row
  printf '%*s' "$term_w" ''
  printf '%b' "$reset_seq"

  # place title centered
  local tlen=${#title}
  local tcol=$(((term_w - tlen) / 2 + 1))
  move_to $row $tcol
  printf '%b%s%b' "${bg_seq}${fg_seq}" "$title" "${reset_seq}"

  # row 2: score + controls (left aligned)
  row=2
  move_to $row 1
  printf '%b' "${bg_seq}"
  printf '%*s' "$term_w" ''
  printf '%b' "$reset_seq"

  move_to $row 2
  printf '%b%s%b' "${bg_seq}${fg_seq}" "$score_line" "${reset_seq}"

  # controls aligned to the right-ish
  local clen=${#controls}
  local cpos=$((term_w - clen - 1))
  if ((cpos < 2)); then cpos=2; fi
  move_to $row $cpos
  printf '%b%s%b' "${bg_seq}${fg_seq}" "$controls" "${reset_seq}"

  # row 3: separator (optional)
  row=3
  move_to $row 1
  printf '%b' "${bg_seq}"
  printf '%*s' "$term_w" ''
  printf '%b' "$reset_seq"
}

# draw a single cell (rr cc zero-based).  force=1 forces redraw even if unchanged.
draw_cell() {
  local rr=$1 cc=$2 force=${3:-0}
  local idx=$((rr * COLS + cc))
  local val=${board[idx]:-0}
  local prev=${prev_board[idx]:-__NONE__}

  if [[ $force -eq 0 && "${prev}" == "${val}" ]]; then
    return
  fi

  local top=$((ORIGIN_ROW + rr * (CELL_H + GAP)))
  local left=$((ORIGIN_COL + cc * (CELL_W + GAP)))
  if ((top < 1)); then top=1; fi
  if ((left < 1)); then left=1; fi

  local bg_idx fg_idx bg_seq fg_seq reset_seq
  bg_idx=$(tile_colors_bg_idx "$val")
  fg_idx=$(tile_fg_for_bg "$bg_idx")
  reset_seq="\e[0m"

  if [[ "${ENABLE_BG:-1}" -eq 1 ]]; then
    bg_seq="\e[48;5;${bg_idx}m"
    fg_seq="\e[38;5;${fg_idx}m"
  else
    bg_seq=""
    fg_seq=""
  fi

  local mid_row=$((CELL_H / 2))
  local txt=""
  if ((val != 0)); then txt="$val"; fi

  local y
  for ((y = 0; y < CELL_H; y++)); do
    move_to $((top + y)) "$left"
    if [[ -z "$txt" ]]; then
      if [[ -n "$bg_seq" ]]; then
        printf '%b' "$bg_seq"
        printf '%*s' "$CELL_W" ''
        printf '%b' "$reset_seq"
      else
        printf '%*s' "$CELL_W" ''
      fi
    else
      if ((y == mid_row)); then
        local tlen=${#txt}
        local leftpad=$(((CELL_W - tlen) / 2))
        local rightpad=$((CELL_W - tlen - leftpad))
        if [[ -n "$bg_seq" ]]; then
          printf '%b' "${bg_seq}${fg_seq}"
          printf '%*s' "$leftpad" ''
          printf '%s' "$txt"
          printf '%*s' "$rightpad" ''
          printf '%b' "$reset_seq"
        else
          printf '%*s%s%*s' "$leftpad" '' "$txt" "$rightpad" ''
        fi
      else
        if [[ -n "$bg_seq" ]]; then
          printf '%b' "$bg_seq"
          printf '%*s' "$CELL_W" ''
          printf '%b' "$reset_seq"
        else
          printf '%*s' "$CELL_W" ''
        fi
      fi
    fi

    # optional micro pause for dramatic incremental painting
    if awk "BEGIN{exit !($DRAW_DELAY > 0)}"; then
      sleep "$DRAW_DELAY"
    fi
  done

  prev_board[idx]=$val
}

# full draw (topbar + all cells)
full_draw() {
  clear
  draw_topbar
  local r c
  for ((r = 0; r < ROWS; r++)); do
    for ((c = 0; c < COLS; c++)); do
      draw_cell "$r" "$c" 1
    done
  done
  FULL_REDRAW=0
}

# incremental update: topbar + changed cells
update_draw() {
  draw_topbar
  local i
  for ((i = 0; i < SIZE; i++)); do
    if [[ "${prev_board[i]:-__NONE__}" != "${board[i]:-0}" || "${FULL_REDRAW:-0}" -eq 1 ]]; then
      local rr=$((i / COLS))
      local cc=$((i % COLS))
      draw_cell "$rr" "$cc" 1
    fi
  done
  FULL_REDRAW=0
}

# board helpers (indexing, manipulation)
get_idx() { echo $(($1 * COLS + $2)); }

get_cell() {
  local r=$1 c=$2 i=$((r * COLS + c))
  printf '%d' "${board[i]:-0}"
}

set_cell() {
  local r=$1 c=$2 v=${3:-0} i=$((r * COLS + c))
  board[i]=$v
}

random_empty_index() {
  local empties=()
  for ((i = 0; i < SIZE; i++)); do
    if ((${board[i]:-0} == 0)); then
      empties+=("$i")
    fi
  done
  if ((${#empties[@]} == 0)); then
    return 1
  fi
  local pick=$((RANDOM % ${#empties[@]}))
  printf '%d' "${empties[pick]}"
  return 0
}

add_random_tile() {
  local idx
  idx=$(random_empty_index) || return 1
  if ((RANDOM % 10 == 0)); then
    board[idx]=4
  else
    board[idx]=2
  fi
  return 0
}

init_board() {
  for ((i = 0; i < SIZE; i++)); do
    board[i]=0
    prev_board[i]=-1
  done
  score=0
  won=0
  add_random_tile >/dev/null 2>&1 || true
  add_random_tile >/dev/null 2>&1 || true
  adjust_layout
  FULL_REDRAW=1
}

center_pad() {
  local w=$1 text=${2:-}
  local tlen=${#text}
  if ((tlen >= w)); then
    printf '%s' "${text:0:w}"
    return
  fi
  local left=$(((w - tlen) / 2))
  local right=$((w - tlen - left))
  printf '%*s%s%*s' "$left" '' "$text" "$right" ''
}

compress_and_merge_line() {
  local a0=${1:-0}
  local a1=${2:-0}
  local a2=${3:-0}
  local a3=${4:-0}
  local arr=("$a0" "$a1" "$a2" "$a3")
  local tmp=()
  local i

  for ((i = 0; i < 4; i++)); do
    if ((${arr[i]:-0} != 0)); then
      tmp+=("${arr[i]}")
    fi
  done

  local out=()
  i=0
  while ((i < ${#tmp[@]})); do
    if ((i + 1 < ${#tmp[@]})) && ((tmp[i] == tmp[i + 1])); then
      local new=$((tmp[i] * 2))
      out+=("$new")
      score=$((score + new))
      i=$((i + 2))
    else
      out+=("${tmp[i]}")
      i=$((i + 1))
    fi
  done

  while ((${#out[@]} < COLS)); do
    out+=(0)
  done

  moved=0
  for ((i = 0; i < COLS; i++)); do
    if ((out[i] != arr[i])); then
      moved=1
      break
    fi
  done

  printf '%d %d %d %d' "${out[0]}" "${out[1]}" "${out[2]}" "${out[3]}"
  return 0
}

reverse_four() {
  printf '%d %d %d %d' "${4:-0}" "${3:-0}" "${2:-0}" "${1:-0}"
}

do_move_left() {
  moved=0
  for ((r = 0; r < ROWS; r++)); do
    local base=$((r * COLS))
    local a0=${board[base + 0]:-0}
    local a1=${board[base + 1]:-0}
    local a2=${board[base + 2]:-0}
    local a3=${board[base + 3]:-0}
    read -r n0 n1 n2 n3 < <(compress_and_merge_line "$a0" "$a1" "$a2" "$a3")
    board[base + 0]=$n0
    board[base + 1]=$n1
    board[base + 2]=$n2
    board[base + 3]=$n3
  done
  return 0
}

do_move_right() {
  moved=0
  for ((r = 0; r < ROWS; r++)); do
    local base=$((r * COLS))
    local a0=${board[base + 0]:-0}
    local a1=${board[base + 1]:-0}
    local a2=${board[base + 2]:-0}
    local a3=${board[base + 3]:-0}
    read -r r0 r1 r2 r3 < <(reverse_four "$a0" "$a1" "$a2" "$a3")
    read -r n0 n1 n2 n3 < <(compress_and_merge_line "$r0" "$r1" "$r2" "$r3")
    board[base + 0]=$n3
    board[base + 1]=$n2
    board[base + 2]=$n1
    board[base + 3]=$n0
  done
  return 0
}

do_move_up() {
  moved=0
  for ((c = 0; c < COLS; c++)); do
    local a0=${board[0 * COLS + c]:-0}
    local a1=${board[1 * COLS + c]:-0}
    local a2=${board[2 * COLS + c]:-0}
    local a3=${board[3 * COLS + c]:-0}
    read -r n0 n1 n2 n3 < <(compress_and_merge_line "$a0" "$a1" "$a2" "$a3")
    board[0 * COLS + c]=$n0
    board[1 * COLS + c]=$n1
    board[2 * COLS + c]=$n2
    board[3 * COLS + c]=$n3
  done
  return 0
}

do_move_down() {
  moved=0
  for ((c = 0; c < COLS; c++)); do
    local a0=${board[0 * COLS + c]:-0}
    local a1=${board[1 * COLS + c]:-0}
    local a2=${board[2 * COLS + c]:-0}
    local a3=${board[3 * COLS + c]:-0}
    read -r r0 r1 r2 r3 < <(reverse_four "$a0" "$a1" "$a2" "$a3")
    read -r n0 n1 n2 n3 < <(compress_and_merge_line "$r0" "$r1" "$r2" "$r3")
    board[0 * COLS + c]=$n3
    board[1 * COLS + c]=$n2
    board[2 * COLS + c]=$n1
    board[3 * COLS + c]=$n0
  done
  return 0
}

can_move() {
  for ((i = 0; i < SIZE; i++)); do
    if ((${board[i]:-0} == 0)); then
      return 0
    fi
  done
  for ((r = 0; r < ROWS; r++)); do
    for ((c = 0; c < COLS - 1; c++)); do
      local a=${board[r * COLS + c]:-0}
      local b=${board[r * COLS + c + 1]:-0}
      if ((a == b)); then
        return 0
      fi
    done
  done
  for ((r = 0; r < ROWS - 1; r++)); do
    for ((c = 0; c < COLS; c++)); do
      local a=${board[r * COLS + c]:-0}
      local b=${board[(r + 1) * COLS + c]:-0}
      if ((a == b)); then
        return 0
      fi
    done
  done
  return 1
}

check_win() {
  for v in "${board[@]}"; do
    if ((v >= TARGET)); then
      won=1
      return 0
    fi
  done
  return 1
}

read_key() {
  local key rest
  IFS= read -rsn1 key 2>/dev/null || return 0
  if [[ $key == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.0005 rest 2>/dev/null || rest=''
    key+="$rest"
  fi

  case "$key" in
  $'\x1b[A') echo up ;;
  $'\x1b[B') echo down ;;
  $'\x1b[C') echo right ;;
  $'\x1b[D') echo left ;;
  w | W | k | K) echo up ;;
  s | S | j | J) echo down ;;
  a | A | h | H) echo left ;;
  d | D | l | L) echo right ;;
  q | Q) echo quit ;;
  r | R) echo restart ;;
  *) echo unknown ;;
  esac
  return 0
}

on_winch() {
  adjust_layout
  FULL_REDRAW=1
}
trap on_winch SIGWINCH

main_loop() {
  hide_cursor
  while true; do
    if ((FULL_REDRAW)); then
      full_draw
    else
      update_draw
    fi

    check_win

    if ! can_move; then
      move_to $((ORIGIN_ROW + BOARD_H + 2)) 1
      printf '\n  no moves left.  you lost.  r to restart  q to quit\n'
      while true; do
        k=$(read_key)
        if [[ $k == restart ]]; then
          init_board
          break
        elif [[ $k == quit ]]; then
          exit 0
        fi
      done
      continue
    fi

    local before_state after_state
    before_state="$(printf '%s ' "${board[@]}")"

    k=$(read_key)
    case "$k" in
    up) do_move_up ;;
    down) do_move_down ;;
    left) do_move_left ;;
    right) do_move_right ;;
    restart)
      init_board
      continue
      ;;
    quit) exit 0 ;;
    *) continue ;;
    esac

    after_state="$(printf '%s ' "${board[@]}")"

    if [[ "$before_state" != "$after_state" ]]; then
      add_random_tile >/dev/null 2>&1 || true
    fi

    FULL_REDRAW=0
  done
}

# start
clear
init_board
main_loop
