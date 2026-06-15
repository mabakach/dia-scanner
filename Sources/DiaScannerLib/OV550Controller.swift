// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * PX-2130 Slide Scanner macOS Driver — OV550 ASIC bridge commands.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 *
 * F-register SCCB bridge protocol (F1=slave, F2=subaddr, F3=write,
 * F4=read, F5=op, F6=status) is derived from the Linux ov534-ov9xxx
 * gspca driver (drivers/media/usb/gspca/ov534_9.c):
 *   Copyright (C) 2009-2011 Jean-Francois Moine <http://moinejf.free.fr>
 *   Copyright (C) 2008      Antonio Ospite <ospite@studenti.unina.it>
 *   Copyright (C) 2008      Jim Paris <jim@jtan.com>
 *   USB protocol reverse engineered by Jim Paris.
 */

import Foundation

/// Commands for the OV550 USB ASIC bridge chip.
/// All register addresses and sequences are derived from ov550ivx.inf analysis.
public final class OV550Controller {

    private let transport: USBTransport

    // OV550 control register addresses (from INF analysis)
    enum Register {
        static let usbControl: UInt16    = 0xE0
        static let powerControl: UInt16  = 0xE7
        static let cclk: UInt16          = 0xE5  // camera master clock to sensor
        static let ledReg1: UInt16       = 0x21
        static let ledReg2: UInt16       = 0x23
        static let hSizeLow: UInt16      = 0x88
        static let hSizeHigh: UInt16     = 0x89
        static let vSizeLow: UInt16      = 0x8A
        static let vSizeHigh: UInt16     = 0x8B
        static let isoControl: UInt16    = 0x8C
        static let inputFormat: UInt16   = 0x8D
        static let outputFmt1: UInt16    = 0x1C
        static let outputFmt2: UInt16    = 0x1D
        static let sccbId: UInt16        = 0xF1  // SCCB slave address
    }

    public init(transport: USBTransport) {
        self.transport = transport
    }

    // ─── Power / Streaming control (from INF CamSet keys) ─────────────

    /// PowerOnCamera: e7=0x3a (release PWDN), e0=0x08 (blockStream).
    /// MCLK (E5) is intentionally not written here — it must remain off during
    /// sensor.initialize() (SCCB writes NACK with MCLK active). MCLK is enabled
    /// later by configureForOV2640RAW8() before stream start.
    public func powerOn() throws {
        try transport.writeRegister(Register.powerControl, value: 0x3A)
        try transport.writeRegister(Register.usbControl, value: 0x08)
    }

    /// PowerDownCamera: e7=0x3b, e0=0x08
    public func powerDown() throws {
        try transport.writeRegister(Register.powerControl, value: 0x3B)
        try transport.writeRegister(Register.usbControl, value: 0x08)
    }

    /// SetUsbWork / StartStream: e0=0x00
    public func startStream() throws {
        try transport.writeRegister(Register.usbControl, value: 0x00)
    }

    /// BlockStream: e0=0x08
    public func blockStream() throws {
        try transport.writeRegister(Register.usbControl, value: 0x08)
    }

    /// TurnOnLed:  e0=0x00; 0x21 |= 0x80; 0x23 |= 0x80
    /// TurnOffLed: e0=0x08; 0x23 &= ~0x80; 0x21 &= ~0x80
    public func setLED(on: Bool) throws {
        if on {
            try transport.writeRegister(Register.usbControl, value: 0x00)
            try rmw(Register.ledReg1, value: 0x80, mask: 0x80)
            try rmw(Register.ledReg2, value: 0x80, mask: 0x80)
        } else {
            try transport.writeRegister(Register.usbControl, value: 0x08)
            try rmw(Register.ledReg1, value: 0x80, mask: 0x80) // INF: 21,80,80
            try rmw(Register.ledReg2, value: 0x00, mask: 0x80) // INF: 23,00,80
            try rmw(Register.ledReg1, value: 0x00, mask: 0x80) // INF: 21,00,80
        }
    }

    // ─── UsbSetting sequences (from apollo2640.set) ────────────────────

