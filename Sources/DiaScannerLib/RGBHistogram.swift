// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — per-channel RGB histogram.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation

/// Per-channel luminance histogram of a rendered RGB image (256 bins per channel).
public struct RGBHistogram: Sendable {
    public let r: [Int]
    public let g: [Int]
    public let b: [Int]

    /// Builds a histogram from packed RGB data (3 bytes per pixel, R-G-B order).
    public static func compute(from rgb: Data, pixelCount: Int) -> RGBHistogram {
        var r = [Int](repeating: 0, count: 256)
        var g = [Int](repeating: 0, count: 256)
        var b = [Int](repeating: 0, count: 256)
        rgb.withUnsafeBytes { ptr in
            let src = ptr.bindMemory(to: UInt8.self).baseAddress!
            for i in stride(from: 0, to: pixelCount * 3, by: 3) {
                r[Int(src[i])]     += 1
                g[Int(src[i + 1])] += 1
                b[Int(src[i + 2])] += 1
            }
        }
        return RGBHistogram(r: r, g: g, b: b)
    }
}
