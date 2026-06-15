// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PX-2130 Slide Scanner macOS Driver — OV5621 sensor support.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 *
 * Ported from the Linux ov534-ov9xxx gspca driver
 * (drivers/media/usb/gspca/ov534_9.c):
 *   Copyright (C) 2009-2011 Jean-Francois Moine <http://moinejf.free.fr>
 *   Copyright (C) 2008      Antonio Ospite <ospite@studenti.unina.it>
 *   Copyright (C) 2008      Jim Paris <jim@jtan.com>
 *   Based on a prototype by Mark Ferrell <majortrips@gmail.com>
 *   USB protocol reverse engineered by Jim Paris.
 *
 * Output format: SBGGR8 (BGGR Bayer pattern, 8 bpp), native resolution 2592×1680.
 */

import Foundation

public final class OV5621Sensor {

    public static let frameWidth  = 2592
    public static let frameHeight = 1680
    public static let frameBytes  = frameWidth * frameHeight  // 4,354,560

    /// Bridge IDs known to the gspca driver — high nibbles only (sensor_id & 0xFFF0).
    public enum SensorID: UInt16 {
        case ov965x  = 0x9650
        case ov971x  = 0x9710
        case ov562x  = 0x5620
        case ov361x  = 0x3610
    }

    private let transport: USBTransport

    public init(transport: USBTransport) {
        self.transport = transport
    }

    /// Bridge reset + chip ID detection. Returns the raw sensor ID
    /// (e.g. 0x5621 for the OV5621 we have). Caller should match `value & 0xFFF0`
    /// against `SensorID` to dispatch.
    @discardableResult
    public func detect() throws -> UInt16 {
        // gspca sd_init(): release PWDN, block stream, wait 100ms.
        try transport.writeRegister(0xE7, value: 0x3A)
        try transport.writeRegister(0xE0, value: 0x08)
        Thread.sleep(forTimeInterval: 0.1)

        // Set SCCB slave to OV2640/OV5621/OV965x default (0x60), soft-reset sensor.
        try transport.writeRegister(0xF1, value: 0x60)
        try? transport.writeSensorRegister(0x12, value: 0x80)   // soft reset; NACK is normal
        Thread.sleep(forTimeInterval: 0.01)

        // Drain any stale SCCB status left over from the NACK above.
        if let dev = (transport as? IOKitUSBTransport)?.device {
            dev.clearSCCBStatus()
        }

        // gspca double-reads each chip ID byte to prime the SCCB bus.
        _ = try? transport.readSensorRegister(0x0A)
        let high = (try? transport.readSensorRegister(0x0A)) ?? 0
        _ = try? transport.readSensorRegister(0x0B)
        let low  = (try? transport.readSensorRegister(0x0B)) ?? 0
        return (UInt16(high) << 8) | UInt16(low)
    }

    /// Apply the gspca `ov562x_init` (bridge) + `ov562x_init_2` (sensor) sequences
    /// and start the transfer (E0=0x00). Call after `detect()` returns 0x562X.
    public func initializeAndStart() throws {
        try applyBridgeArray(Self.ov562xBridgeInit)
        try applySensorArray(Self.ov562xSensorInit)
        try transport.writeRegister(0xE0, value: 0x00)  // start transfer
    }

    /// Stop sequence from gspca sd_stopN for non-OV361x sensors.
    public func stop() throws {
        try transport.writeRegister(0xE0, value: 0x01)  // stop transfer
        try setLED(on: false)
        try transport.writeRegister(0xE0, value: 0x00)
    }

    /// gspca set_led — toggles bit 7 on bridge regs 0x21/0x23.
    public func setLED(on: Bool) throws {
        var data = try transport.readRegister(0x21)
        data |= 0x80
        try transport.writeRegister(0x21, value: data)

        data = try transport.readRegister(0x23)
        if on { data |= 0x80 } else { data &= ~0x80 }
        try transport.writeRegister(0x23, value: data)

        if !on {
            data = try transport.readRegister(0x21)
            data &= ~0x80
            try transport.writeRegister(0x21, value: data)
        }
    }

    // MARK: - Helpers

    private func applyBridgeArray(_ array: [(UInt8, UInt8)]) throws {
        for (reg, val) in array {
            try transport.writeRegister(UInt16(reg), value: val)
        }
    }

