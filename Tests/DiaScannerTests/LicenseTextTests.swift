// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — license text constant tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
@testable import DiaScannerLib

final class LicenseTextTests: XCTestCase {

    func testLicenseTextIsNonEmpty() {
        XCTAssertFalse(gplV2LicenseText.isEmpty)
    }

    func testLicenseTextContainsGPLHeading() {
        XCTAssertTrue(
            gplV2LicenseText.contains("GNU General Public License"),
            "License text must reference the GNU General Public License"
        )
    }

    func testLicenseTextContainsFSFAddress() {
        XCTAssertTrue(
            gplV2LicenseText.contains("Free Software Foundation"),
            "License text must reference the Free Software Foundation"
        )
    }

    func testLicenseTextContainsNoWarrantySection() {
        XCTAssertTrue(
            gplV2LicenseText.contains("NO WARRANTY"),
            "License text must contain the NO WARRANTY section"
        )
    }

    func testLicenseTextContainsEndOfTerms() {
        XCTAssertTrue(
            gplV2LicenseText.contains("END OF TERMS AND CONDITIONS"),
            "License text must contain END OF TERMS AND CONDITIONS marker"
        )
    }

    func testLicenseTextContainsCopyrightNotice() {
        XCTAssertTrue(
            gplV2LicenseText.contains("Copyright (C) 1989, 1991 Free Software Foundation"),
            "License text must contain the FSF copyright header"
        )
    }

    func testLicenseTextIsSubstantial() {
        XCTAssertGreaterThan(
            gplV2LicenseText.count, 5000,
            "GPL v2 text should be at least 5000 characters"
        )
    }
}
