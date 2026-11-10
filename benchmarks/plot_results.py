"""Draw the figures of docs/BENCHMARKS.md from its tables of results.

    python3 benchmarks/plot_results.py

For each table of times or memory on the page (Reading and writing, The
first call, Memory, The command-line tools), this writes an SVG figure in
docs/figures/: one panel per row of the table, a bar per implementation, on
a logarithmic scale. The seven WFDB-x implementations are drawn in one
colour, the original C library (or tools) and wfdb-python each in its own.
The numbers are read from the Markdown tables themselves, so the figures
always show what the tables say: after the tables are updated with new
results (benchmarks/run.py --markdown), run this script again. Rows with
fewer than three values (such as the frame-by-frame reading, which only C++
and C have) are left out of the figures. Only the Python standard library
is used.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
It has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 2.1 of the License, or (at your option)
any later version. See LICENSE.
"""

import math
import re
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "BENCHMARKS.md"
OUT = ROOT / "docs" / "figures"

# The tables drawn: the heading of each section, the name of its figure, and
# the sentence above the panels.
FIGURES = [
    ("Reading and writing", "benchmark-reading-writing",
     "Time of one call (fastest of 7, warm cache); log scale. "
     "All return identical samples and files."),
    ("The first call", "benchmark-first-call",
     "Time of the first call in a new process; log scale."),
    ("Memory", "benchmark-memory",
     "Peak memory of the whole process while reading a record; log scale."),
    ("The command-line tools", "benchmark-tools",
     "Time of one run of each tool, start-up included; log scale."),
]

FONT = "Helvetica, Arial, 'DejaVu Sans', sans-serif"
INK = "#1f2933"
MUTED = "#52606d"
GRID = "#e4e7eb"
WFDBX = "#1f5f99"        # the seven WFDB-x implementations
C_REF = "#3e4c59"        # the original C library and tools
WFDB_PY = "#b4521f"      # wfdb-python
COLOURS = {"C (original)": C_REF, "wfdb-python": WFDB_PY}
LEGEND = [(WFDBX, "WFDB-x (7 languages)"),
          (C_REF, "original C package 10.7.0"),
          (WFDB_PY, "wfdb-python")]

# Layout, in SVG units (pixels at 1x)
WIDTH = 1000
MARGIN = 20
PANEL_W, GAP_X, GAP_Y = 470, 20, 54
LABEL_W, VALUE_W = 120, 70     # room for the names, and for the last value
BAR_H, STEP = 20, 26
MIN_VALUES = 3                 # rows with fewer values are not drawn


def read_tables(text):
    """{section heading: (column names, [(row label, [value or None])],
    unit)} for the tables of the page whose cells are times or memory."""
    tables = {}
    section = None
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"#{2,3} (.+)", lines[i])
        if m:
            section = m.group(1).strip()
        if lines[i].startswith("| |") and i + 1 < len(lines) and \
                lines[i + 1].startswith("|---"):
            cols = [c.strip() for c in lines[i].strip("|").split("|")][1:]
            rows, unit = [], None
            i += 2
            while i < len(lines) and lines[i].startswith("|"):
                cells = [c.strip() for c in lines[i].strip("|").split("|")]
                vals = []
                for c in cells[1:]:
                    m = re.fullmatch(r"([0-9.,]+) (ms|MB)", c)
                    if m:
                        unit = m.group(2)
                        vals.append(float(m.group(1).replace(",", "")))
                    else:
                        vals.append(None)
                rows.append((cells[0], vals))
                i += 1
            if unit and section not in tables:
                tables[section] = (cols, rows, unit)
            continue
        i += 1
    return tables


def titles(labels):
    """The panel titles: the table labels without Markdown backticks, and a
    label "the same, ..." completed with the subject of the label above it
    ("read long, in physical units")."""
    out = []
    for label in labels:
        label = label.replace("`", "")
        if label.startswith("the same,") and out:
            label = out[-1].split(" (")[0] + label[len("the same"):]
        out.append(label)
    return out


def fmt(v, unit):
    """A value as the tables write it."""
    if unit == "MB":
        return "%.0f MB" % v
    if v < 1:
        return "%.2f ms" % v
    if v < 100:
        return "%.1f ms" % v
    return "%.0f ms" % v


