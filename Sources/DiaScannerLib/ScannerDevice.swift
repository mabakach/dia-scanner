// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 *
 * Based on ov2640 Camera Driver
 * Copyright (C) 2010 Alberto Panizzo <maramaopercheseimorto@gmail.com>
 * Copyright 2005-2009 Freescale Semiconductor, Inc. All Rights Reserved.
 * Copyright (C) 2006, OmniVision
 */

import Foundation
import AppKit
import DiaScannerUSBBridge

/// High-level API for the PX-2130 slide scanner.
/// Coordinates the OV550 bridge chip, OV2640 sensor, and frame capture pipeline.
@MainActor
public final class ScannerDevice: ObservableObject {

    public static let frameWidth  = 1600
    public static let frameHeight = 1200

    @Published public var isConnected   = false
    @Published public var isBusy        = false
    @Published public var lastError: String?
    @Published public var capturedImage: NSImage?

    private var usbDevice: OVUSBDevice?
    private var transport: IOKitUSBTransport?
    private var ov550:    OV550Controller?
    private var ov2640:   OV2640Sensor?

    public init() {}

    // ─── Connect / Disconnect ──────────────────────────────────────

    private static func log(_ msg: String) {
        let line = "\(Date()): \(msg)\n"
        let logURL = URL(fileURLWithPath: "/tmp/diascanner.log")
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.data(using: .utf8)!.write(to: logURL)
        }
    }

    public func connect() async {
        Self.log("connect() called")
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        let device = OVUSBDevice()
        do {
            Self.log("calling connectScanner()")
            try device.connectScanner()
            Self.log("connectScanner() succeeded")
        } catch {
            Self.log("connectScanner() FAILED: \(error)")
            lastError = error.localizedDescription
            return
        }

        let xport  = IOKitUSBTransport(device: device)
        let ctrl   = OV550Controller(transport: xport)
        let sensor = OV2640Sensor(transport: xport)

        do {
            Self.log("powerOn…")
            try ctrl.powerOn()
            try await Task.sleep(nanoseconds: 500_000_000)  // 500ms — MCLK/sensor power stabilisation
            Self.log("setLED…")
            try ctrl.setLED(on: true)
            Self.log("configureUSB…")
            try ctrl.configureForOV2640RAW8()
            try await Task.sleep(nanoseconds: 1_000_000_000)  // 1s — MCLK to OV2640 must stabilise before SCCB
            Self.log("probing SCCB ACK…")
            device.probeI2CBridge()
            Self.log("SCCB probe done")

            Self.log("verifyChipID…")
            let validID = try sensor.verifyChipID()
            Self.log("chipID valid=\(validID)")
            if !validID {
                lastError = "Sensor chip ID mismatch — is this the correct scanner?"
                device.disconnectScanner()
                return
            }

            Self.log("initialize sensor…")
            try sensor.initialize()
            Self.log("sensor init done")

            usbDevice = device
            transport = xport
            ov550     = ctrl
            ov2640    = sensor
            isConnected = true
            Self.log("connected!")
        } catch {
            Self.log("connect FAILED: \(error)")
            lastError = error.localizedDescription
            device.disconnectScanner()
        }
    }

    public func disconnect() {
        usbDevice?.disconnectScanner()
        usbDevice   = nil
        transport   = nil
        ov550       = nil
        ov2640      = nil
        isConnected = false
    }

    // ─── Capture ───────────────────────────────────────────────────

    public func captureFrame() async {
        guard isConnected, let device = usbDevice, let ctrl = ov550, let sensor = ov2640 else {
            lastError = "Scanner not connected"
            return
        }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            Self.log("captureFrame: applyFrameRate1…")
            try sensor.applyFrameRate1()
            Self.log("captureFrame: startStream…")
            try ctrl.startStream()
            try await Task.sleep(nanoseconds: 200_000_000)  // 200ms — sensor stabilisation
            Self.log("captureFrame: readFrame…")

            let rawData: Data = try await Task.detached(priority: .userInitiated) {
                try device.readFrame(withTimeout: 10.0)
            }.value

            Self.log("captureFrame: got \(rawData.count) bytes raw")
            try? ctrl.blockStream()
            try? ctrl.setLED(on: false)

            let rgb = BayerDemosaic.demosaic(rawData,
                                             width:   ScannerDevice.frameWidth,
                                             height:  ScannerDevice.frameHeight,
                                             pattern: .rggb)
            if let image = BayerDemosaic.nsImage(fromRGB: rgb,
                                                 width:   ScannerDevice.frameWidth,
                                                 height:  ScannerDevice.frameHeight) {
                Self.log("captureFrame: image created \(Int(image.size.width))x\(Int(image.size.height))")
                capturedImage = image
            } else {
                lastError = "Failed to create image from raw frame data"
            }
        } catch {
            Self.log("captureFrame: FAILED: \(error)")
            try? ctrl.blockStream()
            lastError = error.localizedDescription
        }
    }

    // ─── Save ──────────────────────────────────────────────────────

    public func saveImage(to url: URL) throws {
        guard let image = capturedImage else {
            throw ScannerError.invalidData("No captured image to save")
        }
        guard let tiff   = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png    = bitmap.representation(using: .png, properties: [:])
        else {
            throw ScannerError.invalidData("Failed to encode image as PNG")
        }
        try png.write(to: url)
    }
}
