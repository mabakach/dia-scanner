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

    /// Default radial vignetting coefficient.  `0` = no correction (default); `0.5` gives corners
    /// a 2× gain relative to the centre.
    public static let defaultVignetteK: Float = 0.0

    /// Display gamma applied to positives.  The sensor output is linear, so without it midtones
    /// and shadows look too dark; `1/2.0` lifts them without needing more exposure (which would
    /// clip highlights).
    public static let displayGamma: Float = 1.0 / 2.0

    /// Per-channel clip points for the histogram stretch step.
    /// Returned by `apply` so callers can smooth them across frames.
    public struct Clips: Sendable {
        public var loR, hiR, loG, hiG, loB, hiB: Int

        /// EMA blend: `alpha` weight on `measured`, `1-alpha` on self.
        public func blended(with measured: Clips, alpha: Float) -> Clips {
            func ema(_ prev: Int, _ meas: Int) -> Int {
                Int((alpha * Float(meas) + (1 - alpha) * Float(prev)).rounded())
            }
            return Clips(loR: ema(loR, measured.loR), hiR: ema(hiR, measured.hiR),
                         loG: ema(loG, measured.loG), hiG: ema(hiG, measured.hiG),
                         loB: ema(loB, measured.loB), hiB: ema(hiB, measured.hiB))
        }

        /// True when any channel's clip point differs by more than `threshold` DN — indicates a
        /// scene change (new slide) rather than normal sensor noise.
        public func hasSceneChange(vs fresh: Clips, threshold: Int = 30) -> Bool {
            max(abs(loR - fresh.loR), abs(hiR - fresh.hiR),
                abs(loG - fresh.loG), abs(hiG - fresh.hiG),
                abs(loB - fresh.loB), abs(hiB - fresh.hiB)) > threshold
        }
    }

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

    /// Applies vignetting correction and optionally auto-levels to packed RGB data.
    /// Use this for positive (dia) slides.
    /// - Parameter vignetteK: Correction strength; `0` = none, up to `0.9` (10× corner gain).
    /// - Parameter applyAutoLevels: When `false`, skips the histogram stretch step.
    /// - Parameter clips: Pre-computed (and optionally smoothed) clip points. When `nil`, clips
    ///   are computed fresh from this frame's histogram.
    /// - Returns: Processed data and the clip points measured from this frame (for EMA smoothing).
    ///   Clips are `nil` when `applyAutoLevels` is `false`.
    public static func apply(to rgb: Data, width: Int, height: Int,
                             vignetteK: Float = defaultVignetteK,
                             applyAutoLevels: Bool = true,
                             clips: Clips? = nil) -> (Data, Clips?) {
        guard applyAutoLevels else {
            let corrected = applyVignetting(to: rgb, width: width, height: height, vignetteK: vignetteK)
            return (applyGamma(corrected), nil)
        }
        // Measure clip points from pre-vignette data: vignette boosts edges up to 2×, which would
        // inflate hiR/hiG from landscape borders and shrink the effective scale for blue sky.
        let fresh = measureClips(rgb, width: width, height: height)
        let corrected = applyVignetting(to: rgb, width: width, height: height, vignetteK: vignetteK)
        let levelled = applyLevels(corrected, width: width, height: height, clips: clips ?? fresh)
        return (applyGamma(levelled), fresh)
    }

    // MARK: - Private helpers

    private static func measureClips(_ rgb: Data, width: Int, height: Int) -> Clips {
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
        return Clips(
            loR: percentile(histR, pixelCount, 0.01), hiR: percentile(histR, pixelCount, 0.99),
            loG: percentile(histG, pixelCount, 0.01), hiG: percentile(histG, pixelCount, 0.99),
            loB: percentile(histB, pixelCount, 0.01), hiB: percentile(histB, pixelCount, 0.99)
        )
    }

    private static func applyLevels(_ rgb: Data, width: Int, height: Int, clips c: Clips) -> Data {
        let count = width * height * 3
        let lumRange = 0.299 * Float(c.hiR - c.loR)
                     + 0.587 * Float(c.hiG - c.loG)
                     + 0.114 * Float(c.hiB - c.loB)
        let scale = lumRange > 0 ? 255.0 / lumRange : 1.0
        var out = Data(count: count)
        rgb.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for i in stride(from: 0, to: count, by: 3) {
                    dst[i]     = stretch(Int(src[i]),     lo: c.loR, scale: scale)
                    dst[i + 1] = stretch(Int(src[i + 1]), lo: c.loG, scale: scale)
                    dst[i + 2] = stretch(Int(src[i + 2]), lo: c.loB, scale: scale)
                }
            }
        }
        return out
    }

    private static func applyGamma(_ rgb: Data) -> Data {
        let lut = (0..<256).map { clampByte(255 * pow(Float($0) / 255, displayGamma)) }
        var out = rgb
        out.withUnsafeMutableBytes { buf in
            for i in 0..<buf.count { buf[i] = lut[Int(buf[i])] }
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
