// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — OV550Controller tests.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import XCTest
@testable import DiaScannerLib

/// Verifies that OV550Controller builds the correct register sequences
/// without touching real hardware (uses MockUSBTransport).
final class OV550ControllerTests: XCTestCase {

    var mock: MockUSBTransport!
    var controller: OV550Controller!

    override func setUp() {
        mock = MockUSBTransport()
        controller = OV550Controller(transport: mock)
    }

    // Power on: must write e7=0x3a then e0=0x08
    func testPowerOn() throws {
        try controller.powerOn()
        XCTAssertEqual(mock.writes.count, 2)
        XCTAssertEqual(mock.writes[0], RegWrite(0xE7, 0x3A))
        XCTAssertEqual(mock.writes[1], RegWrite(0xE0, 0x08))
    }

    // Power down: must write e7=0x3b then e0=0x08
    func testPowerDown() throws {
        try controller.powerDown()
        XCTAssertEqual(mock.writes[0], RegWrite(0xE7, 0x3B))
        XCTAssertEqual(mock.writes[1], RegWrite(0xE0, 0x08))
    }

    // StartStream: e0 = 0x00
    func testStartStream() throws {
        try controller.startStream()
        XCTAssertEqual(mock.writes.last, RegWrite(0xE0, 0x00))
    }

    // BlockStream: e0 = 0x08
    func testBlockStream() throws {
        try controller.blockStream()
        XCTAssertEqual(mock.writes.last, RegWrite(0xE0, 0x08))
    }

    // TurnOnLed: e0=0x00, 0x21|=0x80, 0x23|=0x80
    func testTurnOnLed() throws {
        mock.registerState[0x21] = 0x00
        mock.registerState[0x23] = 0x10
        try controller.setLED(on: true)
        let w = mock.writes
        XCTAssertTrue(w.contains(RegWrite(0xE0, 0x00)))
        // 0x21 masked: (0x00 & ~0x80) | (0x80 & 0x80) = 0x80
        XCTAssertTrue(w.contains(RegWrite(0x21, 0x80)))
        // 0x23 masked: (0x10 & ~0x80) | (0x80 & 0x80) = 0x90
        XCTAssertTrue(w.contains(RegWrite(0x23, 0x90)))
    }

    // TurnOffLed: e0=0x08, 0x23&=~0x80, 0x21&=~0x80
    func testTurnOffLed() throws {
        mock.registerState[0x21] = 0x80
        mock.registerState[0x23] = 0x80
        try controller.setLED(on: false)
        let w = mock.writes
        XCTAssertTrue(w.contains(RegWrite(0xE0, 0x08)))
        XCTAssertTrue(w.contains(RegWrite(0x23, 0x00)))
        XCTAssertTrue(w.contains(RegWrite(0x21, 0x00)))
    }

    func testApplyUsbSetting() throws {
        // Three triplets: plain write, masked write, and no-op mask
        let triplets: [UInt8] = [
            0xF1, 0x60, 0xFF,  // write 0x60 to F1
            0xE0, 0x00, 0x08,  // clear bit3 of E0 (current=0x08 → 0x00)
            0x8C, 0x01, 0xFF,  // write 0x01 to 8C
        ]
        mock.registerState[0xE0] = 0x08
        try controller.applyUSBSetting(Data(triplets))
        XCTAssertTrue(mock.writes.contains(RegWrite(0xF1, 0x60)))
        XCTAssertTrue(mock.writes.contains(RegWrite(0xE0, 0x00)))
        XCTAssertTrue(mock.writes.contains(RegWrite(0x8C, 0x01)))
    }
}

// ─── Mock ────────────────────────────────────────────────────────────

struct RegWrite: Equatable {
    let reg: UInt16
    let value: UInt8
    init(_ reg: UInt16, _ value: UInt8) { self.reg = reg; self.value = value }
}

final class MockUSBTransport: USBTransport {
    var writes: [RegWrite] = []
    var registerState: [UInt16: UInt8] = [:]
    var sensorWrites: [(UInt8, UInt8)] = []

    func writeRegister(_ reg: UInt16, value: UInt8) throws {
        writes.append(RegWrite(reg, value))
        registerState[reg] = value
    }

    func readRegister(_ reg: UInt16) throws -> UInt8 {
        return registerState[reg] ?? 0
    }

    func writeSensorRegister(_ reg: UInt8, value: UInt8) throws {
        sensorWrites.append((reg, value))
    }

    func readSensorRegister(_ reg: UInt8) throws -> UInt8 { 0 }
}
