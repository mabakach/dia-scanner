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

    @Test("default prefix is 'scan' and counter is 1")
    func defaultValues() {
        let fn = ScanFilename()
        #expect(fn.prefix == "scan")
        #expect(fn.counter == 1)
    }

    @Test("filename uses prefix_counter.ext format")
    func filenameFormat() {
        let fn = ScanFilename(prefix: "slide", counter: 3)
        #expect(fn.filename(for: .png)  == "slide_3.png")
        #expect(fn.filename(for: .jpeg) == "slide_3.jpg")
        #expect(fn.filename(for: .tiff) == "slide_3.tiff")
        #expect(fn.filename(for: .bmp)  == "slide_3.bmp")
        #expect(fn.filename(for: .jpeg2000) == "slide_3.jp2")
    }

    @Test("default filename is scan_1.png")
    func defaultFilename() {
        let fn = ScanFilename()
        #expect(fn.filename(for: .png) == "scan_1.png")
    }

    @Test("increment advances counter by one")
    func increment() {
        var fn = ScanFilename(prefix: "img", counter: 5)
        fn.increment()
        #expect(fn.counter == 6)
        #expect(fn.filename(for: .jpeg) == "img_6.jpg")
    }

    @Test("increment does not mutate prefix")
    func incrementKeepsPrefix() {
        var fn = ScanFilename(prefix: "holiday", counter: 1)
        fn.increment()
        fn.increment()
        #expect(fn.prefix == "holiday")
        #expect(fn.counter == 3)
    }

    @Test("custom prefix with spaces is preserved verbatim")
    func customPrefixWithSpaces() {
        let fn = ScanFilename(prefix: "my scan", counter: 10)
        #expect(fn.filename(for: .png) == "my scan_10.png")
    }

    @Test("counter zero is valid")
    func counterZero() {
        let fn = ScanFilename(prefix: "scan", counter: 0)
        #expect(fn.filename(for: .png) == "scan_0.png")
    }

    @Test("large counter value")
    func largeCounter() {
        let fn = ScanFilename(prefix: "batch", counter: 9999)
        #expect(fn.filename(for: .tiff) == "batch_9999.tiff")
    }
}