def text(x, y, s, size=12, weight="normal", fill=INK, anchor="start"):
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">'
            f'{escape(s)}</text>\n')


def panel(px, py, title, names, vals, unit):
    """One panel: a log-scale bar per implementation that has a value."""
    items = [(n, v) for n, v in zip(names, vals) if v is not None]
    out = text(px, py, title, 13.5, "bold")
    lo = 10 ** math.floor(math.log10(min(v for _, v in items)))
    if min(v for _, v in items) / lo < 3:
        lo /= 10
    hi = 10 ** math.ceil(math.log10(max(v for _, v in items)))
    x0, x1 = px + LABEL_W, px + PANEL_W - VALUE_W
    y0 = py + 16

    def xpos(v):
        return x0 + (math.log10(v) - math.log10(lo)) / \
            (math.log10(hi) - math.log10(lo)) * (x1 - x0)

    bottom = y0 + len(items) * STEP
    d = lo
    while d <= hi * 1.0001:
        x = xpos(d)
        out += (f'<line x1="{x:.1f}" y1="{y0 - 4}" x2="{x:.1f}" '
                f'y2="{bottom}" stroke="{GRID}" stroke-width="1"/>\n')
        out += text(x, bottom + 16, f"{d:g} {unit}", 10.5, fill=MUTED,
                    anchor="middle")
        d *= 10
    for k, (name, v) in enumerate(items):
        y = y0 + k * STEP
        colour = COLOURS.get(name, WFDBX)
        out += text(x0 - 8, y + 14.5, name, 12,
                    "normal" if colour == WFDBX else "bold",
                    INK if colour == WFDBX else colour, "end")
        out += (f'<rect x="{x0}" y="{y}" width="{max(xpos(v) - x0, 1):.1f}" '
                f'height="{BAR_H}" fill="{colour}" rx="2"/>\n')
        out += text(xpos(v) + 6, y + 14.5, fmt(v, unit), 11, fill=MUTED)
    return out, bottom + 24 - py


def figure(table, caption, alt):
    cols, rows, unit = table
    rows = [(t, v) for t, (_, v) in zip(titles([r for r, _ in rows]), rows)
            if sum(x is not None for x in v) >= MIN_VALUES]
    body = text(MARGIN, 30, caption, 13)
    top = 60
    y = top
    for k in range(0, len(rows), 2):
        heights = []
        for j, (label, vals) in enumerate(rows[k:k + 2]):
            p, h = panel(MARGIN + j * (PANEL_W + GAP_X), y, label, cols, vals,
                         unit)
            body += p
            heights.append(h)
        y += max(heights) + GAP_Y
    legend_y = y - GAP_Y + 24
    x = MARGIN
    for colour, name in LEGEND:
        if colour == WFDB_PY and "wfdb-python" not in cols:
            continue
        body += (f'<rect x="{x}" y="{legend_y - 12}" width="14" height="14" '
                 f'fill="{colour}" rx="2"/>\n')
        body += text(x + 20, legend_y, name, 12)
        x += 30 + 7.2 * len(name)
    body += text(WIDTH - MARGIN, legend_y,
                 "Intel Xeon 2.1 GHz, x86-64 Linux; docs/BENCHMARKS.md",
                 size=11, fill=MUTED, anchor="end")
    height = legend_y + 20
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {WIDTH} '
            f'{height:.0f}" width="{WIDTH}" height="{height:.0f}" role="img" '
            f'aria-label="{escape(alt)}" font-family="{FONT}">\n'
            f'<rect x="0" y="0" width="{WIDTH}" height="{height:.0f}" '
            f'fill="#ffffff"/>\n{body}</svg>\n')


def main():
    tables = read_tables(PAGE.read_text(encoding="utf-8"))
    OUT.mkdir(parents=True, exist_ok=True)
    for section, name, caption in FIGURES:
        if section not in tables:
            raise SystemExit("no table of results under '%s' in %s"
                             % (section, PAGE))
        alt = ("%s: the seven WFDB-x implementations, the original C "
               "package and wfdb-python, log scale" % section)
        path = OUT / (name + ".svg")
        path.write_text(figure(tables[section], caption, alt),
                        encoding="utf-8")
        print(path.relative_to(ROOT))


if __name__ == "__main__":
    main()
