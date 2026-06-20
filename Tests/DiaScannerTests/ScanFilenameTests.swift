// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — ScanFilename unit tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Testing
@testable import DiaScannerLib

@Suite("ScanFilename")
struct ScanFilenameTests {

    // MARK: - Defaults

    @Test("default prefix is 'scan', counter is 1, padding is 3")
    func defaultValues() {
        let fn = ScanFilename()
        #expect(fn.prefix == "scan")
        #expect(fn.counter == 1)
        #expect(fn.counterPadding == 3)
    }

    @Test("default filename is scan_001.png")
    func defaultFilename() {
        let fn = ScanFilename()
        #expect(fn.filename(for: .png) == "scan_001.png")
    }

    // MARK: - filename format (no padding)

    @Test("filename uses prefix_counter.ext format across all formats")
    func filenameFormat() {
        let fn = ScanFilename(prefix: "slide", counter: 3, counterPadding: 1)
        #expect(fn.filename(for: .png)      == "slide_3.png")
        #expect(fn.filename(for: .jpeg)     == "slide_3.jpg")
        #expect(fn.filename(for: .tiff)     == "slide_3.tiff")
        #expect(fn.filename(for: .bmp)      == "slide_3.bmp")
        #expect(fn.filename(for: .jpeg2000) == "slide_3.jp2")
    }

    @Test("custom prefix with spaces is preserved verbatim")
    func customPrefixWithSpaces() {
        let fn = ScanFilename(prefix: "my scan", counter: 10, counterPadding: 1)
        #expect(fn.filename(for: .png) == "my scan_10.png")
    }

    @Test("counter zero is valid")
    func counterZero() {
        let fn = ScanFilename(prefix: "scan", counter: 0, counterPadding: 1)
        #expect(fn.filename(for: .png) == "scan_0.png")
    }

    @Test("large counter without padding")
    func largeCounter() {
        let fn = ScanFilename(prefix: "batch", counter: 9999, counterPadding: 1)
        #expect(fn.filename(for: .tiff) == "batch_9999.tiff")
    }

    // MARK: - increment

    @Test("increment advances counter by one")
    func increment() {
        var fn = ScanFilename(prefix: "img", counter: 5, counterPadding: 1)
        fn.increment()
        #expect(fn.counter == 6)
        #expect(fn.filename(for: .jpeg) == "img_6.jpg")
    }

    @Test("increment does not mutate prefix or padding")
    func incrementKeepsPrefix() {
        var fn = ScanFilename(prefix: "holiday", counter: 1, counterPadding: 3)
        fn.increment()
        fn.increment()
        #expect(fn.prefix == "holiday")
        #expect(fn.counterPadding == 3)
        #expect(fn.counter == 3)
    }

    // MARK: - formattedCounter

    @Test("formattedCounter without padding")
    func formattedCounterNoPadding() {
        let fn = ScanFilename(prefix: "x", counter: 7, counterPadding: 1)
        #expect(fn.formattedCounter == "7")
    }

    @Test("formattedCounter pads single digit to three places")
    func formattedCounterPad3() {
        let fn = ScanFilename(prefix: "x", counter: 5, counterPadding: 3)
        #expect(fn.formattedCounter == "005")
    }

    @Test("formattedCounter pads two-digit value to three places")
    func formattedCounterPad3TwoDigit() {
        let fn = ScanFilename(prefix: "x", counter: 42, counterPadding: 3)
        #expect(fn.formattedCounter == "042")
    }

    @Test("formattedCounter does not truncate when counter exceeds padding width")
    func formattedCounterNaturalOverflow() {
        let fn = ScanFilename(prefix: "x", counter: 1000, counterPadding: 3)
        #expect(fn.formattedCounter == "1000")
    }

    @Test("formattedCounter with padding 2 rolls over correctly")
    func formattedCounterPad2Rollover() {
        var fn = ScanFilename(prefix: "x", counter: 9, counterPadding: 2)
        fn.increment()
        #expect(fn.formattedCounter == "10")
        #expect(fn.filename(for: .png) == "x_10.png")
    }

    // MARK: - filename with padding

    @Test("filename uses zero-padded counter in name")
    func filenamePadded() {
        let fn = ScanFilename(prefix: "dia", counter: 3, counterPadding: 3)
        #expect(fn.filename(for: .jpeg) == "dia_003.jpg")
    }

    @Test("increment with padding produces correctly padded next filename")
    func incrementWithPadding() {
        var fn = ScanFilename(prefix: "scan", counter: 1, counterPadding: 3)
        fn.increment()
        #expect(fn.filename(for: .png) == "scan_002.png")
    }

    // MARK: - parseCounterInput

    @Test("parse plain number — no padding")
    func parseNoPadding() {
        let result = ScanFilename.parseCounterInput("1")
        #expect(result?.counter == 1)
        #expect(result?.padding == 1)
    }

    @Test("parse multi-digit without leading zero — no padding")
    func parseMultiDigitNoPadding() {
        let result = ScanFilename.parseCounterInput("42")
        #expect(result?.counter == 42)
        #expect(result?.padding == 1)
    }

    @Test("parse single leading zero sets padding to 2")
    func parseOneLeadingZero() {
        let result = ScanFilename.parseCounterInput("01")
        #expect(result?.counter == 1)
        #expect(result?.padding == 2)
    }

    @Test("parse two leading zeros sets padding to 3")
    func parseTwoLeadingZeros() {
        let result = ScanFilename.parseCounterInput("001")
        #expect(result?.counter == 1)
        #expect(result?.padding == 3)
    }

    @Test("parse '042' — leading zero, non-zero value")
    func parseLeadingZeroNonZeroValue() {
        let result = ScanFilename.parseCounterInput("042")
        #expect(result?.counter == 42)
        #expect(result?.padding == 3)
    }

    @Test("parse '0' alone — no padding (single zero is valid)")
    func parseSingleZero() {
        let result = ScanFilename.parseCounterInput("0")
        #expect(result?.counter == 0)
        #expect(result?.padding == 1)
    }

    @Test("parse empty string returns nil")
    func parseEmpty() {
        #expect(ScanFilename.parseCounterInput("") == nil)
    }

    @Test("parse non-numeric returns nil")
    func parseNonNumeric() {
        #expect(ScanFilename.parseCounterInput("abc") == nil)
        #expect(ScanFilename.parseCounterInput("1a") == nil)
    }

    @Test("parse negative number returns nil")
    func parseNegative() {
        #expect(ScanFilename.parseCounterInput("-1") == nil)
    }
}
