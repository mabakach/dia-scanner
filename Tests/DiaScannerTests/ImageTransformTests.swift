// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — ImageTransform tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
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
}
