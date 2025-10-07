#!/usr/bin/env python3
# terminal-desktop-launcher-v6-dark.py
# Changes requested by user:
#  - q / Q do not close the launcher; they can be typed into the query
#  - preview pane shows only the Exec (command path)
#  - remove duplicate bottom lines; single-line dark bar (tmux-like)
#  - dark mode: black background, white text for powerline
#  - simplified help text: esc to quit

from __future__ import annotations

import curses
import glob
import os
import re
import shlex
import shutil
import subprocess
import sys
import textwrap
from configparser import ConfigParser
from dataclasses import dataclass
from typing import List, Optional, Tuple

# ------------------
# user config
# ------------------
DESKTOP_PATHS = [
    os.path.expanduser("~/.local/share/applications"),
    "/usr/share/applications",
    "/usr/local/share/applications",
]
TERMINAL_CANDIDATES = [
    "kitty",
    "alacritty",
    "st",
    "xterm",
    "urxvt",
    "gnome-terminal",
    "konsole",
]
PREFER_TERMINAL_FOR_TERMINAL_ENTRIES = True


@dataclass
class DesktopEntry:
    name: str
    exec: str
    comment: str
    terminal: bool
    path: str
    no_display: bool
    categories: str


def find_terminal() -> Optional[str]:
    for t in TERMINAL_CANDIDATES:
        p = shutil.which(t)
        if p:
            return p
    return None


