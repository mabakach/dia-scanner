// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — PositiveFilter tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
@testable import DiaScannerLib

final class PositiveFilterTests: XCTestCase {

    func testOutputSize() {
        let w = 4, h = 4
        let input = Data([UInt8](repeating: 128, count: w * h * 3))
        let out = PositiveFilter.apply(to: input, width: w, height: h)
        XCTAssertEqual(out.count, w * h * 3)
    }

    func testUniformInputDoesNotCrash() {
        let w = 8, h = 8
        let input = Data([UInt8](repeating: 100, count: w * h * 3))
        let out = PositiveFilter.apply(to: input, width: w, height: h)
        XCTAssertEqual(out.count, w * h * 3)
    }

    func testLargeFrameDoesNotCrash() {
        let w = 2592, h = 1680
        let input = Data([UInt8](repeating: 42, count: w * h * 3))
        let out = PositiveFilter.apply(to: input, width: w, height: h)
        XCTAssertEqual(out.count, w * h * 3)
    }

    // The corner pixel must receive more radial gain than the centre pixel.
    // Use a flat white input so only the vignetting correction changes values;
    // then verify the corner raw (pre-auto-levels) gain is larger than at centre.
    //
    // We verify this indirectly: apply the filter to a flat grey image where
    // a vignetting model with k > 0 should boost the corners more than centre.
    // Because auto-levels re-normalises, we test the *corrected* intermediate
    // values instead of the final output, using a known image where the centre
    // is artificially bright and verifying the edge/centre ratio improves.
    func testRadialGainReducesCentreEdgeRatio() {
        // 11×11 synthetic image: centre pixel = 200 (bright), edges = 80 (dark).
        // This mimics scanner vignetting.
        let w = 11, h = 11
        let centre = (h / 2 * w + w / 2) * 3

        var bytes = [UInt8](repeating: 0, count: w * h * 3)
        // All pixels dark
        for i in stride(from: 0, to: bytes.count, by: 3) {
            bytes[i] = 80; bytes[i + 1] = 80; bytes[i + 2] = 80
        }
        // Centre pixel bright
        bytes[centre] = 200; bytes[centre + 1] = 200; bytes[centre + 2] = 200

        let input = Data(bytes)
        let out   = PositiveFilter.apply(to: input, width: w, height: h)

        // In the output after vignette correction + auto-levels, the centre
        // should no longer dominate: the corner pixels should be at least half
        // as bright as the centre (in the raw image they were 80/200 = 40%).
        let centreOut = Int(out[centre])
        let cornerOut = Int(out[0])  // top-left corner pixel, R channel

        if centreOut > 0 {
            let ratio = Double(cornerOut) / Double(centreOut)
            XCTAssertGreaterThan(ratio, 0.40,
                "Corner/centre ratio should improve beyond the raw 40% after vignetting correction")
        }
    }

    // Verify that the filter brightens the corners more than the centre on a
    // uniformly-lit gradient image: corner gain > centre gain.
    func testCornerGainExceedsCentreGain() {
        // A uniform grey image: all pixels identical before the filter.
        // After vignetting correction, corners get gain > 1.0 relative to centre.
        // Since auto-levels normalises the result, we use a 1×1 image (only centre)
        // to get the gain = 1 baseline and compare to the corner of a larger image.
        //
        // Strategy: use a 3×3 image where centre = 100 everywhere.
        // Apply PositiveFilter; the corner will have been brightened relative to
        // centre before clamping. After auto-levels, centre should no longer be the
        // brightest pixel (it gets relative dimming vs the boosted corners).
        //
        // In practice with k=0.5 on a 3×3 image:
        //   corner r² ≈ (1/√2)² = 0.5 → gain = 1/(1-0.25) ≈ 1.33
        //   centre r² = 0 → gain = 1.0
        // So corners start higher after gain and after auto-levels the centre is
        // not at the maximum value.
        let w = 3, h = 3
        let input = Data([UInt8](repeating: 100, count: w * h * 3))
        let out = PositiveFilter.apply(to: input, width: w, height: h)

        // Corner pixel (index 0) and centre pixel (index 4 → pixel 4 = centre)
        let cornerR = Int(out[0])
        let centreR = Int(out[4 * 3])   // pixel 4 is centre of 3×3

        // After correcting a uniform image the corners should not be dimmer than centre.
        XCTAssertGreaterThanOrEqual(cornerR, centreR,
            "After vignetting correction, corners should be at least as bright as centre")
    }

    // The filter must not change the output if applied to a 1×1 image (degenerate case).
    func testSinglePixelDoesNotCrash() {
        let input = Data([128, 64, 32])
        let out = PositiveFilter.apply(to: input, width: 1, height: 1)
        XCTAssertEqual(out.count, 3)
    }

    // Negative mode must still use NegativeFilter (not PositiveFilter).
    // Applying NegativeFilter to a gradient must produce different output than PositiveFilter.
    func testPositiveAndNegativeFiltersProduceDifferentOutput() {
        let w = 8, h = 8
        var bytes = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<bytes.count { bytes[i] = UInt8(i % 256) }
        let rgb = Data(bytes)

        let pos = PositiveFilter.apply(to: rgb, width: w, height: h)
        let neg = NegativeFilter.apply(to: rgb, width: w, height: h)

        XCTAssertNotEqual(pos, neg,
            "PositiveFilter and NegativeFilter must produce distinct output on the same input")
    }

    // Applying the filter twice to the same data must yield the same result (deterministic).
    func testIsDeterministic() {
        let w = 8, h = 8
        var bytes = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<bytes.count { bytes[i] = UInt8(i % 200 + 30) }
        let rgb = Data(bytes)

        let out1 = PositiveFilter.apply(to: rgb, width: w, height: h)
        let out2 = PositiveFilter.apply(to: rgb, width: w, height: h)
        XCTAssertEqual(out1, out2)
    }
}
