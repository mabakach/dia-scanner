// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — brightness and contrast adjustment.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation

/// Applies brightness and contrast adjustments to packed RGB data in a single pass.
///
/// Brightness shifts every channel by a fixed offset; contrast scales each channel
/// around the midpoint (128).  Both are applied together:
///   1. add brightness offset
///   2. scale around 128 by the contrast factor
/// Values are clamped to [0, 255].
public enum BrightnessContrastFilter {

    /// Adjusts brightness and contrast of packed RGB data.
    /// - Parameters:
    ///   - brightness: Additive offset in normalised units; `0` = no change,
    ///                 `+1` shifts all channels to white, `-1` to black.
    ///   - contrast: Scaling factor around 128 in normalised units; `0` = no change,
    ///               `+1` doubles the contrast, `-1` collapses to flat grey.
    public static func apply(to rgb: Data, width: Int, height: Int,
                             brightness: Float, contrast: Float) -> Data {
        let count = width * height * 3
        precondition(rgb.count >= count, "RGB data size mismatch")

        let brightOffset    = brightness * 255.0
        let contrastFactor  = contrast + 1.0

        var out = Data(count: count)
        rgb.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for i in 0..<count {
                    let v = (Float(src[i]) + brightOffset - 128.0) * contrastFactor + 128.0
                    dst[i] = UInt8(max(0, min(255, Int(v.rounded()))))
                }
            }
        }
        return out
    }
}