def sanitize_exec_field(exec_field: str) -> str:
    s = exec_field
    s = re.sub(r"%[a-zA-Z@]", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def clean_text(s: str) -> str:
    if not s:
        return ""
    s = "".join(ch for ch in s if ch.isprintable())
    s = re.sub(r"\s+", " ", s).strip()
    return s


def parse_desktop_file(path: str) -> Optional[DesktopEntry]:
    try:
        cfg = ConfigParser(interpolation=None)
        with open(path, errors="ignore") as fh:
            cfg.read_file(fh)
        if "Desktop Entry" not in cfg:
            return None
        sec = cfg["Desktop Entry"]
        no_display = sec.getboolean("NoDisplay", fallback=False)
        name = sec.get("Name", fallback=os.path.splitext(os.path.basename(path))[0])
        exec_field = sec.get("Exec", fallback="")
        if not exec_field:
            return None
        comment = sec.get("Comment", fallback="")
        terminal = sec.getboolean("Terminal", fallback=False)
        categories = sec.get("Categories", fallback="")
        exec_clean = sanitize_exec_field(exec_field)
        comment_clean = clean_text(comment)
        return DesktopEntry(
            name=name,
            exec=exec_clean,
            comment=comment_clean,
            terminal=terminal,
            path=path,
            no_display=no_display,
            categories=categories,
        )
    except Exception:
        return None


def collect_desktop_entries(paths: List[str]) -> List[DesktopEntry]:
    seen_names = set()
    entries: List[DesktopEntry] = []
    for base in paths:
        try:
            pattern = os.path.join(base, "*.desktop")
            for p in glob.glob(pattern):
                d = parse_desktop_file(p)
                if not d:
                    continue
                if d.no_display:
                    continue
                if d.name in seen_names:
                    continue
                seen_names.add(d.name)
                entries.append(d)
        except Exception:
            continue
    entries.sort(key=lambda x: x.name.lower())
    return entries


# fuzzy scoring: lower is better
def fuzzy_score(query: str, text: str) -> Optional[int]:
    q = query.lower()
    t = text.lower()
    if not q:
        return 0
    if t.startswith(q):
        return 0
    i = 0
    score = 0
    for ch in q:
        pos = t.find(ch, i)
        if pos == -1:
            return None
        score += pos - i
        i = pos + 1
    score += len(t) - len(q)
    return score


class LauncherUI:
    def __init__(self, stdscr, entries: List[DesktopEntry]):
        self.stdscr = stdscr
        self.entries = entries
        self.query = ""
        self.filtered: List[Tuple[DesktopEntry, int]] = []
        self.selected = 0
        self.terminal = find_terminal()

        try:
            curses.curs_set(1)
        except Exception:
            pass
        curses.use_default_colors()
        if curses.has_colors():
            curses.start_color()
            # minimal dark palette
            curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLACK)  # powerline
            curses.init_pair(2, curses.COLOR_YELLOW, -1)  # prompt
            curses.init_pair(3, curses.COLOR_MAGENTA, -1)  # exec text in list
        self.update_filter()

    def safe_add(self, y: int, x: int, s: str, attr=0):
        try:
            self.stdscr.addstr(y, x, s, attr)
        except Exception:
            try:
                maxw = max(0, self.stdscr.getmaxyx()[1] - x)
                if maxw > 0:
                    self.stdscr.addstr(y, x, s[:maxw], attr)
            except Exception:
                pass

    def update_filter(self):
        q = self.query.strip()
        scored = []
        for e in self.entries:
            texts = [e.name, e.comment, e.categories, e.exec]
            best: Optional[int] = None
            for t in texts:
                s = fuzzy_score(q, t)
                if s is None:
                    continue
                if best is None or s < best:
                    best = s
            if best is not None:
                scored.append((e, best))
        scored.sort(key=lambda x: (x[1], x[0].name.lower()))
        self.filtered = scored
        if self.selected >= len(self.filtered):
            self.selected = max(0, len(self.filtered) - 1)

    def draw_powerline(self, h: int, w: int):
        # fill entire bottom line to prevent any overlap
        left = " hsd! "
        sel_exec = "-"
        if self.filtered:
            cur = self.filtered[self.selected][0]
            sel_exec = cur.exec or "-"
        sel_exec = clean_text(sel_exec)

        # compute how much space to reserve for exec on right
        right_space = max(0, w - (len(left) + 4))
        if len(sel_exec) > right_space:
            if right_space >= 4:
                sel_exec = sel_exec[: right_space - 3] + "..."
            else:
                sel_exec = sel_exec[: right_space]

        if curses.has_colors():
            attr = curses.color_pair(1) | curses.A_BOLD
            # fill whole last line with powerline background
            try:
                self.safe_add(h - 1, 0, " " * max(0, w - 1), attr)
            except Exception:
                pass
            # left label
            self.safe_add(h - 1, 1, left, attr)
            # right-justified exec
            rx = max(len(left) + 2, w - len(sel_exec) - 2)
            rx = min(max(0, rx), max(0, w - 1))
            self.safe_add(h - 1, rx, sel_exec, attr)
        else:
            self.safe_add(h - 1, 0, f" {left} ")
            rx = max(0, w - (len(sel_exec) + 1))
            self.safe_add(h - 1, rx, sel_exec)

    def draw(self):
        self.stdscr.erase()
        h, w = self.stdscr.getmaxyx()

        # --- input line
        prompt = "filter: "
        if curses.has_colors():
            self.safe_add(0, 0, prompt, curses.color_pair(2) | curses.A_BOLD)
        else:
            self.safe_add(0, 0, prompt)
        max_query_w = max(0, w - len(prompt) - 1)
        q_draw = (self.query[-max_query_w:])
        # ensure the rest of the input line is clean
        try:
            self.stdscr.move(0, len(prompt))
            self.stdscr.clrtoeol()
        except Exception:
            pass
        self.safe_add(0, len(prompt), q_draw)

        # layout columns
        split = max(20, int(w * 0.45))
        split = min(split, max(20, w - 20))  # keep some room for preview on tiny screens
        list_h = max(1, h - 3)

        # --- list area: explicitly clear each line and draw left + exec columns
        for idx in range(list_h):
            y = 1 + idx
            # clear line
            try:
                self.stdscr.move(y, 0)
                self.stdscr.clrtoeol()
            except Exception:
                pass

            if idx >= len(self.filtered):
                continue

            e, score = self.filtered[idx]
            name = e.name
            left_text = f" {name}"
            left_col_width = max(0, split - 1)

            # left column (pad to fixed width so it cannot overlap)
            left_draw = left_text[:left_col_width]
            if len(left_draw) < left_col_width:
                left_draw = left_draw + " " * (left_col_width - len(left_draw))
            if idx == self.selected:
                try:
                    self.safe_add(y, 0, left_draw, curses.A_REVERSE)
                except Exception:
                    self.safe_add(y, 0, left_draw)
            else:
                self.safe_add(y, 0, left_draw)

            # right column: exec preview (pad/trim to available width)
            exec_show = e.exec or "-"
            exec_col_x = split + 1
            exec_col_width = max(0, w - exec_col_x - 1)
            exec_draw = exec_show[: exec_col_width]
            if len(exec_draw) < exec_col_width:
                exec_draw = exec_draw + " " * (exec_col_width - len(exec_draw))
            if curses.has_colors():
                self.safe_add(y, exec_col_x, exec_draw, curses.color_pair(3))
            else:
                self.safe_add(y, exec_col_x, exec_draw)

        # --- preview pane: vertical separator and preview text
        preview_x = split + 1
        # draw vertical separator that stops above footer/powerline
        try:
            sep_height = max(0, h - 3)
            self.stdscr.vline(1, preview_x - 1, ord('|'), sep_height)
        except Exception:
            pass

        # clear preview area lines before drawing wrapped exec
        preview_width = max(10, w - preview_x - 2)
        for i in range(0, max(0, h - 3)):
            yy = 1 + i
            try:
                self.stdscr.move(yy, preview_x)
                # clear only the preview area to avoid touching list area
                self.safe_add(yy, preview_x, " " * max(0, preview_width))
            except Exception:
                pass

        if self.filtered:
            cur = self.filtered[self.selected][0]
            exec_lines = textwrap.wrap(cur.exec, width=max(10, preview_width)) if cur.exec else ["-"]
            for i, pl in enumerate(exec_lines[: h - 3]):
                self.safe_add(1 + i, preview_x + 1, pl)

        # --- footer help (kept one line above powerline) - clear first
        footer_y = max(0, h - 2)
        try:
            self.stdscr.move(footer_y, 0)
            self.stdscr.clrtoeol()
        except Exception:
            pass
        footer = ""
        self.safe_add(footer_y, 0, footer[: w - 1])

        # --- bottom powerline
        self.draw_powerline(h, w)

        # restore cursor position on input
        try:
            self.stdscr.move(0, len(prompt) + min(len(self.query), max_query_w))
        except Exception:
            pass
        self.stdscr.refresh()

    def run(self):
        while True:
            self.draw()
            ch = self.stdscr.get_wch()
            if isinstance(ch, str):
                if ch == "\n":
                    if not self.filtered:
                        continue
                    entry = self.filtered[self.selected][0]
                    self.launch(entry, in_terminal=False)
                    return
                elif ch == "\x1b":
                    return
                elif ch == "\t":
                    continue
                elif ch in ("\x7f", "\b", "\x08", "\u007f"):
                    self.query = self.query[:-1]
                    self.update_filter()
                else:
                    # allow typing q / Q; do not exit on q
                    if ch.isprintable():
                        self.query += ch
                        self.update_filter()
            else:
                if ch in (curses.KEY_BACKSPACE,):
                    self.query = self.query[:-1]
                    self.update_filter()
                elif ch == curses.KEY_UP:
                    self.selected = max(0, self.selected - 1)
                elif ch == curses.KEY_DOWN:
                    self.selected = min(max(0, len(self.filtered) - 1), self.selected + 1)
                elif ch == curses.KEY_NPAGE:
                    self.selected = min(len(self.filtered) - 1, self.selected + 10)
                elif ch == curses.KEY_PPAGE:
                    self.selected = max(0, self.selected - 10)

    def launch(self, entry: DesktopEntry, in_terminal: bool):
        raw_cmd = entry.exec.strip()
        if not raw_cmd:
            return
        quoted = shlex.quote(raw_cmd)
        detached_cmd = f"setsid sh -c {quoted} >/dev/null 2>&1 < /dev/null &"

        if in_terminal or (entry.terminal and PREFER_TERMINAL_FOR_TERMINAL_ENTRIES):
            term = self.terminal
            if not term:
                subprocess.Popen(["sh", "-c", detached_cmd])
                return
            else:
                tried = False
                attempts = [
                    [term, "-e", "sh", "-c", detached_cmd],
                    [term, "-e", detached_cmd],
                ]
                for args in attempts:
                    try:
                        subprocess.Popen(args)
                        tried = True
                        break
                    except Exception:
                        continue
                if not tried:
                    subprocess.Popen(["sh", "-c", detached_cmd])
                return
        else:
            subprocess.Popen(["sh", "-c", detached_cmd])
            return


def main(stdscr):
    entries = collect_desktop_entries(DESKTOP_PATHS)
    if not entries:
        stdscr.addstr(0, 0, "no .desktop entries found in paths.\n")
        stdscr.refresh()
        curses.napms(1500)
        return
    ui = LauncherUI(stdscr, entries)
    ui.run()


if __name__ == "__main__":
    try:
        curses.wrapper(main)
    except KeyboardInterrupt:
        sys.exit(0)

