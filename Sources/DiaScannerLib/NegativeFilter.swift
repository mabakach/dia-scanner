// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — color negative orange-mask removal.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation

/// Inverts and removes the orange mask from color negative film using per-channel auto-levels.
///
/// Fixed mask constants break on old or faded film because the dye couplers shift
/// over time (cyan fades fastest, so the base becomes more red). Auto-levels adapts
/// to the actual film in the scanner: after inversion, a histogram is built for each
/// channel and the 1st/99th percentile clip points are used as black/white points,
/// stretching the result to [0, 255]. The 1% clip on each end absorbs dust and
/// scratch outliers without distorting the overall exposure.
public enum NegativeFilter {

    /// Inverts packed RGB data and auto-levels each channel to remove the orange mask.
    /// Input: 3 bytes per pixel, R-G-B order, `width × height` pixels.
    public static func apply(to rgb: Data, width: Int, height: Int) -> Data {
        let pixelCount = width * height
        let count      = pixelCount * 3
        precondition(rgb.count >= count, "RGB data size mismatch")

        // Pass 1 — accumulate per-channel histograms from inverted values, no intermediate buffer.
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)

        rgb.withUnsafeBytes { srcPtr in
            let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            for i in stride(from: 0, to: count, by: 3) {
                histR[255 - Int(src[i])]     += 1
                histG[255 - Int(src[i + 1])] += 1
                histB[255 - Int(src[i + 2])] += 1
            }
        }

        // Find 1st and 99th percentile clip points for each channel.
        let loR = percentile(histR, pixelCount, 0.01)
        let hiR = percentile(histR, pixelCount, 0.99)
        let loG = percentile(histG, pixelCount, 0.01)
        let hiG = percentile(histG, pixelCount, 0.99)
        let loB = percentile(histB, pixelCount, 0.01)
        let hiB = percentile(histB, pixelCount, 0.99)

        // Pass 2 — stretch each channel from [lo, hi] → [0, 255].
        let scaleR = hiR > loR ? 255.0 / Float(hiR - loR) : 1.0
        let scaleG = hiG > loG ? 255.0 / Float(hiG - loG) : 1.0
        let scaleB = hiB > loB ? 255.0 / Float(hiB - loB) : 1.0

        var out = Data(count: count)
        rgb.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for i in stride(from: 0, to: count, by: 3) {
                    dst[i]     = stretch(255 - Int(src[i]),     lo: loR, scale: scaleR)
                    dst[i + 1] = stretch(255 - Int(src[i + 1]), lo: loG, scale: scaleG)
                    dst[i + 2] = stretch(255 - Int(src[i + 2]), lo: loB, scale: scaleB)
                }
            }
        }
        return out
    }

    // Returns the value at which `frac` of pixels fall at or below.
    private static func percentile(_ hist: [Int], _ total: Int, _ frac: Double) -> Int {
        let threshold = max(1, Int(Double(total) * frac))
        var cumulative = 0
        for i in 0..<256 {
            cumulative += hist[i]
            if cumulative >= threshold { return i }
        }
        return 255
    }

    @inline(__always)
    private static func stretch(_ v: Int, lo: Int, scale: Float) -> UInt8 {
        let s = Int(Float(v - lo) * scale)
        return UInt8(max(0, min(255, s)))
    }
}
