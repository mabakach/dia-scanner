// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — positive (dia) vignetting correction.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation

/// Corrects vignetting in positive (dia) slides and normalises exposure via per-channel
/// auto-levels.
///
/// The PX-2130 uses a point LED with a simple lens: the centre of the image receives
/// more light than the edges, producing a characteristic centre-bright / edge-dark falloff.
/// A radial gain map `gain(r) = 1 / (1 − k·r²)` (r normalised so the corner is 1.0)
/// counters this: the centre is left untouched while the edges are brightened proportionally.
/// After the spatial correction, per-channel 1st/99th-percentile auto-levels normalises the
/// overall exposure without being thrown off by dust or scratch outliers.
public enum PositiveFilter {

    /// Radial vignetting coefficient.  `0` = no correction; `0.5` gives the image corners
    /// a 2× gain relative to the centre.  Increase if edges still look dark after correction.
    public static let vignetteK: Float = 0.5

    /// Applies radial vignetting correction and per-channel auto-levels to packed RGB data.
    /// Input: 3 bytes per pixel, R-G-B order, `width × height` pixels.
    public static func apply(to rgb: Data, width: Int, height: Int) -> Data {
        let pixelCount = width * height
        let count      = pixelCount * 3
        precondition(rgb.count >= count, "RGB data size mismatch")

        let cx   = Float(width  - 1) / 2.0
        let cy   = Float(height - 1) / 2.0
        let maxR2 = cx * cx + cy * cy

        // Pass 1 — apply radial gain; accumulate per-channel histograms for auto-levels.
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        var corrected = Data(count: count)

        rgb.withUnsafeBytes { srcPtr in
            corrected.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for row in 0..<height {
                    let dy = Float(row) - cy
                    for col in 0..<width {
                        let dx  = Float(col) - cx
                        let r2  = maxR2 > 0 ? (dx * dx + dy * dy) / maxR2 : 0
                        // Prevent division by zero; at corner with k=1 denominator → 0.
                        let gain = 1.0 / max(0.001, 1.0 - vignetteK * r2)
                        let i   = (row * width + col) * 3
                        let r   = clampByte(Float(src[i])     * gain)
                        let g   = clampByte(Float(src[i + 1]) * gain)
                        let b   = clampByte(Float(src[i + 2]) * gain)
                        dst[i]     = r
                        dst[i + 1] = g
                        dst[i + 2] = b
                        histR[Int(r)] += 1
                        histG[Int(g)] += 1
                        histB[Int(b)] += 1
                    }
                }
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
        corrected.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for i in stride(from: 0, to: count, by: 3) {
                    dst[i]     = stretch(Int(src[i]),     lo: loR, scale: scaleR)
                    dst[i + 1] = stretch(Int(src[i + 1]), lo: loG, scale: scaleG)
                    dst[i + 2] = stretch(Int(src[i + 2]), lo: loB, scale: scaleB)
                }
            }
        }
        return out
    }

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
    private static func clampByte(_ v: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(v.rounded()))))
    }

    @inline(__always)
    private static func stretch(_ v: Int, lo: Int, scale: Float) -> UInt8 {
        let s = Int(Float(v - lo) * scale)
        return UInt8(max(0, min(255, s)))
    }
}
