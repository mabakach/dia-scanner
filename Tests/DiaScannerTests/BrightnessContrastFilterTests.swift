// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — BrightnessContrastFilter tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
@testable import DiaScannerLib

final class BrightnessContrastFilterTests: XCTestCase {

    func testOutputSize() {
        let w = 4, h = 4
        let input = Data([UInt8](repeating: 128, count: w * h * 3))
        let out = BrightnessContrastFilter.apply(to: input, width: w, height: h,
                                                 brightness: 0, contrast: 0)
        XCTAssertEqual(out.count, w * h * 3)
    }

    // brightness=0, contrast=0 must be a no-op.
    func testIdentityPassthrough() {
        var bytes = [UInt8](repeating: 0, count: 6)
        bytes[0] = 50; bytes[1] = 128; bytes[2] = 200
        bytes[3] = 10; bytes[4] = 255; bytes[5] = 0
        let input = Data(bytes)
        let out = BrightnessContrastFilter.apply(to: input, width: 2, height: 1,
                                                 brightness: 0, contrast: 0)
        XCTAssertEqual(out, input)
    }

    // Positive brightness shifts values up.
    func testBrightnessUp() {
        let input = Data([100, 100, 100])
        let out = BrightnessContrastFilter.apply(to: input, width: 1, height: 1,
                                                 brightness: 0.2, contrast: 0)
        XCTAssertGreaterThan(Int(out[0]), 100)
    }

    // Negative brightness shifts values down.
    func testBrightnessDown() {
        let input = Data([100, 100, 100])
        let out = BrightnessContrastFilter.apply(to: input, width: 1, height: 1,
                                                 brightness: -0.2, contrast: 0)
        XCTAssertLessThan(Int(out[0]), 100)
    }

    // Contrast = -1 collapses everything to flat grey (128).
    func testMinimumContrastIsGrey() {
        var bytes = [UInt8](repeating: 0, count: 6 * 3)
        for i in 0..<bytes.count { bytes[i] = UInt8(i * 10) }
        let input = Data(bytes)
        let out = BrightnessContrastFilter.apply(to: input, width: 6, height: 1,
                                                 brightness: 0, contrast: -1)
        for byte in out { XCTAssertEqual(Int(byte), 128) }
    }

    // Positive contrast stretches values away from midpoint.
    func testPositiveContrastIncreasesDifference() {
        // Two pixels: one below 128, one above.
        let input = Data([100, 0, 0,  156, 0, 0])
        let out = BrightnessContrastFilter.apply(to: input, width: 2, height: 1,
                                                 brightness: 0, contrast: 0.5)
        let delta_before = 156 - 100
        let delta_after  = Int(out[3]) - Int(out[0])
        XCTAssertGreaterThan(delta_after, delta_before)
    }

    // Values must be clamped to [0, 255].
    func testClampsToByteRange() {
        let input = Data([255, 255, 255,  0, 0, 0])
        let out = BrightnessContrastFilter.apply(to: input, width: 2, height: 1,
                                                 brightness: 1.0, contrast: 1.0)
        for byte in out { XCTAssertLessThanOrEqual(Int(byte), 255) }
        let out2 = BrightnessContrastFilter.apply(to: input, width: 2, height: 1,
                                                  brightness: -1.0, contrast: 1.0)
        for byte in out2 { XCTAssertGreaterThanOrEqual(Int(byte), 0) }
    }
}
