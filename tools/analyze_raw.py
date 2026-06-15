#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# PX-2130 Slide Scanner macOS Driver — raw capture analysis tool.
#
# Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
"""
Analyze RAW8 captures from the PX-2130 scanner.
Usage: python3 tools/analyze_raw.py [raw_file] [--bmp bmp_file]

Produces statistics useful for diagnosing strip artifacts:
- Row/column mean statistics and standard deviation
- Dark-row and dark-column detection
- Row-parity column reversal check (the June 4 artifact)
- Per-channel PNG row/column analysis when a BMP is supplied
"""

import struct
import sys
import statistics
from collections import Counter
from pathlib import Path


W, H = 1600, 1200


def load_raw(path):
    data = bytearray(Path(path).read_bytes())
    assert len(data) == W * H, f"Expected {W*H} bytes, got {len(data)}"
    return data


def load_bmp(path):
    """Return (width, height, pixel_data_BGR_top_down) from a 24-bit BMP."""
    raw = Path(path).read_bytes()
    offset = struct.unpack_from('<I', raw, 10)[0]
    width  = abs(struct.unpack_from('<i', raw, 18)[0])
    height = abs(struct.unpack_from('<i', raw, 22)[0])
    bpp    = struct.unpack_from('<H', raw, 28)[0]
    assert bpp == 24, f"Expected 24bpp BMP, got {bpp}"
    row_stride = ((width * 3 + 3) // 4) * 4
    return width, height, raw[offset:], row_stride


def analyze_raw(data):
    row_means = [sum(data[r*W:(r+1)*W]) / W for r in range(H)]
    col_means = [sum(data[c::W]) / H for c in range(W)]

    row_std = statistics.stdev(row_means)
    col_std = statistics.stdev(col_means)
    overall = statistics.mean(row_means)

    print(f"=== RAW statistics ===")
    print(f"Overall mean: {overall:.2f}")
    print(f"Row means: min={min(row_means):.1f}  max={max(row_means):.1f}  stdev={row_std:.2f}")
    print(f"Col means: min={min(col_means):.1f}  max={max(col_means):.1f}  stdev={col_std:.2f}")

    dark_rows = [(r, m) for r, m in enumerate(row_means) if m < 150]
    print(f"\nDark rows (mean<150): {len(dark_rows)}")
    for r, m in dark_rows[:10]:
        print(f"  row {r:4d}: {m:.1f}")

    dark_cols = [(c, m) for c, m in enumerate(col_means) if m < overall - 3]
    print(f"\nDark cols (mean < overall-3 = {overall-3:.1f}): {len(dark_cols)}")
    for c, m in dark_cols[:20]:
        print(f"  col {c:4d}: {m:.1f}")

    # Row-parity reversal check
    reversed_count = 0
    for r in range(H):
        base = r * W
        even_sum = sum(data[base + c] for c in range(0, W, 2))
        odd_sum  = sum(data[base + c] for c in range(1, W, 2))
        if even_sum * 2 > odd_sum * 3:
            reversed_count += 1
    print(f"\nRow-parity reversed rows (even>1.5×odd): {reversed_count}/{H}")

    # Even vs odd column means
    even_mean = statistics.mean(col_means[0::2])
    odd_mean  = statistics.mean(col_means[1::2])
    print(f"\nEven-col mean: {even_mean:.2f}  Odd-col mean: {odd_mean:.2f}")

    # Column means sampled every 50 for quick pattern check
    print(f"\nColumn means every 50 cols:")
    for c in range(0, W, 50):
        marker = " <--" if col_means[c] < overall - 2 else ""
        print(f"  col {c:4d}: {col_means[c]:.2f}{marker}")

    return row_means, col_means


def analyze_bmp(path):
    width, height, pixel_data, row_stride = load_bmp(path)
    print(f"\n=== PNG/BMP statistics ({width}×{height}) ===")

    row_stats = []
    for r in range(height):
        base = r * row_stride
        chunk = pixel_data[base:base + width * 3]
        B = sum(chunk[0::3]) / width
        G = sum(chunk[1::3]) / width
        R = sum(chunk[2::3]) / width
        row_stats.append((R, G, B))

    row_lumas = [(R + G + B) / 3 for R, G, B in row_stats]
    print(f"Row luma: min={min(row_lumas):.1f}  max={max(row_lumas):.1f}"
          f"  stdev={statistics.stdev(row_lumas):.2f}")

    dark = [(i, l) for i, l in enumerate(row_lumas) if l < 150]
    print(f"Dark rows (luma<150): {len(dark)}")
    for i, l in dark[:10]:
        R, G, B = row_stats[i]
        print(f"  row {i:4d}: luma={l:.1f}  R={R:.1f} G={G:.1f} B={B:.1f}")

    # Darkest 10 rows
    darkest = sorted(range(height), key=lambda i: row_lumas[i])[:10]
    darkest.sort()
    print(f"\n10 darkest rows:")
    for i in darkest:
        R, G, B = row_stats[i]
        print(f"  row {i:4d}: luma={row_lumas[i]:.1f}  R={R:.1f} G={G:.1f} B={B:.1f}")

    # Column lumas
    col_lumas = []
    for c in range(width):
        luma = 0
        for r in range(height):
            base = r * row_stride + c * 3
            luma += (pixel_data[base] + pixel_data[base+1] + pixel_data[base+2]) / 3
        col_lumas.append(luma / height)

    print(f"\nCol luma: min={min(col_lumas):.1f}  max={max(col_lumas):.1f}"
          f"  stdev={statistics.stdev(col_lumas):.2f}")
    overall = statistics.mean(col_lumas)
    dark_c = [(c, l) for c, l in enumerate(col_lumas) if l < overall - 3]
    print(f"Dark cols (luma < {overall-3:.1f}): {len(dark_c)}")
    for c, l in dark_c[:20]:
        print(f"  col {c:4d}: {l:.1f}")

    # Column lumas every 50
    print(f"\nColumn lumas every 50 cols:")
    for c in range(0, width, 50):
        marker = " <--" if col_lumas[c] < overall - 2 else ""
        print(f"  col {c:4d}: {col_lumas[c]:.2f}{marker}")


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Analyze RAW8 scanner captures")
    parser.add_argument("raw", nargs="?", help="Path to .raw file")
    parser.add_argument("--bmp", help="Path to .bmp file (from sips -s format bmp)")
    args = parser.parse_args()

    if args.raw:
        data = load_raw(args.raw)
        analyze_raw(data)
    elif not args.bmp:
        # Default: analyze the most recent captures
        for path in ['/tmp/diascanner_strip_test.raw', '/tmp/diascanner_capture.raw']:
            p = Path(path)
            if p.exists():
                print(f"\n{'='*60}")
                print(f"File: {path}")
                print('='*60)
                data = load_raw(path)
                analyze_raw(data)

    if args.bmp:
        analyze_bmp(args.bmp)
