#!/bin/bash

# ===============================================
# MINI-VIM BASH EDITOR - FUNCTIONAL VERSION
# features: normal/insert, hjkl/arrows, dd, :w/:wq/:q/:q!
# horizontal scroll, open file, save-as, max verbosity/debug output
# / search mode, n/N navigation, b/e word motions
# syntax highlighting: strings & functions
# auto-indent
# ===============================================

filename="$1"
lines=("")
rendered_lines=()
current_line=0
current_col=0
col_offset=0
top_line=0
mode="NORMAL"
numcol=6
prev_key=""
status_msg=""
status_type="info" # info, warn, error
search_query=""
search_matches=()
current_match_index=0

# --meow feature
if [[ "$1" == "--meow" ]]; then
  if grep -q "meow" "$0"; then
    echo "meow"
  else
    echo "no meow found"
  fi
  exit
fi

# ======================
# UTILS
# ======================

log_status() {
  status_type="$1"
  status_msg="$2"
}

save_file() {
  local target="${1:-$filename}"
  if [[ -z "$target" ]]; then
    log_status "warn" "WARNING! file not set!"
    return 1
  fi
  printf '%s\n' "${lines[@]}" >"$target" 2>/dev/null
  if [[ $? -eq 0 ]]; then
    log_status "info" "File saved to '$target'"
  else
    log_status "error" "ERROR! Failed to save file to '$target'"
  fi
}

cleanup() {
  tput cnorm
  printf '\e[?25h'
  stty sane
  tput cup $(tput lines) 0
  echo -e "\nEditor exited."
  exit
}

