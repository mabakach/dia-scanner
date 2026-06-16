// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — IOKit USB transport wrapper.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation
import DiaScannerUSBBridge

extension OVUSBDevice: @unchecked Sendable {}

/// Bridges USBTransport to the Objective-C OVUSBDevice IOKit layer.
public final class IOKitUSBTransport: USBTransport {

    public let device: OVUSBDevice

    public init(device: OVUSBDevice) {
        self.device = device
    }

    public func writeRegister(_ reg: UInt16, value: UInt8) throws {
        try device.writeRegister(reg, value: value)
    }

    public func readRegister(_ reg: UInt16) throws -> UInt8 {
        let n = try device.readRegister(reg)
        return n.uint8Value
    }

    public func writeSensorRegister(_ reg: UInt8, value: UInt8) throws {
        try device.writeSensorRegister(reg, value: value)
    }

    public func readSensorRegister(_ reg: UInt8) throws -> UInt8 {
        let n = try device.readSensorRegister(reg)
        return n.uint8Value
    }
}
