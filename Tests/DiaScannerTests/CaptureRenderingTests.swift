// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — capture rendering pipeline tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
@testable import DiaScannerLib

/// Verifies that the same raw Bayer frame produces different output depending on
/// the filter mode applied at render time — the core invariant fixed by issue #8.
final class CaptureRenderingTests: XCTestCase {

    private let width  = 16
    private let height = 16

    // Synthetic BGGR Bayer frame: gradient across the frame so auto-levels
    // has a real histogram to work with (uniform data collapses auto-levels).
    private lazy var rawBayer: Data = {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for i in 0..<bytes.count {
            bytes[i] = UInt8(i % 256)
        }
        return Data(bytes)
    }()

    // MARK: - Pipeline output

    func testPositiveRenderHasExpectedSize() {
        let rgb = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        XCTAssertEqual(rgb.count, width * height * 3)
    }

    func testNegativeRenderHasExpectedSize() {
        let rgb = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        let neg = NegativeFilter.apply(to: rgb, width: width, height: height)
        XCTAssertEqual(neg.count, width * height * 3)
    }

    // The critical invariant: positive and negative renders of the same raw frame
    // must produce different pixel data.  If they were identical, the filter would
    // have no effect and the fix would be pointless.
    func testPositiveAndNegativeModesDiffer() {
        let rgb     = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        let negRgb  = NegativeFilter.apply(to: rgb, width: width, height: height)
        XCTAssertNotEqual(rgb, negRgb, "Positive and negative renders must differ")
    }

    // The negative pipeline inverts and auto-levels the image.  After inversion the
    // average brightness of the result should differ from the positive version.
    func testNegativePipelineChangesAverageBrightness() {
        let rgb    = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        let negRgb = NegativeFilter.apply(to: rgb, width: width, height: height)

        let posSum = rgb.reduce(0) { $0 + Int($1) }
        let negSum = negRgb.reduce(0) { $0 + Int($1) }

        XCTAssertNotEqual(posSum, negSum,
            "Negative filter must change overall brightness")
    }

    // Applying the same filter twice to different raw captures of the same frame
    // must give the same result — render is deterministic.
    func testRenderIsDeterministic() {
        let rgb1 = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        let neg1 = NegativeFilter.apply(to: rgb1, width: width, height: height)

        let rgb2 = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        let neg2 = NegativeFilter.apply(to: rgb2, width: width, height: height)

        XCTAssertEqual(neg1, neg2,
            "Re-rendering the same raw frame with the same mode must be idempotent")
    }

    // Re-rendering the same raw data in positive mode must equal the first positive render.
    // This validates that mode-switch re-renders (the option-3 path) are stable.
    func testPositiveReRenderMatchesOriginal() {
        let first  = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        let second = BayerDemosaic.demosaic(rawBayer, width: width, height: height, pattern: .bggr)
        XCTAssertEqual(first, second)
    }
}
