// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — NegativeFilter tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
@testable import DiaScannerLib

final class NegativeFilterTests: XCTestCase {

    func testOutputSize() {
        let w = 4, h = 4
        let input = Data([UInt8](repeating: 128, count: w * h * 3))
        let out = NegativeFilter.apply(to: input, width: w, height: h)
        XCTAssertEqual(out.count, w * h * 3)
    }

    // A uniform input with all pixels equal means histograms have a single spike.
    // After auto-levels with lo == hi the scale is 1.0, so the stretch clamps
    // everything to 0. The important invariant is that the output size is correct
    // and no crash occurs.
    func testUniformInputDoesNotCrash() {
        let w = 8, h = 8
        let input = Data([UInt8](repeating: 100, count: w * h * 3))
        let out = NegativeFilter.apply(to: input, width: w, height: h)
        XCTAssertEqual(out.count, w * h * 3)
    }

    // A two-pixel image: one pixel at value 0 (inverts to 255) and one at 255
    // (inverts to 0). With exactly these two values the histogram has entries at
    // 0 and 255. The 1% percentile clips to 0, the 99% percentile clips to 255,
    // so the stretch is identity. The inverted pixels should pass through unchanged.
    func testInversionIsCorrectWithFullRange() {
        // 2×1 image: pixel 0 = (0,0,0), pixel 1 = (255,255,255)
        // After inversion: pixel 0 → (255,255,255), pixel 1 → (0,0,0)
        // With full range [0,255] the stretch leaves these unchanged.
        let input = Data([0, 0, 0, 255, 255, 255])
        let out = NegativeFilter.apply(to: input, width: 2, height: 1)
        XCTAssertEqual(out.count, 6)
        // pixel 0 after invert+stretch
        XCTAssertEqual(Int(out[0]), 255, accuracy: 1) // R
        XCTAssertEqual(Int(out[1]), 255, accuracy: 1) // G
        XCTAssertEqual(Int(out[2]), 255, accuracy: 1) // B
        // pixel 1 after invert+stretch
        XCTAssertEqual(Int(out[3]), 0, accuracy: 1) // R
        XCTAssertEqual(Int(out[4]), 0, accuracy: 1) // G
        XCTAssertEqual(Int(out[5]), 0, accuracy: 1) // B
    }

    // Verify that output is identical to the pre-refactor algorithm (brute-force
    // reference) so that removing `inv` did not change observable results.
    func testOutputMatchesReference() {
        var rng: UInt64 = 0xDEAD_BEEF_CAFE_1234
        func nextByte() -> UInt8 {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return UInt8(rng & 0xFF)
        }

        let w = 16, h = 16
        let pixelCount = w * h
        let count = pixelCount * 3
        var raw = [UInt8](repeating: 0, count: count)
        for i in 0..<count { raw[i] = nextByte() }
        let input = Data(raw)

        // Reference: the original two-pass algorithm with explicit `inv` buffer.
        let reference = referenceApply(to: input, width: w, height: h)
        let result    = NegativeFilter.apply(to: input, width: w, height: h)

        XCTAssertEqual(result, reference)
    }

    func testLargeFrameDoesNotCrash() {
        let w = 2592, h = 1680
        let input = Data([UInt8](repeating: 42, count: w * h * 3))
        let out = NegativeFilter.apply(to: input, width: w, height: h)
        XCTAssertEqual(out.count, w * h * 3)
    }

    // MARK: - Reference implementation (original pre-refactor algorithm)

    private func referenceApply(to rgb: Data, width: Int, height: Int) -> Data {
        let pixelCount = width * height
        let count      = pixelCount * 3

        var inv   = Data(count: count)
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)

        rgb.withUnsafeBytes { srcPtr in
            inv.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for i in stride(from: 0, to: count, by: 3) {
                    let r = 255 - Int(src[i])
                    let g = 255 - Int(src[i + 1])
                    let b = 255 - Int(src[i + 2])
                    dst[i] = UInt8(r); dst[i + 1] = UInt8(g); dst[i + 2] = UInt8(b)
                    histR[r] += 1; histG[g] += 1; histB[b] += 1
                }
            }
        }

        let loR = refPercentile(histR, pixelCount, 0.01)
        let hiR = refPercentile(histR, pixelCount, 0.99)
        let loG = refPercentile(histG, pixelCount, 0.01)
        let hiG = refPercentile(histG, pixelCount, 0.99)
        let loB = refPercentile(histB, pixelCount, 0.01)
        let hiB = refPercentile(histB, pixelCount, 0.99)

        let scaleR = hiR > loR ? 255.0 / Float(hiR - loR) : 1.0
        let scaleG = hiG > loG ? 255.0 / Float(hiG - loG) : 1.0
        let scaleB = hiB > loB ? 255.0 / Float(hiB - loB) : 1.0

        var out = Data(count: count)
        inv.withUnsafeBytes { srcPtr in
            out.withUnsafeMutableBytes { dstPtr in
                let src = srcPtr.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstPtr.bindMemory(to: UInt8.self).baseAddress!
                for i in stride(from: 0, to: count, by: 3) {
                    dst[i]     = refStretch(Int(src[i]),     lo: loR, scale: scaleR)
                    dst[i + 1] = refStretch(Int(src[i + 1]), lo: loG, scale: scaleG)
                    dst[i + 2] = refStretch(Int(src[i + 2]), lo: loB, scale: scaleB)
                }
            }
        }
        return out
    }

    private func refPercentile(_ hist: [Int], _ total: Int, _ frac: Double) -> Int {
        let threshold = Int(Double(total) * frac)
        var cumulative = 0
        for i in 0..<256 { cumulative += hist[i]; if cumulative >= threshold { return i } }
        return 255
    }

    private func refStretch(_ v: Int, lo: Int, scale: Float) -> UInt8 {
        let s = Int(Float(v - lo) * scale)
        return UInt8(max(0, min(255, s)))
    }
}
