// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — high-level scanner device.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation
import AppKit
import DiaScannerUSBBridge

/// High-level API for the PX-2130 slide scanner.
/// Coordinates the OV550 bridge chip, OV5621 sensor, and frame capture pipeline.
@MainActor
public final class ScannerDevice: ObservableObject {

    public static let frameWidth  = OV5621Sensor.frameWidth
    public static let frameHeight = OV5621Sensor.frameHeight

    @Published public var isConnected   = false
    @Published public var isBusy        = false
    @Published public var lastError: String?
    @Published public var capturedImage: NSImage?
    @Published public var liveFrame:     NSImage?

    private var usbDevice:    OVUSBDevice?
    private var transport:    IOKitUSBTransport?
    private var ov5621:       OV5621Sensor?
    private var streamTask:   Task<Void, Never>?

    public init() {}

    // ─── Logging ───────────────────────────────────────────────────

    private static nonisolated func log(_ msg: String) {
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

    // ─── Connect / Disconnect ──────────────────────────────────────

    public func connect() async {
        Self.log("connect() called")
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        let device = OVUSBDevice()
        do {
            Self.log("connectScanner()")
            try device.connectScanner()
        } catch {
            Self.log("connectScanner FAILED: \(error)")
            lastError = error.localizedDescription
            return
        }

        let xport  = IOKitUSBTransport(device: device)
        let sensor = OV5621Sensor(transport: xport)

        do {
            Self.log("detecting sensor…")
            let id = try sensor.detect()
            Self.log(String(format: "sensor_id=0x%04X", id))
            guard (id & 0xFFF0) == 0x5620 else {
                throw NSError(domain: "diascanner", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(format: "Expected OV5621 (0x562X), got 0x%04X", id)
                ])
            }

            Self.log("applying bridge+sensor init…")
            try sensor.initializeAndStart()
            Self.log("setAlternateInterface(1)")
            try device.setAlternateInterface(1)

            // Let AEC/AGC converge before the first capture.
            try await Task.sleep(nanoseconds: 1_500_000_000)

            usbDevice   = device
            transport   = xport
            ov5621      = sensor
            isConnected = true
            Self.log("connected!")
            startLivePreview()
        } catch {
            Self.log("connect FAILED: \(error)")
            lastError = error.localizedDescription
            device.disconnectScanner()
        }
    }

    public func disconnect() {
        streamTask?.cancel()
        streamTask  = nil
        liveFrame   = nil
        try? ov5621?.stop()
        usbDevice?.disconnectScanner()
        usbDevice   = nil
        transport   = nil
        ov5621      = nil
        isConnected = false
    }

    private func startLivePreview() {
        guard let device = usbDevice else { return }
        let width    = OV5621Sensor.frameWidth
        let height   = OV5621Sensor.frameHeight
        let expected = UInt(OV5621Sensor.frameBytes)

        streamTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    let raw = try device.readFrame(withTimeout: 3.0, frameBytes: expected)
                    if Task.isCancelled { break }
                    let rows = raw.count / width
                    let h    = min(height, rows)
                    guard h > 0 else { continue }
                    let trimmed = raw.count == width * h ? raw : Data(raw.prefix(width * h))
                    let rgb = BayerDemosaic.demosaic(trimmed, width: width, height: h, pattern: .bggr)
                    guard let image = BayerDemosaic.nsImage(fromRGB: rgb, width: width, height: h) else { continue }
                    if Task.isCancelled { break }
                    await MainActor.run { self.liveFrame = image }
                } catch {
                    if Task.isCancelled { break }
                    ScannerDevice.log("livePreview: \(error)")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    // ─── Capture ───────────────────────────────────────────────────

    public func captureFrame() async {
        guard isConnected else {
            lastError = "Scanner not connected"
            return
        }
        guard let frame = liveFrame else {
            lastError = "No live frame available yet"
            return
        }
        capturedImage = frame
        Self.log("captureFrame: snapshot from live feed")
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