    /// gspca sccb_w_array: if reg==0xFF, do a sensor read of `val` then write FF=0
    /// (an idiom used to refresh certain status registers in the OV9650 path; harmless here).
    private func applySensorArray(_ array: [(UInt8, UInt8)]) throws {
        for (reg, val) in array {
            if reg == 0xFF {
                _ = try? transport.readSensorRegister(val)
                try? transport.writeSensorRegister(0xFF, value: 0x00)
            } else {
                try transport.writeSensorRegister(reg, value: val)
            }
        }
    }

    // MARK: - Register sequences from gspca_ov534_9.c

    /// ov562x_init: 13 bridge writes that configure the OV550 ASIC for OV5621 output.
    static let ov562xBridgeInit: [(UInt8, UInt8)] = [
        (0x88, 0x20),
        (0x89, 0x0A),
        (0x8A, 0x90),
        (0x8B, 0x06),
        (0x8C, 0x01),
        (0x8D, 0x10),
        (0x1C, 0x00),
        (0x1D, 0x48),
        (0x1D, 0x00),
        (0x1D, 0xFF),
        (0x1C, 0x0A),
        (0x1D, 0x2E),
        (0x1D, 0x1E),
    ]

    /// ov562x_init_2: ~107 SCCB writes that program the OV5621 sensor.
    static let ov562xSensorInit: [(UInt8, UInt8)] = [
        (0x12, 0x80),
        (0x11, 0x41),
        (0x13, 0x00),
        (0x10, 0x1E),
        (0x3B, 0x07),
        (0x5B, 0x40),
        (0x39, 0x07),
        (0x53, 0x02),
        (0x54, 0x60),
        (0x04, 0x20),
        (0x27, 0x04),
        (0x3D, 0x40),
        (0x36, 0x00),
        (0xC5, 0x04),
        (0x4E, 0x00),
        (0x4F, 0x93),
        (0x50, 0x7B),
        (0xCA, 0x0C),
        (0xCB, 0x0F),
        (0x39, 0x07),
        (0x4A, 0x10),
        (0x3E, 0x0A),
        (0x3D, 0x00),
        (0x0C, 0x38),
        (0x38, 0x90),
        (0x46, 0x30),
        (0x4F, 0x93),
        (0x50, 0x7B),
        (0xAB, 0x00),
        (0xCA, 0x0C),
        (0xCB, 0x0F),
        (0x37, 0x02),
        (0x44, 0x48),
        (0x8D, 0x44),
        (0x2A, 0x00),
        (0x2B, 0x00),
        (0x32, 0x00),
        (0x38, 0x90),
        (0x53, 0x02),
        (0x54, 0x60),
        (0x12, 0x00),
        (0x17, 0x12),
        (0x18, 0xB4),
        (0x19, 0x0C),
        (0x1A, 0xF4),
        (0x03, 0x4A),
        (0x89, 0x20),
        (0x83, 0x80),
        (0xB7, 0x9D),
        (0xB6, 0x11),
        (0xB5, 0x55),
        (0xB4, 0x00),
        (0xA9, 0xF0),
        (0xA8, 0x0A),
        (0xB8, 0xF0),
        (0xB9, 0xF0),
        (0xBA, 0xF0),
        (0x81, 0x07),
        (0x63, 0x44),
        (0x13, 0xC7),
        (0x14, 0x60),
        (0x33, 0x75),
        (0x2C, 0x00),
        (0x09, 0x00),
        (0x35, 0x30),
        (0x27, 0x04),
        (0x3C, 0x07),
        (0x3A, 0x0A),
        (0x3B, 0x07),
        (0x01, 0x40),
        (0x02, 0x40),
        (0x16, 0x40),
        (0x52, 0xB0),
        (0x51, 0x83),
        (0x21, 0xBB),
        (0x22, 0x10),
        (0x23, 0x03),
        (0x35, 0x38),
        (0x20, 0x90),
        (0x28, 0x30),
        (0x73, 0xE1),
        (0x6C, 0x00),
        (0x6D, 0x80),
        (0x6E, 0x00),
        (0x70, 0x04),
        (0x71, 0x00),
        (0x8D, 0x04),
        (0x64, 0x00),
        (0x65, 0x00),
        (0x66, 0x00),
        (0x67, 0x00),
        (0x68, 0x00),
        (0x69, 0x00),
        (0x6A, 0x00),
        (0x6B, 0x00),
        (0x71, 0x94),
        (0x74, 0x20),
        (0x80, 0x09),
        (0x85, 0xC0),
    ]
}
