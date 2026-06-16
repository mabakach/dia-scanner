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

    private var usbDevice:          OVUSBDevice?
    private var transport:          IOKitUSBTransport?
    private var ov5621:             OV5621Sensor?
    private var streamContinuation: AsyncStream<Data>.Continuation?
    private var streamTask:         Task<Void, Never>?

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

    public func disconnect() async {
        isConnected = false
        liveFrame   = nil
        // End the stream so the consumer task exits its for-await loop.
        streamContinuation?.finish()
        streamContinuation = nil
        streamTask?.cancel()
        streamTask = nil
        // Stop USB on a background thread — stopStreaming blocks up to 3 s.
        let device = usbDevice
        let sensor = ov5621
        usbDevice  = nil
        transport  = nil
        ov5621     = nil
        await Task.detached {
            device?.stopStreaming()
            try? sensor?.stop()
            device?.disconnectScanner()
        }.value
    }

    private func startLivePreview() {
        guard let device = usbDevice else { return }
        let width    = OV5621Sensor.frameWidth
        let height   = OV5621Sensor.frameHeight
        let expected = UInt(OV5621Sensor.frameBytes)

        // Use AsyncStream as a bridge: the ObjC handler only captures 'continuation'
        // (Sendable), satisfying Swift's 'sending' requirement without touching any
        // main-actor-isolated state from the isoch callback queue.
        // bufferingNewest(1) drops stale frames when demosaic can't keep up.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        streamContinuation = continuation

        do {
            try device.startStreaming(withFrameBytes: expected) { rawData in
                continuation.yield(rawData)
            }
        } catch {
            continuation.finish()
            streamContinuation = nil
            Self.log("startStreaming failed: \(error)")
            lastError = error.localizedDescription
            return
        }

        // Consume frames on the main actor; demosaic runs in a detached task.
        streamTask = Task {
            for await rawData in stream {
                let image: NSImage? = await Task.detached(priority: .userInitiated) {
                    let rows = rawData.count / width
                    let h    = min(height, rows)
                    guard h > 0 else { return nil }
                    let trimmed = rawData.count == width * h
                        ? rawData : Data(rawData.prefix(width * h))
                    let rgb = BayerDemosaic.demosaic(trimmed, width: width, height: h, pattern: .bggr)
                    return BayerDemosaic.nsImage(fromRGB: rgb, width: width, height: h)
                }.value
                guard !Task.isCancelled, let image else { continue }
                self.liveFrame = image
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
