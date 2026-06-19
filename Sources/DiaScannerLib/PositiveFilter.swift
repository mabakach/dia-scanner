// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — vignetting correction and positive auto-levels.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation

/// Corrects the PX-2130's centre-bright / edge-dark illumination falloff.
///
/// The scanner uses a point LED with a simple lens: the centre receives more light than
/// the edges.  `applyVignetting` counters this with a radial gain map
/// `gain(r) = 1 / (1 − k·r²)` (r normalised so the corner is 1.0): centre pixels are
/// unchanged while edges are brightened proportionally.
///
/// For positive (dia) slides `apply` follows the vignetting step with per-channel
/// 1st/99th-percentile auto-levels to normalise overall exposure.  For negative film the
/// caller first runs `applyVignetting` and then `NegativeFilter.apply`, so that the
/// illumination correction happens before colour-mask removal and inversion.
public enum PositiveFilter {

    /// Default radial vignetting coefficient.  `0` = no correction; `0.5` gives corners
    /// a 2× gain relative to the centre.
    public static let defaultVignetteK: Float = 0.5

    // MARK: - Public API

    /// Applies only the radial vignetting correction to packed RGB data.
    /// Use this before `NegativeFilter.apply` in negative mode.
    /// Returns the input unchanged when `vignetteK == 0`.
    public static func applyVignetting(to rgb: Data, width: Int, height: Int,
                                       vignetteK: Float) -> Data {
        guard vignetteK > 0 else { return rgb }
        let count = width * height * 3
        precondition(rgb.count >= count, "RGB data size mismatch")

        let cx    = Float(width  - 1) / 2.0
        let cy    = Float(height - 1) / 2.0
        let maxR2 = cx * cx + cy * cy

        var out = Data(count: count)
        rgb.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for row in 0..<height {
                    let dy = Float(row) - cy
                    for col in 0..<width {
                        let dx   = Float(col) - cx
                        let r2   = maxR2 > 0 ? (dx * dx + dy * dy) / maxR2 : 0
                        let gain = 1.0 / max(0.001, 1.0 - vignetteK * r2)
                        let i    = (row * width + col) * 3
                        dst[i]     = clampByte(Float(src[i])     * gain)
                        dst[i + 1] = clampByte(Float(src[i + 1]) * gain)
                        dst[i + 2] = clampByte(Float(src[i + 2]) * gain)
                    }
                }
            }
        }
        return out
    }

    /// Applies vignetting correction followed by per-channel auto-levels to packed RGB data.
    /// Use this for positive (dia) slides.
    /// - Parameter vignetteK: Correction strength; `0` = none, up to `0.9` (10× corner gain).
    public static func apply(to rgb: Data, width: Int, height: Int,
                             vignetteK: Float = defaultVignetteK) -> Data {
        let corrected = applyVignetting(to: rgb, width: width, height: height, vignetteK: vignetteK)
        return autoLevels(corrected, width: width, height: height)
    }

    // MARK: - Private helpers

    private static func autoLevels(_ rgb: Data, width: Int, height: Int) -> Data {
        let pixelCount = width * height
        let count      = pixelCount * 3

        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)

        rgb.withUnsafeBytes { srcPtr in
            let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
            for i in stride(from: 0, to: count, by: 3) {
                histR[Int(src[i])]     += 1
                histG[Int(src[i + 1])] += 1
                histB[Int(src[i + 2])] += 1
            }
        }

        let loR = percentile(histR, pixelCount, 0.01)
        let hiR = percentile(histR, pixelCount, 0.99)
        let loG = percentile(histG, pixelCount, 0.01)
        let hiG = percentile(histG, pixelCount, 0.99)
        let loB = percentile(histB, pixelCount, 0.01)
        let hiB = percentile(histB, pixelCount, 0.99)

        let scaleR = hiR > loR ? 255.0 / Float(hiR - loR) : 1.0
        let scaleG = hiG > loG ? 255.0 / Float(hiG - loG) : 1.0
        let scaleB = hiB > loB ? 255.0 / Float(hiB - loB) : 1.0

        var out = Data(count: count)
        rgb.withUnsafeBytes { srcPtr in
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
