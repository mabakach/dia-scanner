// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — ImageTransform tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
import AppKit
@testable import DiaScannerLib

final class ImageTransformTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStateIsIdentity() {
        let t = ImageTransform()
        XCTAssertEqual(t.rotation, 0)
        XCTAssertFalse(t.mirrorHorizontal)
        XCTAssertFalse(t.mirrorVertical)
        XCTAssertTrue(t.isIdentity)
    }

    // MARK: - Rotation

    func testRotateRightIncrementsByNinety() {
        var t = ImageTransform()
        t.rotateRight()
        XCTAssertEqual(t.rotation, 90)
    }

    func testRotateLeftDecrementsByNinety() {
        var t = ImageTransform()
        t.rotateLeft()
        XCTAssertEqual(t.rotation, 270)
    }

    func testFourRightRotationsReturnToZero() {
        var t = ImageTransform()
        t.rotateRight(); t.rotateRight(); t.rotateRight(); t.rotateRight()
        XCTAssertEqual(t.rotation, 0)
    }

    func testFourLeftRotationsReturnToZero() {
        var t = ImageTransform()
        t.rotateLeft(); t.rotateLeft(); t.rotateLeft(); t.rotateLeft()
        XCTAssertEqual(t.rotation, 0)
    }

    func testLeftAndRightCancelOut() {
        var t = ImageTransform()
        t.rotateRight()
        t.rotateLeft()
        XCTAssertEqual(t.rotation, 0)
    }

    func testRotationWrapsCorrectly() {
        var t = ImageTransform()
        t.rotateRight()  // 90
        t.rotateRight()  // 180
        t.rotateRight()  // 270
        t.rotateRight()  // 0 (wraps)
        XCTAssertEqual(t.rotation, 0)
    }

    // MARK: - Mirror

    func testToggleMirrorHorizontal() {
        var t = ImageTransform()
        t.toggleMirrorHorizontal()
        XCTAssertTrue(t.mirrorHorizontal)
        t.toggleMirrorHorizontal()
        XCTAssertFalse(t.mirrorHorizontal)
    }

    func testToggleMirrorVertical() {
        var t = ImageTransform()
        t.toggleMirrorVertical()
        XCTAssertTrue(t.mirrorVertical)
        t.toggleMirrorVertical()
        XCTAssertFalse(t.mirrorVertical)
    }

    func testHorizontalAndVerticalMirrorAreIndependent() {
        var t = ImageTransform()
        t.toggleMirrorHorizontal()
        XCTAssertTrue(t.mirrorHorizontal)
        XCTAssertFalse(t.mirrorVertical)

        t.toggleMirrorVertical()
        XCTAssertTrue(t.mirrorHorizontal)
        XCTAssertTrue(t.mirrorVertical)
    }

    // MARK: - isIdentity

    func testIsIdentityFalseAfterRotation() {
        var t = ImageTransform()
        t.rotateRight()
        XCTAssertFalse(t.isIdentity)
    }

    func testIsIdentityFalseAfterHorizontalMirror() {
        var t = ImageTransform()
        t.toggleMirrorHorizontal()
        XCTAssertFalse(t.isIdentity)
    }

    func testIsIdentityFalseAfterVerticalMirror() {
        var t = ImageTransform()
        t.toggleMirrorVertical()
        XCTAssertFalse(t.isIdentity)
    }

    func testIsIdentityTrueAfterFullRotationCycle() {
        var t = ImageTransform()
        t.rotateRight(); t.rotateRight(); t.rotateRight(); t.rotateRight()
        XCTAssertTrue(t.isIdentity)
    }

    func testIsIdentityTrueAfterDoubleToggle() {
        var t = ImageTransform()
        t.toggleMirrorHorizontal()
        t.toggleMirrorVertical()
        t.toggleMirrorHorizontal()
        t.toggleMirrorVertical()
        XCTAssertTrue(t.isIdentity)
    }

    // MARK: - Equatable

    func testEqualTransformsAreEqual() {
        var a = ImageTransform()
        var b = ImageTransform()
        a.rotateRight(); b.rotateRight()
        XCTAssertEqual(a, b)
    }

    func testDifferentTransformsAreNotEqual() {
        var a = ImageTransform()
        let b = ImageTransform()
        a.rotateRight()
        XCTAssertNotEqual(a, b)
    }

    // MARK: - NSImage.applying(_:) — size

    func testApplyingIdentityReturnsSameObject() {
        let img = makeImage(width: 4, height: 2)
        XCTAssertTrue(img.applying(ImageTransform()) === img)
    }

    func testApplyingRotateRightSwapsDimensions() {
        let img = makeImage(width: 4, height: 2)
        var t = ImageTransform(); t.rotateRight()
        let result = img.applying(t)
        XCTAssertEqual(result.size, NSSize(width: 2, height: 4))
    }

    func testApplyingRotateLeftSwapsDimensions() {
        let img = makeImage(width: 4, height: 2)
        var t = ImageTransform(); t.rotateLeft()
        let result = img.applying(t)
        XCTAssertEqual(result.size, NSSize(width: 2, height: 4))
    }

    func testApplyingRotate180KeepsDimensions() {
        let img = makeImage(width: 4, height: 2)
        var t = ImageTransform(); t.rotateRight(); t.rotateRight()
        let result = img.applying(t)
        XCTAssertEqual(result.size, NSSize(width: 4, height: 2))
    }

    func testApplyingMirrorHorizontalKeepsDimensions() {
        let img = makeImage(width: 4, height: 2)
        var t = ImageTransform(); t.toggleMirrorHorizontal()
        XCTAssertEqual(img.applying(t).size, NSSize(width: 4, height: 2))
    }

    func testApplyingMirrorVerticalKeepsDimensions() {
        let img = makeImage(width: 4, height: 2)
        var t = ImageTransform(); t.toggleMirrorVertical()
        XCTAssertEqual(img.applying(t).size, NSSize(width: 4, height: 2))
    }

    // MARK: - NSImage.applying(_:) — pixel mapping

    // After a horizontal mirror the left and right pixels of a 2×1 image swap.
    func testApplyingMirrorHorizontalSwapsPixels() {
        // 2×1: x=0 is reddish, x=1 is bluish (Y-down visual coordinates)
        let src = makeImage(width: 2, height: 1) { x, _ in
            x == 0
                ? NSColor(deviceRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
                : NSColor(deviceRed: 0.1, green: 0.1, blue: 0.8, alpha: 1)
        }
        var t = ImageTransform(); t.toggleMirrorHorizontal()
        let result = src.applying(t)

        let srcL = rgb(at: 0, y: 0, in: src)
        let srcR = rgb(at: 1, y: 0, in: src)
        let dstL = rgb(at: 0, y: 0, in: result)
        let dstR = rgb(at: 1, y: 0, in: result)

        XCTAssertEqual(dstL.r, srcR.r, accuracy: 5)
        XCTAssertEqual(dstL.g, srcR.g, accuracy: 5)
        XCTAssertEqual(dstL.b, srcR.b, accuracy: 5)
        XCTAssertEqual(dstR.r, srcL.r, accuracy: 5)
        XCTAssertEqual(dstR.g, srcL.g, accuracy: 5)
        XCTAssertEqual(dstR.b, srcL.b, accuracy: 5)
    }

    // After a clockwise 90° rotation the bottom-left pixel moves to the top-left.
    func testApplyingRotateRightMovesBottomLeftToTopLeft() {
        // 2×2 image with a distinct colour at each corner (Y-down visual coordinates):
        //   TL=red  TR=green
        //   BL=blue BR=yellow
        let src = makeImage(width: 2, height: 2) { x, y in
            switch (x, y) {
            case (0, 0): return NSColor(deviceRed: 0.9, green: 0.1, blue: 0.1, alpha: 1)
            case (1, 0): return NSColor(deviceRed: 0.1, green: 0.9, blue: 0.1, alpha: 1)
            case (0, 1): return NSColor(deviceRed: 0.1, green: 0.1, blue: 0.9, alpha: 1)
            default:     return NSColor(deviceRed: 0.9, green: 0.9, blue: 0.1, alpha: 1)
            }
        }
        var t = ImageTransform(); t.rotateRight()
        let result = src.applying(t)

        // CW 90°: the left column becomes the top row.
        // BL (0,1) → TL (0,0),  TL (0,0) → TR (1,0)
        let srcBL = rgb(at: 0, y: 1, in: src)
        let dstTL = rgb(at: 0, y: 0, in: result)
        XCTAssertEqual(dstTL.r, srcBL.r, accuracy: 5)
        XCTAssertEqual(dstTL.g, srcBL.g, accuracy: 5)
        XCTAssertEqual(dstTL.b, srcBL.b, accuracy: 5)

        let srcTL = rgb(at: 0, y: 0, in: src)
        let dstTR = rgb(at: 1, y: 0, in: result)
        XCTAssertEqual(dstTR.r, srcTL.r, accuracy: 5)
        XCTAssertEqual(dstTR.g, srcTL.g, accuracy: 5)
        XCTAssertEqual(dstTR.b, srcTL.b, accuracy: 5)
    }

    // MARK: - Helpers

    /// Creates a solid-colour or per-pixel NSImage for testing (Y-down visual coordinates).
    private func makeImage(
        width: Int,
        height: Int,
        colorAt: (Int, Int) -> NSColor = { _, _ in .gray }
    ) -> NSImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        for y in 0..<height {
            for x in 0..<width { rep.setColor(colorAt(x, y), atX: x, y: y) }
        }
        let img = NSImage(size: NSSize(width: width, height: height))
        img.addRepresentation(rep)
        return img
    }

    /// Reads an RGB triple (0-255) at a visual position in Y-down coordinates.
    private func rgb(at x: Int, y: Int, in image: NSImage) -> (r: Int, g: Int, b: Int) {
        guard let tiff = image.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let c    = rep.colorAt(x: x, y: y),
              let d    = c.usingColorSpace(.deviceRGB)
        else { return (0, 0, 0) }
        return (Int(d.redComponent * 255 + 0.5),
                Int(d.greenComponent * 255 + 0.5),
                Int(d.blueComponent * 255 + 0.5))
    }
}
