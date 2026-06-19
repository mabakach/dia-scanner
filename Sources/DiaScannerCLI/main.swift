// SPDX-License-Identifier: GPL-2.0-only
/*
 * PX-2130 Slide Scanner macOS Driver — command-line capture tool.
 *
 * Copyright (C) 2026 Marc Baumgartner <marc@mabaka.ch>
 */

import Foundation
import AppKit
import DiaScannerLib
import DiaScannerUSBBridge

// CLI runner — captures one full 2592×1680 SBGGR8 frame from the OV5621 sensor
// using the gspca_ov534_9 port. Saves raw Bayer to <path>.raw and the demosaiced
// image to <path>.<ext> in the chosen format.
//
// Usage: swift run DiaScannerCLI [output-path] [--format jpeg|png|bmp|tiff|jpeg2000] [--quality 1-100] [--negative]

let cliArgs    = CommandLine.arguments.dropFirst()
let isNegative = cliArgs.contains("--negative")
let outputPath = cliArgs.filter { !$0.hasPrefix("--") }.first ?? "/tmp/diascanner_capture"

func argValue(for flag: String) -> String? {
    guard let idx = cliArgs.firstIndex(of: flag), cliArgs.index(after: idx) < cliArgs.endIndex
    else { return nil }
    return cliArgs[cliArgs.index(after: idx)]
}

let outputFormat: OutputFormat = {
    guard let raw = argValue(for: "--format"),
          let fmt = OutputFormat(rawValue: raw)
    else { return .png }
    return fmt
}()

let jpegQuality: Double = {
    guard let raw = argValue(for: "--quality"), let pct = Double(raw)
    else { return 85 }
    return max(1, min(100, pct)) / 100.0
}()

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    fputs(line, stdout)
    fflush(stdout)
    let logURL = URL(fileURLWithPath: "/tmp/diascanner.log")
    if let fh = try? FileHandle(forWritingTo: logURL) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        try? fh.close()
    } else {
        try? line.data(using: .utf8)?.write(to: logURL)
    }
}

func run() throws {
    log("CLI: opening device")
    let device = OVUSBDevice()
    try device.connectScanner()
    defer { device.disconnectScanner() }
    log("CLI: device open")

    let transport = IOKitUSBTransport(device: device)
    let sensor    = OV5621Sensor(transport: transport)

    // Detect sensor — confirm it really is OV5621 before applying its init.
    log("CLI: probing sensor (gspca bridge reset + chip-ID read)")
    let id = try sensor.detect()
    log(String(format: "CLI: sensor_id=0x%04X", id))
    guard (id & 0xFFF0) == 0x5620 else {
        throw NSError(domain: "diascanner", code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                                 String(format: "Expected OV5621 (0x562X), got 0x%04X", id)])
    }

    // Apply bridge + sensor init sequences from gspca and start the transfer.
    log("CLI: applying ov562x bridge+sensor init sequences")
    try sensor.initializeAndStart()
    log("CLI: init done, transfer started (E0=0x00)")

    // Switch USB interface to alternate setting 1 (isochronous endpoint active).
    log("CLI: setAlternateInterface(1)")
    try device.setAlternateInterface(1)

    // Let AEC/AGC converge.
    Thread.sleep(forTimeInterval: 1.5)

    // Dump the raw stream for 5s, then extract the LARGEST PTS-group as our best
    // partial frame and demosaic it as 2592-wide Bayer.
    log("CLI: rawIsochDump for 5s")
    let sizes = NSMutableArray()
    let dump = try device.rawIsochDump(withDuration: 5.0, packetSizes: sizes)
    let pktSizes = (sizes as! [NSNumber]).map { $0.intValue }
    log("CLI: rawIsochDump got \(dump.count) bytes across \(pktSizes.count) microframes")

    // Parse PTS groups and pick the largest.
    var groups: [(pts: UInt32, fid: UInt8, payload: Data)] = []
    var curPayload = Data()
    var curPts: UInt32 = 0
    var curFid: UInt8 = 0
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
    log("CLI: parsed \(groups.count) PTS groups")

    guard let biggest = groups.max(by: { $0.payload.count < $1.payload.count }) else {
        throw NSError(domain: "diascanner", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "no PTS group received"])
    }
    log(String(format: "CLI: largest group: PTS=0x%08X bytes=%d",
               biggest.pts, biggest.payload.count))

    // Strip the 4-byte end sentinel (FF 5A A5 01) before treating as image data.
    var raw = biggest.payload
    if raw.count >= 4, raw.suffix(4) == Data([0xFF, 0x5A, 0xA5, 0x01]) {
        raw = raw.prefix(raw.count - 4)
    }

    // Cleanup: stop streaming before disconnect.
    try? sensor.stop()

    // Save raw Bayer.
    let rawURL = URL(fileURLWithPath: "\(outputPath).raw")
    try raw.write(to: rawURL)
    log("CLI: raw Bayer saved to \(rawURL.path)")

    // Demosaic and save. OV5621 outputs BGGR Bayer pattern (SBGGR8).
    let width  = OV5621Sensor.frameWidth
    let rowsAvailable = raw.count / width
    let height = min(OV5621Sensor.frameHeight, rowsAvailable)
    log("CLI: demosaicing \(width)×\(height) BGGR8\(isNegative ? " (negative mode)" : "")")
    let trimmed = raw.count == width * height ? Data(raw) : Data(raw.prefix(width * height))
    var rgb = BayerDemosaic.demosaic(trimmed, width: width, height: height, pattern: .bggr)
    if isNegative { rgb = NegativeFilter.apply(to: rgb, width: width, height: height) }
    if let img = BayerDemosaic.nsImage(fromRGB: rgb, width: width, height: height) {
        let imgURL = URL(fileURLWithPath: "\(outputPath).\(outputFormat.fileExtension)")
        let data = try outputFormat.encode(img, quality: jpegQuality)
        try data.write(to: imgURL)
        log("CLI: \(outputFormat.displayName) saved to \(imgURL.path)")
    } else {
        log("CLI: demosaic/save failed")
    }
}

do {
    try run()
    log("CLI: SUCCESS")
    exit(0)
} catch {
    log("CLI: FAILED: \(error)")
    exit(1)
}
