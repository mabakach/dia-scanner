// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — high-level scanner device.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation
import AppKit
import Combine
import DiaScannerUSBBridge

/// High-level API for the PX-2130 slide scanner.
/// Coordinates the OV550 bridge chip, OV5621 sensor, and frame capture pipeline.
@MainActor
public final class ScannerDevice: ObservableObject {

    public static let frameWidth  = OV5621Sensor.frameWidth
    public static let frameHeight = OV5621Sensor.frameHeight

    @Published public var isConnected    = false
    @Published public var isBusy         = false
    @Published public var lastError: String?
    @Published public var capturedImage: NSImage?
    @Published public var liveFrame:     NSImage?
    @Published public var isNegativeMode    = false
    @Published public var vignetteK: Float  = PositiveFilter.defaultVignetteK
    @Published public var autoLevelsEnabled = true
    @Published public var histogram: RGBHistogram?

    private var usbDevice:       OVUSBDevice?
    private var transport:       IOKitUSBTransport?
    private var ov5621:          OV5621Sensor?
    private var streamTask:      Task<Void, Never>?
    private var latestRawBayer:  Data?
    private var capturedRawBayer: Data?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        $isNegativeMode
            .dropFirst()
            .sink { [weak self] _ in Task { [weak self] in await self?.renderCapturedImage() } }
            .store(in: &cancellables)
        $vignetteK
            .dropFirst()
            .sink { [weak self] _ in Task { [weak self] in await self?.renderCapturedImage() } }
            .store(in: &cancellables)
        $autoLevelsEnabled
            .dropFirst()
            .sink { [weak self] _ in Task { [weak self] in await self?.renderCapturedImage() } }
            .store(in: &cancellables)
    }

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
        isConnected    = false
        liveFrame      = nil
        histogram      = nil
        latestRawBayer = nil
        // Cancelling the consumer task ends the AsyncStream for-await loop automatically.
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

        // Stream and continuation are created in a nonisolated context so they are
        // never in the main actor's region. Only the Sendable AsyncStream crosses
        // back to the main actor. The continuation stays nonisolated for its lifetime,
        // making the ObjC 'sending' handler closure trivially region-safe.
        let stream: AsyncStream<Data>
        do {
            stream = try Self.beginStreaming(on: device, frameBytes: expected)
        } catch {
            Self.log("startStreaming failed: \(error)")
            lastError = error.localizedDescription
            return
        }

        // Consume frames on the main actor; demosaic runs in a detached task.
        // bufferingNewest(1) (set in beginStreaming) drops stale frames when
        // demosaic can't keep up. Task cancellation ends the for-await loop.
        streamTask = Task {
            for await rawData in stream {
                self.latestRawBayer = rawData
                let negative    = self.isNegativeMode
                let vk          = self.vignetteK
                let autoLevels  = self.autoLevelsEnabled
                let result: (NSImage, RGBHistogram)? = await Task.detached(priority: .userInitiated) {
                    let rows = rawData.count / width
                    let h    = min(height, rows)
                    guard h > 0 else { return nil }
                    let trimmed = rawData.count == width * h
                        ? rawData : Data(rawData.prefix(width * h))
                    var rgb = BayerDemosaic.demosaic(trimmed, width: width, height: h, pattern: .bggr)
                    if negative {
                        rgb = PositiveFilter.applyVignetting(to: rgb, width: width, height: h, vignetteK: vk)
                        rgb = NegativeFilter.apply(to: rgb, width: width, height: h, applyAutoLevels: autoLevels)
                    } else {
                        rgb = PositiveFilter.apply(to: rgb, width: width, height: h, vignetteK: vk,
                                                   applyAutoLevels: autoLevels)
                    }
                    let hist = RGBHistogram.compute(from: rgb, pixelCount: width * h)
                    guard let img = BayerDemosaic.nsImage(fromRGB: rgb, width: width, height: h)
                    else { return nil }
                    return (img, hist)
                }.value
                guard !Task.isCancelled, let (image, hist) = result else { continue }
                self.liveFrame  = image
                self.histogram  = hist
            }
        }
    }

    // Both AsyncStream and its continuation are created here, in a nonisolated
    // context. The continuation is captured by the frame handler closure and never
    // touches the main actor's region, so it can be passed as a 'sending' parameter
    // to the ObjC startStreaming method without a region-isolation error.
    private static nonisolated func beginStreaming(
        on device: OVUSBDevice,
        frameBytes: UInt
    ) throws -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        try device.startStreaming(withFrameBytes: frameBytes) { rawData in
            continuation.yield(rawData)
        }
        return stream
    }

    // ─── Capture ───────────────────────────────────────────────────

    public func captureFrame() async {
        guard isConnected else {
            lastError = "Scanner not connected"
            return
        }
        guard let raw = latestRawBayer else {
            lastError = "No raw frame available yet"
            return
        }
        capturedRawBayer = raw
        await renderCapturedImage()
        Self.log("captureFrame: raw Bayer frame captured")
    }

    // Renders capturedImage from capturedRawBayer using the current filter settings.
    // Called at capture time and whenever any filter setting changes while raw data is held.
    private func renderCapturedImage() async {
        guard let raw = capturedRawBayer else { return }
        let width      = ScannerDevice.frameWidth
        let height     = ScannerDevice.frameHeight
        let negative   = isNegativeMode
        let vk         = vignetteK
        let autoLevels = autoLevelsEnabled
        let result: (NSImage, RGBHistogram)? = await Task.detached(priority: .userInitiated) {
            var rgb = BayerDemosaic.demosaic(raw, width: width, height: height, pattern: .bggr)
            if negative {
                rgb = PositiveFilter.applyVignetting(to: rgb, width: width, height: height, vignetteK: vk)
                rgb = NegativeFilter.apply(to: rgb, width: width, height: height, applyAutoLevels: autoLevels)
            } else {
                rgb = PositiveFilter.apply(to: rgb, width: width, height: height, vignetteK: vk,
                                           applyAutoLevels: autoLevels)
            }
            let hist = RGBHistogram.compute(from: rgb, pixelCount: width * height)
            guard let img = BayerDemosaic.nsImage(fromRGB: rgb, width: width, height: height)
            else { return nil }
            return (img, hist)
        }.value
        guard let (image, hist) = result else { return }
        capturedImage = image
        histogram     = hist
    }

    // ─── Save ──────────────────────────────────────────────────────

    public func saveImage(_ image: NSImage, to url: URL) throws {
        guard let tiff   = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png    = bitmap.representation(using: .png, properties: [:])
        else {
            throw ScannerError.invalidData("Failed to encode image as PNG")
        }
        try png.write(to: url)
    }
}
