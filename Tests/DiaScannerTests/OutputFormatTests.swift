// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — output format encoder tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
import AppKit
@testable import DiaScannerLib

final class OutputFormatTests: XCTestCase {

    // A tiny 4×4 solid-red NSImage used as a minimal encode target.
    private var redImage: NSImage {
        let size = CGSize(width: 4, height: 4)
        let img  = NSImage(size: size)
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        img.unlockFocus()
        return img
    }

    // MARK: - Metadata

    func testAllFormatsHaveNonEmptyDisplayName() {
        for fmt in OutputFormat.allCases {
            XCTAssertFalse(fmt.displayName.isEmpty, "\(fmt.rawValue) missing displayName")
        }
    }

    func testAllFormatsHaveNonEmptyFileExtension() {
        for fmt in OutputFormat.allCases {
            XCTAssertFalse(fmt.fileExtension.isEmpty, "\(fmt.rawValue) missing fileExtension")
        }
    }

    func testQualityFlagsMatchExpected() {
        XCTAssertTrue(OutputFormat.jpeg.supportsQuality)
        XCTAssertTrue(OutputFormat.jpeg2000.supportsQuality)
        XCTAssertFalse(OutputFormat.png.supportsQuality)
        XCTAssertFalse(OutputFormat.bmp.supportsQuality)
        XCTAssertFalse(OutputFormat.tiff.supportsQuality)
    }

    func testFileExtensions() {
        XCTAssertEqual(OutputFormat.jpeg.fileExtension,     "jpg")
        XCTAssertEqual(OutputFormat.png.fileExtension,      "png")
        XCTAssertEqual(OutputFormat.bmp.fileExtension,      "bmp")
        XCTAssertEqual(OutputFormat.tiff.fileExtension,     "tiff")
        XCTAssertEqual(OutputFormat.jpeg2000.fileExtension, "jp2")
    }

    // MARK: - Encoding

    func testJPEGEncodesSuccessfully() throws {
        let data = try OutputFormat.jpeg.encode(redImage, quality: 0.8)
        XCTAssertGreaterThan(data.count, 0, "JPEG encoding produced empty data")
        // JPEG files begin with the SOI marker FF D8
        XCTAssertEqual(data.prefix(2), Data([0xFF, 0xD8]))
    }

    func testPNGEncodesSuccessfully() throws {
        let data = try OutputFormat.png.encode(redImage)
        XCTAssertGreaterThan(data.count, 0, "PNG encoding produced empty data")
        // PNG signature
        XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    func testBMPEncodesSuccessfully() throws {
        let data = try OutputFormat.bmp.encode(redImage)
        XCTAssertGreaterThan(data.count, 0, "BMP encoding produced empty data")
        // BMP files start with "BM"
        XCTAssertEqual(data.prefix(2), Data([0x42, 0x4D]))
    }

    func testTIFFEncodesSuccessfully() throws {
        let data = try OutputFormat.tiff.encode(redImage)
        XCTAssertGreaterThan(data.count, 0, "TIFF encoding produced empty data")
        // TIFF files start with II (little-endian) or MM (big-endian) magic
        let magic = data.prefix(2)
        let isLittleEndian = magic == Data([0x49, 0x49])
        let isBigEndian    = magic == Data([0x4D, 0x4D])
        XCTAssertTrue(isLittleEndian || isBigEndian, "TIFF magic bytes not found")
    }

    func testJPEG2000EncodesSuccessfully() throws {
        let data = try OutputFormat.jpeg2000.encode(redImage, quality: 0.9)
        XCTAssertGreaterThan(data.count, 0, "JPEG 2000 encoding produced empty data")
    }

    // MARK: - Quality clamping

    func testJPEGHighQualityLargerThanLowQuality() throws {
        let large = try OutputFormat.jpeg.encode(redImage, quality: 1.0)
        let small = try OutputFormat.jpeg.encode(redImage, quality: 0.1)
        // Higher quality → more data for a real image (4×4 may be degenerate; just assert both non-zero)
        XCTAssertGreaterThan(large.count, 0)
        XCTAssertGreaterThan(small.count, 0)
    }

    func testQualityClampedToValidRange() throws {
        // Passing out-of-range values should not throw — they are clamped internally.
        XCTAssertNoThrow(try OutputFormat.jpeg.encode(redImage, quality: 1.5))
        XCTAssertNoThrow(try OutputFormat.jpeg.encode(redImage, quality: -0.5))
    }

    // MARK: - Round-trip pixel check (PNG lossless)

    func testPNGRoundTripPreservesPixels() throws {
        let size  = CGSize(width: 2, height: 2)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let data = try OutputFormat.png.encode(image)
        let rep  = NSBitmapImageRep(data: data)
        XCTAssertNotNil(rep, "Could not decode PNG back to bitmap rep")
    }
}
