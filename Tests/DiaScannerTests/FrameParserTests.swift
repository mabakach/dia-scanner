// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — FrameParser tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
@testable import DiaScannerLib

final class FrameParserTests: XCTestCase {

    func testSingleCompleteFrame() {
        let parser = FrameParser(frameWidth: 4, frameHeight: 2)

        // SOF packet (sync byte 0xFF + 4 pixels)
        var sof = Data([0xFF]) + Data([10, 20, 30, 40])
        parser.feed(sof)

        // Middle packet (4 more pixels)
        parser.feed(Data([50, 60, 70, 80]))

        // EOF packet (sync byte 0xFE, no extra data)
        var frames: [Data] = []
        parser.onFrameComplete = { frames.append($0) }
        parser.feed(Data([0xFE]))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([10, 20, 30, 40, 50, 60, 70, 80]))
    }

    func testDiscardDataBeforeFirstSOF() {
        let parser = FrameParser(frameWidth: 4, frameHeight: 2)
        var frames: [Data] = []
        parser.onFrameComplete = { frames.append($0) }

        // Junk before frame
        parser.feed(Data([1, 2, 3]))
        parser.feed(Data([0xFF, 10, 20, 30, 40]))
        parser.feed(Data([50, 60, 70, 80]))
        parser.feed(Data([0xFE]))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 8)
    }

    func testMultipleFrames() {
        let parser = FrameParser(frameWidth: 2, frameHeight: 1)
        var frames: [Data] = []
        parser.onFrameComplete = { frames.append($0) }

        for _ in 0..<3 {
            parser.feed(Data([0xFF, 0xAA, 0xBB]))
            parser.feed(Data([0xFE]))
        }

        XCTAssertEqual(frames.count, 3)
        for f in frames {
            XCTAssertEqual(f, Data([0xAA, 0xBB]))
        }
    }

    func testEmptyPacketsIgnored() {
        let parser = FrameParser(frameWidth: 2, frameHeight: 1)
        var frames: [Data] = []
        parser.onFrameComplete = { frames.append($0) }

        parser.feed(Data())
        parser.feed(Data([0xFF, 0x11, 0x22]))
        parser.feed(Data())
        parser.feed(Data([0xFE]))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0x11, 0x22]))
    }

    func testFrameRestartOnNewSOF() {
        // If a second SOF arrives before EOF, discard the partial frame
        let parser = FrameParser(frameWidth: 2, frameHeight: 1)
        var frames: [Data] = []
        parser.onFrameComplete = { frames.append($0) }

        parser.feed(Data([0xFF, 0x01, 0x02]))  // start frame 1
        parser.feed(Data([0xFF, 0xAA, 0xBB]))  // restart → discard frame 1
        parser.feed(Data([0xFE]))               // EOF for frame 2

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([0xAA, 0xBB]))
    }
}
