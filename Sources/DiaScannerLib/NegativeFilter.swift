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

    /// Per-channel clip points used for the histogram stretch step.
    /// Returned by `apply` so callers can smooth them across frames to avoid oscillation.
    public struct Clips: Sendable {
        public var loR, hiR, loG, hiG, loB, hiB: Int

        /// Exponential moving average blend: `alpha` weight on `measured`, `1-alpha` on self.
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

    /// Inverts packed RGB data and optionally auto-levels each channel to remove the orange mask.
    /// Input: 3 bytes per pixel, R-G-B order, `width × height` pixels.
    /// - Parameter clips: Pre-computed (and optionally smoothed) clip points. When `nil`, clips
    ///   are computed fresh from this frame's histogram.
    /// - Returns: Processed data and the clip points that were measured from this frame
    ///   (useful for EMA smoothing across frames in a live stream). Clips are `nil` when
    ///   `applyAutoLevels` is `false`.
    public static func apply(to rgb: Data, width: Int, height: Int,
                             applyAutoLevels: Bool = true,
                             clips: Clips? = nil) -> (Data, Clips?) {
        let pixelCount = width * height
        let count      = pixelCount * 3
        precondition(rgb.count >= count, "RGB data size mismatch")

        guard applyAutoLevels else {
            var out = Data(count: count)
            rgb.withUnsafeBytes { srcPtr in
                out.withUnsafeMutableBytes { dstPtr in
                    let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                    let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                    for i in 0..<count { dst[i] = 255 - src[i] }
                }
            }
            return (out, nil)
        }

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

        // Fresh clip points measured from this frame (always returned so callers can smooth).
        let fresh = Clips(
            loR: percentile(histR, pixelCount, 0.01), hiR: percentile(histR, pixelCount, 0.99),
            loG: percentile(histG, pixelCount, 0.01), hiG: percentile(histG, pixelCount, 0.99),
            loB: percentile(histB, pixelCount, 0.01), hiB: percentile(histB, pixelCount, 0.99)
        )
        // Use caller-supplied (smoothed) clips if available; fall back to fresh on first frame.
        let c = clips ?? fresh

        // Pass 2 — stretch each channel from [lo, hi] → [0, 255].
        let scaleR = c.hiR > c.loR ? 255.0 / Float(c.hiR - c.loR) : 1.0
        let scaleG = c.hiG > c.loG ? 255.0 / Float(c.hiG - c.loG) : 1.0
        let scaleB = c.hiB > c.loB ? 255.0 / Float(c.hiB - c.loB) : 1.0

        var out = Data(count: count)
        rgb.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for i in stride(from: 0, to: count, by: 3) {
                    dst[i]     = stretch(255 - Int(src[i]),     lo: c.loR, scale: scaleR)
                    dst[i + 1] = stretch(255 - Int(src[i + 1]), lo: c.loG, scale: scaleG)
                    dst[i + 2] = stretch(255 - Int(src[i + 2]), lo: c.loB, scale: scaleB)
                }
            }
        }
        return (out, fresh)
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