ensure_line_exists() {
  ((${#lines[@]} == 0)) && lines+=("")
  ((current_line >= ${#lines[@]})) && current_line=$((${#lines[@]} - 1))
  ((current_line < 0)) && current_line=0
}

clamp_display() {
  local rows cols max_visible
  cols=$(tput cols)
  rows=$(tput lines)
  max_visible=$((rows - 2))
  ((top_line > current_line)) && top_line=$current_line
  ((current_line > top_line + max_visible)) && top_line=$((current_line - max_visible))
}

clamp_horizontal() {
  local cols max_text
  cols=$(tput cols)
  max_text=$((cols - numcol))
  ((max_text < 0)) && max_text=0
  ((current_col < col_offset)) && col_offset=$current_col
  ((current_col - col_offset > max_text)) && col_offset=$((current_col - max_text))
  ((col_offset < 0)) && col_offset=0
}

# ======================
# SYNTAX HIGHLIGHTING
# ======================

syntax_color() {
  local word="$1"
  local color="\e[0m"
  case "$word" in
  \"*\" | \'*\') color="\e[32m" ;; # strings green
  *\(\)) color="\e[36m" ;;         # functions cyan
  *) color="\e[0m" ;;
  esac
  echo -n "$color$word\e[0m"
}

build_rendered() {
  local i words w line hl
  rendered_lines=()
  for i in "${!lines[@]}"; do
    line="${lines[i]}"
    hl=""
    words=($line)
    for w in "${words[@]}"; do
      hl+=$(syntax_color "$w")" "
    done
    rendered_lines[i]="$hl"
  done
}

# ======================
# DRAW FUNCTION
# ======================

draw() {
  local cols rows max_visible max_text end_line printed_lines display_row display_col line visible
  cols=$(tput cols)
  rows=$(tput lines)
  max_visible=$((rows - 2))
  max_text=$((cols - numcol))
  ((max_text < 0)) && max_text=0

  printf '\e[?25l'
  tput civis
  printf '\e[H'

  build_rendered

  end_line=$((top_line + max_visible))
  ((end_line >= ${#lines[@]})) && end_line=$((${#lines[@]} - 1))

  for ((i = top_line; i <= end_line; i++)); do
    n=$((i + 1))
    line="${rendered_lines[i]}"
    visible="${line:col_offset:max_text}"
    printf "%3d | %b\e[K\n" "$n" "$visible"
  done

  printed_lines=$((end_line - top_line + 1))
  while ((printed_lines < max_visible)); do
    printf "\e[K\n"
    ((printed_lines++))
  done

  # STATUS BAR
  tput cup $((rows - 1)) 0
  printf "\e[K"
  case "$status_type" in
  info) echo -n "[INFO] " ;;
  warn) echo -n "[WARN] " ;;
  error) echo -n "[ERROR] " ;;
  esac
  echo -n "$status_msg | mode: $mode ln: $((current_line + 1))/${#lines[@]} col: $current_col offs: $col_offset"
  printf "\e[K"

  display_row=$((current_line - top_line))
  ((display_row < 0)) && display_row=0
  display_col=$((current_col - col_offset))
  ((display_col < 0)) && display_col=0
  ((display_col > max_text)) && display_col=$max_text

  tput cup $display_row $((display_col + numcol))
  tput cnorm
  printf '\e[?25h'
}

# ======================
# FILE HANDLING
# ======================

load_file() {
  if [[ -n "$filename" && -f "$filename" ]]; then
    mapfile -t lines <"$filename"
    log_status "info" "Loaded file '$filename' with ${#lines[@]} lines."
  else
    log_status "warn" "No file loaded. Start typing!"
  fi
  printf '\e[2J'
}

# ======================
# SEARCH
# ======================

search() {
  search_matches=()
  current_match_index=0
  for i in "${!lines[@]}"; do
    line="${lines[i]}"
    pos=0
    while [[ "$line" == *"$search_query"* ]]; do
      idx=$(expr index "$line" "$search_query")
      ((idx--))
      search_matches+=("$i:$idx")
      line="${line:idx+1}"
    done
  done
  if ((${#search_matches[@]} > 0)); then
    IFS=: read current_line current_col <<<"${search_matches[0]}"
    log_status "info" "Found ${#search_matches[@]} matches for '$search_query'"
  else
    log_status "warn" "No matches found for '$search_query'"
  fi
}

next_match() {
  if ((${#search_matches[@]} > 0)); then
    ((current_match_index = (current_match_index + 1) % ${#search_matches[@]}))
    IFS=: read current_line current_col <<<"${search_matches[current_match_index]}"
    log_status "info" "Jumped to match $((current_match_index + 1)) of ${#search_matches[@]}"
  fi
}

prev_match() {
  if ((${#search_matches[@]} > 0)); then
    ((current_match_index = (current_match_index - 1 + ${#search_matches[@]}) % ${#search_matches[@]}))
    IFS=: read current_line current_col <<<"${search_matches[current_match_index]}"
    log_status "info" "Jumped to match $((current_match_index + 1)) of ${#search_matches[@]}"
  fi
}

# ======================
# WORD MOTIONS
# ======================

move_word_end() {
  line="${lines[$current_line]}"
  remainder="${line:$current_col}"
  if [[ "$remainder" =~ [^[:space:]]+[[:space:]]* ]]; then
    word="${BASH_REMATCH[0]}"
    ((current_col += ${#word}))
  else
    current_col=${#line}
  fi
}

move_word_start() {
  if ((current_col == 0)); then
    ((current_line > 0)) && ((current_line--)) && current_col=${#lines[$current_line]}
    return
  fi
  line="${lines[$current_line]:0:current_col}"
  reversed=$(echo "$line" | rev)
  if [[ "$reversed" =~ [^[:space:]]+[[:space:]]* ]]; then
    word="${BASH_REMATCH[0]}"
    ((current_col -= ${#word}))
  else
    current_col=0
  fi
}

# ======================
# NORMAL MODE HANDLERS
# ======================

handle_normal_mode() {
  case "$key" in
  d) prev_key="d" ;;
  i)
    mode="INSERT"
    log_status "info" "Switched to INSERT mode"
    ;;
  h) ((current_col > 0)) && ((current_col--)) ;;
  l) ((current_col < ${#lines[$current_line]})) && ((current_col++)) ;;
  j)
    ((current_line < ${#lines[@]} - 1)) && ((current_line++))
    ((current_col > ${#lines[$current_line]})) && current_col=${#lines[$current_line]}
    ;;
  k)
    ((current_line > 0)) && ((current_line--))
    ((current_col > ${#lines[$current_line]})) && current_col=${#lines[$current_line]}
    ;;
  e) move_word_end ;;
  b) move_word_start ;;
  '/')
    tput cup $(($(tput lines) - 1)) 0
    printf "\e[K/"
    read -r search_query
    search
    ;;
  n) next_match ;;
  N) prev_match ;;
  ':')
    tput cup $(($(tput lines) - 1)) 0
    printf "\e[K:"
    read -r cmd args
    case "$cmd" in
    w) save_file "$args" ;;
    wq)
      save_file "$args"
      cleanup
      ;;
    q) cleanup ;;
    q!) cleanup ;;
    *) log_status "error" "Unknown command :$cmd" ;;
    esac
    ;;
  $'\x03') cleanup ;;
  $'\x1b')
    read -rsn2 -t 0.01 key2
    case "$key2" in
    '[A') ((current_line > 0)) && ((current_line--)) ;;
    '[B') ((current_line < ${#lines[@]} - 1)) && ((current_line++)) ;;
    '[C') ((current_col < ${#lines[$current_line]})) && ((current_col++)) ;;
    '[D') ((current_col > 0)) && ((current_col--)) ;;
    esac
    ;;
  *) prev_key="" ;;
  esac
}

# ======================
# INSERT MODE HANDLERS
# ======================

handle_insert_mode() {
  case "$key" in
  $'\x1b')
    mode="NORMAL"
    log_status "info" "Switched to NORMAL mode"
    ;;
  $'\x7f') # backspace
    if ((current_col > 0)); then
      lines[$current_line]="${lines[$current_line]:0:current_col-1}${lines[$current_line]:current_col}"
      ((current_col--))
      log_status "info" "Deleted char at col $current_col"
    elif ((current_col == 0 && current_line > 0)); then
      prev_len=${#lines[$((current_line - 1))]}
      lines[$((current_line - 1))]="${lines[$((current_line - 1))]}${lines[$current_line]}"
      unset 'lines[current_line]'
      lines=("${lines[@]}")
      ((current_line--))
      current_col=$prev_len
      log_status "info" "Merged line $((current_line + 2)) with previous"
    fi ;;
  $'\x00' | $'\x0a' | $'\x0d') # enter with auto-indent
    rest="${lines[$current_line]:$current_col}"
    current_indent=$(echo "${lines[$current_line]}" | sed -E 's/^([[:space:]]*).*/\1/')
    lines[$current_line]="${lines[$current_line]:0:$current_col}"
    lines=("${lines[@]:0:$((current_line + 1))}" "$current_indent$rest" "${lines[@]:$((current_line + 1))}")
    ((current_line++))
    current_col=${#current_indent}
    log_status "info" "Inserted newline with indent at line $current_line"
    ;;
  $'\x03') cleanup ;;
  *) # insert char
    lines[$current_line]="${lines[$current_line]:0:$current_col}$key${lines[$current_line]:$current_col}"
    ((current_col++))
    log_status "info" "Inserted '$key' at col $current_col"
    ;;
  esac
}

# ======================
# MAIN LOOP
# ======================

load_file
printf '\e[2J'

while true; do
  ensure_line_exists
  clamp_display
  clamp_horizontal
  draw

  IFS= read -rsn1 key || break

  if [[ $mode == "NORMAL" ]]; then
    if [[ "$prev_key" == "d" && "$key" == "d" ]]; then
      log_status "info" "Deleting line $((current_line + 1))"
      unset 'lines[current_line]'
      lines=("${lines[@]}")
      ((${#lines[@]} == 0)) && lines+=("")
      ((current_line >= ${#lines[@]})) && ((current_line--))
      current_col=0
      prev_key=""
      continue
    fi
    handle_normal_mode
  else
    handle_insert_mode
  fi
done
