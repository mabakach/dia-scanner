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
    @Published public var liveFrame:     NSImage?
    @Published public var isNegativeMode    = false
    @Published public var vignetteK: Float  = PositiveFilter.defaultVignetteK
    @Published public var autoLevelsEnabled = true
    @Published public var brightness: Float = 0.0
    @Published public var contrast:   Float = 0.0
    @Published public var histogram: RGBHistogram?

    private var usbDevice:       OVUSBDevice?
    private var transport:       IOKitUSBTransport?
    private var ov5621:          OV5621Sensor?
    private var streamTask:      Task<Void, Never>?
    private var latestRawBayer:  Data?
    private var cancellables = Set<AnyCancellable>()

    // Events fed into the single stream-loop: either a new USB frame or a
    // "re-render with current settings" signal from a slider change.
    private enum StreamEvent: Sendable {
        case frame(Data)
        case rerender
    }

    // The continuation is written on the main actor (in startLivePreview / disconnect)
    // and read from @Published sink closures that also run on the main thread.
    // nonisolated(unsafe) opts out of the type-system check; the runtime guarantee holds.
    nonisolated(unsafe) private var reRenderCont: AsyncStream<StreamEvent>.Continuation?

    public init() {
        // When any filter setting changes, push a rerender event so the live stream
        // loop picks it up immediately without waiting for the next USB frame.
        // Also re-render the captured image (if any) through a separate task.
        let rerenderLive: (Any) -> Void = { [weak self] _ in
            self?.reRenderCont?.yield(.rerender)
        }
        $isNegativeMode .dropFirst().sink(receiveValue: rerenderLive).store(in: &cancellables)
        $vignetteK      .dropFirst().sink(receiveValue: rerenderLive).store(in: &cancellables)
        $autoLevelsEnabled.dropFirst().sink(receiveValue: rerenderLive).store(in: &cancellables)
        $brightness     .dropFirst().sink(receiveValue: rerenderLive).store(in: &cancellables)
        $contrast       .dropFirst().sink(receiveValue: rerenderLive).store(in: &cancellables)
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
        reRenderCont?.finish()
        reRenderCont = nil
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

        // Both the AsyncStream and its continuation are created in a nonisolated context
        // so they are never in the main actor's region. The ObjC frame-handler closure
        // captures only the nonisolated continuation, satisfying 'sending' requirements.
        let eventStream: AsyncStream<StreamEvent>
        do {
            let (stream, cont) = try Self.beginStreamingEvents(on: device, frameBytes: expected)
            eventStream = stream
            reRenderCont = cont
        } catch {
            Self.log("startStreaming failed: \(error)")
            lastError = error.localizedDescription
            return
        }

        // Single sequential loop handles BOTH USB frames and slider-change rerenders.
        // No concurrent tasks race over liveFrame: only one processRaw runs at a time.
        // negClips holds EMA-smoothed auto-levels clip points for negatives, eliminating
        // frame-to-frame oscillation caused by per-frame histogram recomputation.
        streamTask = Task {
            var negClips: NegativeFilter.Clips?
            var posClips: PositiveFilter.Clips?
            for await event in eventStream {
                let rawToProcess: Data
                switch event {
                case .frame(let data):
                    self.latestRawBayer = data
                    rawToProcess = data
                case .rerender:
                    guard let latest = self.latestRawBayer else { continue }
                    rawToProcess = latest
                    negClips = nil  // reset smoothing when settings change
                    posClips = nil
                }
                let negative   = self.isNegativeMode
                let vk         = self.vignetteK
                let autoLevels = self.autoLevelsEnabled
                let bright     = self.brightness
                let cont       = self.contrast
                let capNeg     = negClips
                let capPos     = posClips
                let result: (NSImage, RGBHistogram, NegativeFilter.Clips?, PositiveFilter.Clips?)? =
                    await Task.detached(priority: .userInitiated) {
                        Self.processRaw(rawToProcess, width: width, maxHeight: height,
                                        negative: negative, vignetteK: vk, autoLevels: autoLevels,
                                        brightness: bright, contrast: cont,
                                        negClips: capNeg, posClips: capPos)
                    }.value
                guard !Task.isCancelled,
                      let (image, hist, freshNeg, freshPos) = result else { continue }
                self.liveFrame  = image
                self.histogram  = hist
                // Update smoothed clips: snap immediately on scene change (new slide),
                // otherwise blend with EMA to suppress frame-to-frame sensor noise.
                if let fc = freshNeg {
                    if let nc = negClips, !nc.hasSceneChange(vs: fc) {
                        negClips = nc.blended(with: fc, alpha: 0.15)
                    } else {
                        negClips = fc
                    }
                }
                if let fc = freshPos {
                    if let pc = posClips, !pc.hasSceneChange(vs: fc) {
                        posClips = pc.blended(with: fc, alpha: 0.15)
                    } else {
                        posClips = fc
                    }
                }
            }
        }
    }

    // Both AsyncStream<StreamEvent> and its continuation are created here, in a nonisolated
    // context. The ObjC frame-handler closure captures only the continuation (which is
    // nonisolated and Sendable), so it can be passed as 'sending' without isolation errors.
    private static nonisolated func beginStreamingEvents(
        on device: OVUSBDevice,
        frameBytes: UInt
    ) throws -> (AsyncStream<StreamEvent>, AsyncStream<StreamEvent>.Continuation) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: StreamEvent.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        try device.startStreaming(withFrameBytes: frameBytes) { rawData in
            continuation.yield(.frame(rawData))
        }
        return (stream, continuation)
    }

    // Shared image processing pipeline used by the live stream loop.
    // `negClips`/`posClips`: smoothed clip points from previous frames (nil = fresh, first frame).
    // Returns image, histogram, and fresh clips for whichever mode is active (for EMA in caller).
    private static nonisolated func processRaw(
        _ rawData: Data,
        width: Int,
        maxHeight: Int,
        negative: Bool,
        vignetteK: Float,
        autoLevels: Bool,
        brightness: Float,
        contrast: Float,
        negClips: NegativeFilter.Clips? = nil,
        posClips: PositiveFilter.Clips? = nil
    ) -> (NSImage, RGBHistogram, NegativeFilter.Clips?, PositiveFilter.Clips?)? {
        let rows    = rawData.count / width
        let h       = min(maxHeight, rows)
        guard h > 0 else { return nil }
        let trimmed = rawData.count == width * h ? rawData : Data(rawData.prefix(width * h))
        var rgb = BayerDemosaic.demosaic(trimmed, width: width, height: h, pattern: .bggr)
        var freshNeg: NegativeFilter.Clips?
        var freshPos: PositiveFilter.Clips?
        if negative {
            rgb = PositiveFilter.applyVignetting(to: rgb, width: width, height: h, vignetteK: vignetteK)
            (rgb, freshNeg) = NegativeFilter.apply(to: rgb, width: width, height: h,
                                                    applyAutoLevels: autoLevels, clips: negClips)
        } else {
            (rgb, freshPos) = PositiveFilter.apply(to: rgb, width: width, height: h,
                                                    vignetteK: vignetteK, applyAutoLevels: autoLevels,
                                                    clips: posClips)
        }
        if brightness != 0 || contrast != 0 {
            rgb = BrightnessContrastFilter.apply(to: rgb, width: width, height: h,
                                                 brightness: brightness, contrast: contrast)
        }
        let hist = RGBHistogram.compute(from: rgb, pixelCount: width * h)
        guard let img = BayerDemosaic.nsImage(fromRGB: rgb, width: width, height: h) else { return nil }
        return (img, hist, freshNeg, freshPos)
    }

    // ─── Adjustments ───────────────────────────────────────────────

    public func resetAdjustments() {
        autoLevelsEnabled = true
        brightness        = 0.0
        contrast          = 0.0
        vignetteK         = PositiveFilter.defaultVignetteK
    }

    // ─── Save ──────────────────────────────────────────────────────

    public func saveImage(
        _ image: NSImage,
        to url: URL,
        format: OutputFormat = .png,
        quality: Double = 0.85
    ) throws {
        let data = try format.encode(image, quality: quality)
        try data.write(to: url)
    }
}
