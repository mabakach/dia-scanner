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

    private var usbDevice: OVUSBDevice?
    private var transport: IOKitUSBTransport?
    private var ov5621:    OV5621Sensor?

    public init() {}

    // ─── Logging ───────────────────────────────────────────────────

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
        } catch {
            Self.log("connect FAILED: \(error)")
            lastError = error.localizedDescription
            device.disconnectScanner()
        }
    }

    public func disconnect() {
        try? ov5621?.stop()
        usbDevice?.disconnectScanner()
        usbDevice   = nil
        transport   = nil
        ov5621      = nil
        isConnected = false
    }

    // ─── Capture ───────────────────────────────────────────────────

    public func captureFrame() async {
        guard isConnected, let device = usbDevice else {
            lastError = "Scanner not connected"
            return
        }
        isBusy = true
        lastError = nil
        defer { isBusy = false }

        do {
            Self.log("captureFrame: rawIsochDump 5s…")
            let rawData: Data = try await Task.detached(priority: .userInitiated) {
                try Self.captureOneFrame(device: device)
            }.value

            Self.log("captureFrame: got \(rawData.count) bytes — demosaicing…")
            let width  = OV5621Sensor.frameWidth
            let rows   = rawData.count / width
            let height = min(OV5621Sensor.frameHeight, rows)
            let trimmed = rawData.count == width * height
                ? rawData
                : Data(rawData.prefix(width * height))

            let rgb = BayerDemosaic.demosaic(trimmed, width: width, height: height, pattern: .bggr)
            if let image = BayerDemosaic.nsImage(fromRGB: rgb, width: width, height: height) {
                Self.log("captureFrame: image \(Int(image.size.width))×\(Int(image.size.height))")
                capturedImage = image
            } else {
                lastError = "Failed to create image from raw frame data"
            }
        } catch {
            Self.log("captureFrame FAILED: \(error)")
            lastError = error.localizedDescription
        }
    }

    /// Blocking helper — runs on a detached task. Dumps the isoch stream for 5 s,
    /// parses PTS groups, and returns the payload of the largest (best) group.
    private static nonisolated func captureOneFrame(device: OVUSBDevice) throws -> Data {
        let sizes = NSMutableArray()
        let dump  = try device.rawIsochDump(withDuration: 5.0, packetSizes: sizes)
        let pktSizes = (sizes as! [NSNumber]).map { $0.intValue }

        var groups: [(pts: UInt32, fid: UInt8, payload: Data)] = []
        var curPayload = Data()
        var curPts: UInt32 = 0
        var curFid: UInt8  = 0
        var haveCur = false
        var off = 0

        dump.withUnsafeBytes { rawPtr in
            let bytes = rawPtr.bindMemory(to: UInt8.self).baseAddress!
            for sz in pktSizes {
                if sz < 12 { off += sz; continue }
                let flags = bytes[off + 1]
                let pts = UInt32(bytes[off+2]) | (UInt32(bytes[off+3]) << 8)
                        | (UInt32(bytes[off+4]) << 16) | (UInt32(bytes[off+5]) << 24)
                let fid: UInt8 = flags & 1
                if !haveCur { curPts = pts; curFid = fid; haveCur = true }
                if pts != curPts || fid != curFid {
                    groups.append((curPts, curFid, curPayload))
                    curPayload = Data()
                    curPts = pts; curFid = fid
                }
                curPayload.append(Data(bytes: bytes + off + 12, count: sz - 12))
                off += sz
            }
        }
        if haveCur { groups.append((curPts, curFid, curPayload)) }

        guard let biggest = groups.max(by: { $0.payload.count < $1.payload.count }) else {
            throw NSError(domain: "diascanner", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No frame data received"])
        }

        var raw = biggest.payload
        if raw.count >= 4, raw.suffix(4) == Data([0xFF, 0x5A, 0xA5, 0x01]) {
            raw = raw.prefix(raw.count - 4)
        }
        return Data(raw)
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