    /// Applies a sequence of [register, value, mask] USB-ASIC triplets.
    public func applyUSBSetting(_ triplets: Data) throws {
        guard triplets.count % 3 == 0 else {
            throw ScannerError.invalidData("USB setting triplets must be multiples of 3 bytes")
        }
        for i in stride(from: 0, to: triplets.count, by: 3) {
            let reg   = UInt16(triplets[i])
            let value = triplets[i + 1]
            let mask  = triplets[i + 2]
            if mask == 0xFF {
                try transport.writeRegister(reg, value: value)
            } else {
                try rmw(reg, value: value, mask: mask)
            }
        }
    }

    /// Applies the Base UsbSetting from apollo2640.set.
    /// Must be called once at connect time (alt=0) before any streaming.
    /// This primes the 1C/1D command FIFO with the initial state.
    public func applyBaseUSBConfig() throws {
        try transport.writeRegister(Register.sccbId,     value: 0x60)  // f1=0x60 SCCB slave addr
        try transport.writeRegister(Register.hSizeLow,   value: 0xFF)  // 88=0xFF accept any
        try transport.writeRegister(Register.hSizeHigh,  value: 0xFF)  // 89=0xFF
        try transport.writeRegister(Register.vSizeLow,   value: 0xFF)  // 8a=0xFF
        try transport.writeRegister(Register.vSizeHigh,  value: 0xFF)  // 8b=0xFF
        try transport.writeRegister(Register.isoControl,  value: 0x01)  // 8c=0x01
        try transport.writeRegister(Register.inputFormat, value: 0x1C)  // 8d=0x1c RAW
        try transport.writeRegister(Register.outputFmt1,  value: 0x00)  // 1c=0x00
        try transport.writeRegister(Register.outputFmt2,  value: 0x08)  // 1d=0x08 RAW/ISO
        try transport.writeRegister(Register.outputFmt2,  value: 0x00)  // 1d=0x00
        try transport.writeRegister(Register.outputFmt2,  value: 0xFF)  // 1d=0xFF
        try transport.writeRegister(Register.outputFmt1,  value: 0x0A)  // 1c=0x0a
        try transport.writeRegister(Register.outputFmt2,  value: 0x2E)  // 1d=0x2e
        try transport.writeRegister(Register.outputFmt2,  value: 0x1E)  // 1d=0x1e
    }

    /// Applies the FrameRate1 UsbSetting from apollo2640.set 1600×1200RAW8.
    /// Called once at stream start (after sensor init, before alt=1).
    public func configureForOV2640RAW8() throws {
        try transport.writeRegister(Register.cclk,       value: 0x04)  // e5=0x04 CCLK 24MHz
        try transport.writeRegister(Register.isoControl, value: 0x00)  // 8c=0x00
        try transport.writeRegister(Register.inputFormat, value: 0x1C) // 8d=0x1c RAW
        try transport.writeRegister(Register.outputFmt1, value: 0x00)  // 1c=0x00
        try transport.writeRegister(Register.outputFmt2, value: 0x08)  // 1d=0x08
        try transport.writeRegister(0x35, value: 0x00)                 // 35=0x00 no JPEG
        try transport.writeRegister(0xD9, value: 0x21)                 // d9=0x21
        try transport.writeRegister(0xDA, value: 0x00)                 // da=0x00
        try transport.writeRegister(0xC3, value: 0xF9)                 // c3=0xf9 enable PRE
        try transport.writeRegister(Register.outputFmt1, value: 0x0A)  // 1c=0x0a
        try transport.writeRegister(Register.outputFmt2, value: 0x12)  // 1d=0x12 (≈1200 rows; was 0x0a=676 rows)
        try transport.writeRegister(Register.outputFmt2, value: 0x1E)  // 1d=0x1e
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    private func rmw(_ reg: UInt16, value: UInt8, mask: UInt8) throws {
        let current = try transport.readRegister(reg)
        let newVal  = (current & ~mask) | (value & mask)
        try transport.writeRegister(reg, value: newVal)
    }
}
