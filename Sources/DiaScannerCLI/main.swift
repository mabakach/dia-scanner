import Foundation
import AppKit
import DiaScannerLib
import DiaScannerUSBBridge

// CLI runner: connect → init → capture → save PNG + raw
// Usage: swift run DiaScannerCLI [output-path]

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/diascanner_capture"

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
    let ov550     = OV550Controller(transport: transport)
    let sensor    = OV2640Sensor(transport: transport)

    defer {
        try? ov550.blockStream()
        try? transport.writeRegister(0xE5, value: 0x00)
        Thread.sleep(forTimeInterval: 0.2)
        device.clearSCCBStatus()
        try? transport.writeSensorRegister(0xFF, value: 0x01)
        try? transport.writeSensorRegister(0x12, value: 0x80)  // soft reset
        Thread.sleep(forTimeInterval: 0.1)
        device.clearSCCBStatus()
        try? ov550.powerDown()
        try? ov550.setLED(on: false)
    }

    log("CLI: powerCycle (clears stale SCCB)")
    try ov550.powerDown()
    Thread.sleep(forTimeInterval: 0.2)
    try ov550.powerOn()
    Thread.sleep(forTimeInterval: 2.0)
    device.clearSCCBStatus()

    if (try? transport.writeSensorRegister(0xFF, value: 0x01)) == nil {
        log("CLI: SCCB probe NACK — retrying power cycle (3s settle)")
        try ov550.powerDown()
        Thread.sleep(forTimeInterval: 0.5)
        try ov550.powerOn()
        Thread.sleep(forTimeInterval: 3.0)
        device.clearSCCBStatus()
        log("CLI: SCCB retry power cycle done")
    } else {
        // Probe succeeded; restore DSP bank so applyBaseUSBConfig starts clean
        try? transport.writeSensorRegister(0xFF, value: 0x00)
        device.clearSCCBStatus()
    }

    // Apply Base UsbSetting with E0=0x08 (SCCB controller free).
    log("CLI: applyBaseUSBConfig (E0=0x08)")
    try ov550.applyBaseUSBConfig()
    Thread.sleep(forTimeInterval: 0.2)
    device.clearSCCBStatus()

    // Initialize sensor BEFORE setLED (which sets E0=0x00).
    log("CLI: sensor.initialize() (E0=0x08)")
    try sensor.initialize()
    log("CLI: sensor init done")

    log("CLI: applyFrameRate1 sensor regs")
    try sensor.applyFrameRate1()

    // Verify sensor registers were written correctly.
    do {
        try transport.writeSensorRegister(0xFF, value: 0x01)  // sensor bank
        let clkrc = try? device.readSensorRegister(0x11)
        let com1  = try? device.readSensorRegister(0x04)
        log(String(format: "CLI: sensor verify: CLKRC=0x%02X (expect 0x07) COM1=0x%02X (expect 0x33)",
                   clkrc?.uint8Value ?? 0xFF, com1?.uint8Value ?? 0xFF))
        try transport.writeSensorRegister(0xFF, value: 0x00)  // back to DSP bank
    } catch {
        log("CLI: sensor verify failed: \(error)")
    }

    // Enable LED and let OV550 sync with sensor before FIFO latching.
    log("CLI: setLED on + 3s OV550 sync (E0=0x00)")
    try ov550.setLED(on: true)
    Thread.sleep(forTimeInterval: 3.0)

    log("CLI: blockStream before FrameRate1 UsbSetting")
    try ov550.blockStream()
    log("CLI: configureForOV2640RAW8 (FrameRate1 UsbSetting, E0=0x08)")
    try ov550.configureForOV2640RAW8()
    log("CLI: MCLK/PLL settle 1s")
    Thread.sleep(forTimeInterval: 1.0)

    log("CLI: setAlternateInterface(1)")
    try device.setAlternateInterface(1)

    log("CLI: re-apply configureForOV2640RAW8 after alt=1 (E0=0x08)")
    try ov550.configureForOV2640RAW8()

    log("CLI: dumping key ASIC regs before stream")
    for reg: UInt16 in [0x0F, 0x1C, 0x35, 0xDA, 0xE0, 0xE5, 0xE7, 0x8C, 0x8D] {
        if let v = try? transport.readRegister(reg) {
            log(String(format: "  ASIC 0x%02X = 0x%02X", reg, v))
        }
    }

    log("CLI: readFrame (timeout=15s)")
    let rawData = try device.readFrame(withTimeout: 15.0)
    log("CLI: got \(rawData.count) bytes raw")

    let rawURL = URL(fileURLWithPath: "\(outputPath).raw")
    try rawData.write(to: rawURL)
    log("CLI: raw saved to \(rawURL.path)")

    let frameWidth  = ScannerDevice.frameWidth
    let frameHeight = rawData.count / frameWidth
    log("CLI: frame \(frameWidth)×\(frameHeight) RAW8 (\(rawData.count) bytes)")

    let trimmedData = rawData.count % frameWidth == 0
        ? rawData
        : rawData.prefix(frameHeight * frameWidth)

    let rgb = BayerDemosaic.demosaic(trimmedData, width: frameWidth, height: frameHeight, pattern: .rggb)
    if let img = BayerDemosaic.nsImage(fromRGB: rgb, width: frameWidth, height: frameHeight),
       let tiff   = img.tiffRepresentation,
       let bitmap = NSBitmapImageRep(data: tiff),
       let png    = bitmap.representation(using: .png, properties: [:]) {
        let pngURL = URL(fileURLWithPath: "\(outputPath).png")
        try png.write(to: pngURL)
        log("CLI: PNG saved to \(pngURL.path)")
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
