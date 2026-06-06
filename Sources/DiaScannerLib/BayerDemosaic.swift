// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 *
 * Based on ov2640 Camera Driver
 * Copyright (C) 2010 Alberto Panizzo <maramaopercheseimorto@gmail.com>
 * Copyright 2005-2009 Freescale Semiconductor, Inc. All Rights Reserved.
 * Copyright (C) 2006, OmniVision
 */

import Foundation
import AppKit

/// Converts RAW8 Bayer-pattern data from the OV2640 sensor to RGB.
///
/// The OV2640 produces RGGB Bayer pattern:
///   Row 0: R G R G …
///   Row 1: G B G B …
public enum BayerDemosaic {

    public enum Pattern { case rggb, grbg, gbrg, bggr }

    /// Converts RAW8 Bayer data → packed RGB (3 bytes per pixel, R first).
    public static func demosaic(_ raw: Data, width: Int, height: Int, pattern: Pattern = .rggb) -> Data {
        let count = width * height
        precondition(raw.count == count, "RAW data size mismatch")

        var rgb = Data(count: count * 3)
        raw.withUnsafeBytes { rawPtr in
            rgb.withUnsafeMutableBytes { rgbPtr in
                let src = rawPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = rgbPtr.bindMemory(to: UInt8.self).baseAddress!

                for row in 0..<height {
                    for col in 0..<width {
                        let (r, g, b) = interpolate(src, row: row, col: col,
                                                    width: width, height: height,
                                                    pattern: pattern)
                        let out = (row * width + col) * 3
                        dst[out]     = r
                        dst[out + 1] = g
                        dst[out + 2] = b
                    }
                }
            }
        }
        return rgb
    }

    /// Creates an NSImage from packed RGB data.
    public static func nsImage(fromRGB rgb: Data, width: Int, height: Int) -> NSImage? {
        let bitsPerComponent = 8
        let bitsPerPixel     = 24
        let bytesPerRow      = width * 3
        let colorSpace       = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo       = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        guard let provider = CGDataProvider(data: rgb as CFData),
              let cgImage  = CGImage(width:            width,
                                     height:           height,
                                     bitsPerComponent: bitsPerComponent,
                                     bitsPerPixel:     bitsPerPixel,
                                     bytesPerRow:      bytesPerRow,
                                     space:            colorSpace,
                                     bitmapInfo:       bitmapInfo,
                                     provider:         provider,
                                     decode:           nil,
                                     shouldInterpolate: false,
                                     intent:           .defaultIntent)
        else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // ─── Bilinear interpolation ────────────────────────────────────────

    /// Returns the (R, G, B) for a given pixel by bilinear interpolation.
    private static func interpolate(_ src: UnsafePointer<UInt8>,
                                    row: Int, col: Int,
                                    width: Int, height: Int,
                                    pattern: Pattern) -> (UInt8, UInt8, UInt8) {
        // Determine which colour this pixel carries in the Bayer grid
        let (rowParity, colParity) = (row % 2, col % 2)
        let pixelType = bayerPixelType(rowParity: rowParity, colParity: colParity, pattern: pattern)

        func px(_ r: Int, _ c: Int) -> Int {
            let cr = max(0, min(height - 1, r))
            let cc = max(0, min(width  - 1, c))
            return Int(src[cr * width + cc])
        }

        switch pixelType {
        case .red:
            let r = px(row, col)
            let g = avg4(px(row-1, col), px(row+1, col), px(row, col-1), px(row, col+1))
            let b = avg4(px(row-1, col-1), px(row-1, col+1), px(row+1, col-1), px(row+1, col+1))
            return (UInt8(r), UInt8(g), UInt8(b))

        case .greenOnRed:
            let g = px(row, col)
            let r = avg2(px(row, col-1), px(row, col+1))
            let b = avg2(px(row-1, col), px(row+1, col))
            return (UInt8(r), UInt8(g), UInt8(b))

        case .greenOnBlue:
            let g = px(row, col)
            let b = avg2(px(row, col-1), px(row, col+1))
            let r = avg2(px(row-1, col), px(row+1, col))
            return (UInt8(r), UInt8(g), UInt8(b))

        case .blue:
            let b = px(row, col)
            let g = avg4(px(row-1, col), px(row+1, col), px(row, col-1), px(row, col+1))
            let r = avg4(px(row-1, col-1), px(row-1, col+1), px(row+1, col-1), px(row+1, col+1))
            return (UInt8(r), UInt8(g), UInt8(b))
        }
    }

    private enum PixelType { case red, greenOnRed, greenOnBlue, blue }

    private static func bayerPixelType(rowParity: Int, colParity: Int, pattern: Pattern) -> PixelType {
        switch pattern {
        case .rggb:
            if rowParity == 0 && colParity == 0 { return .red }
            if rowParity == 0 && colParity == 1 { return .greenOnRed }
            if rowParity == 1 && colParity == 0 { return .greenOnBlue }
            return .blue
        case .grbg:
            if rowParity == 0 && colParity == 0 { return .greenOnRed }
            if rowParity == 0 && colParity == 1 { return .red }
            if rowParity == 1 && colParity == 0 { return .blue }
            return .greenOnBlue
        case .gbrg:
            if rowParity == 0 && colParity == 0 { return .greenOnBlue }
            if rowParity == 0 && colParity == 1 { return .blue }
            if rowParity == 1 && colParity == 0 { return .red }
            return .greenOnRed
        case .bggr:
            if rowParity == 0 && colParity == 0 { return .blue }
            if rowParity == 0 && colParity == 1 { return .greenOnBlue }
            if rowParity == 1 && colParity == 0 { return .greenOnRed }
            return .red
        }
    }

    @inline(__always)
    private static func avg2(_ a: Int, _ b: Int) -> Int { (a + b) / 2 }

    @inline(__always)
    private static func avg4(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Int { (a + b + c + d) / 4 }
}
