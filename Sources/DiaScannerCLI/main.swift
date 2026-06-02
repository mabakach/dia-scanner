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

    // On exit: remove MCLK (E5=0x00) to stop sensor PCLK output without PWDN.
    // OV2640 SCCB receives via SCL (from OV550), independent of MCLK — so SCCB works
    // even with MCLK removed. This frees the OV550 SCCB controller which was busy
    // capturing sensor pixel data. PWDN and blockStream also applied for safety.
    defer {
        try? ov550.blockStream()                              // E0=0x08: stop USB
        try? transport.writeRegister(0xE5, value: 0x00)      // remove MCLK → sensor stops PCLK
        Thread.sleep(forTimeInterval: 0.2)
        device.clearSCCBStatus()
        try? transport.writeSensorRegister(0xFF, value: 0x01)  // sensor bank
        try? transport.writeSensorRegister(0x12, value: 0x80)  // soft reset → factory defaults
        Thread.sleep(forTimeInterval: 0.1)
        device.clearSCCBStatus()
        try? ov550.powerDown()          // PWDN: sensor in standby with factory defaults
        try? ov550.setLED(on: false)
    }

    // Power cycle the sensor to clear any stale SCCB bus state from previous runs.
    // Toggling E7=0x3B→0x3A resets OV2640's power/SCCB state without USB replug.
    log("CLI: powerCycle (clears stale SCCB)")
    try ov550.powerDown()
    Thread.sleep(forTimeInterval: 0.2)
    try ov550.powerOn()
    Thread.sleep(forTimeInterval: 2.0)  // OV2640 needs up to 2s to stabilise after PWDN deassert
    // Read F6 to drain any stale SCCB state.
    device.clearSCCBStatus()

    // Probe with FF=0x01 (sensor bank select) — exactly the first write sensor.initialize()
    // will attempt. If this NACKs, retry the power cycle before proceeding.
    if (try? transport.writeSensorRegister(0xFF, value: 0x01)) == nil {
        log("CLI: SCCB probe NACK — retrying power cycle (3s settle)")
        try ov550.powerDown()
        Thread.sleep(forTimeInterval: 0.5)
        try ov550.powerOn()
        Thread.sleep(forTimeInterval: 3.0)
        device.clearSCCBStatus()
        log("CLI: SCCB retry power cycle done")
    } else {
        // Probe succeeded; restore DSP bank so sensor.initialize() starts clean
        try? transport.writeSensorRegister(0xFF, value: 0x00)
        device.clearSCCBStatus()
    }

    // Apply Base UsbSetting with E0=0x08 (SCCB controller free).
    log("CLI: applyBaseUSBConfig (E0=0x08 still)")
    try ov550.applyBaseUSBConfig()

    // Initialize sensor BEFORE setLED (which sets E0=0x00). On run-2, the sensor comes
    // out of PWDN in RAW8 streaming mode; with E0=0x00 the OV550 SCCB controller is busy
    // capturing sensor data → NACK. Keeping E0=0x08 until sensor init is done fixes this.
    log("CLI: sensor.initialize() (E0=0x08)")
    try sensor.initialize()
    log("CLI: sensor init done")

    // Apply FrameRate1 sensor registers while E0=0x08.
    log("CLI: applyFrameRate1 sensor regs")
    try sensor.applyFrameRate1()

    // Verify sensor is in RAW8 mode: read back CLKRC (0x11) and COM1 (0x04) from sensor bank.
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

    // Enable LED and let OV550 sync with sensor for 3s before FIFO latching.
    // OV550 needs E0=0x00 time to lock its internal capture engine onto the sensor's
    // VSYNC/HREF/PCLK signals; without this warm-up, C3 arms but produces no dense burst.
    log("CLI: setLED on + 3s OV550 sync time (E0=0x00)")
    try ov550.setLED(on: true)
    Thread.sleep(forTimeInterval: 3.0)

    // Apply FrameRate1 UsbSetting with E0=0x08 (BlockStream).
    // The 1C/1D FIFO writes and C3=0xF9 (PRE enable) must be latched while the USB
    // data path is stopped; E0=0x00 (startStream) then kicks off the first frame.
    log("CLI: blockStream before FrameRate1 UsbSetting")
    try ov550.blockStream()
    log("CLI: configureForOV2640RAW8 (FrameRate1 UsbSetting, E0=0x08)")
    try ov550.configureForOV2640RAW8()
    // Allow MCLK and sensor PLL to stabilise
    log("CLI: MCLK/PLL settle 1s")
    Thread.sleep(forTimeInterval: 1.0)

    // Set alt interface 1 (allocates isochronous bandwidth)
    log("CLI: setAlternateInterface(1)")
    try device.setAlternateInterface(1)

    // Re-apply FrameRate1 UsbSetting after alt change (keeps E0=0x08).
    log("CLI: re-apply configureForOV2640RAW8 after alt=1 (E0=0x08)")
    try ov550.configureForOV2640RAW8()

    // Dump ASIC registers before streaming
    log("CLI: dumping key ASIC regs before stream")
    // Note: 0x1D is a write-only FIFO — reading it would consume a FIFO entry and corrupt
    // the streaming config. 0xC3/0xD9 are write-only and always read 0x00 (no diagnostic value).
    for reg: UInt16 in [0x0F, 0x1C, 0x35, 0xDA, 0xE0, 0xE5, 0xE7, 0x8C, 0x8D] {
        if let v = try? transport.readRegister(reg) {
            log(String(format: "  ASIC 0x%02X = 0x%02X", reg, v))
        }
    }

    // startStream (E0=0x00) is now issued inside readFrame at batch 0, immediately before
    // the first sendIORequestWithData. This minimises the race window for C3 (armed above
    // with E0=0x08) firing at the first VSYNC before any pending requests exist.

    // Capture frame
    log("CLI: readFrame (timeout=15s)")
    let rawData = try device.readFrame(withTimeout: 15.0)
    log("CLI: got \(rawData.count) bytes raw")


    // Save raw data
    let rawURL = URL(fileURLWithPath: "\(outputPath).raw")
    try rawData.write(to: rawURL)
    log("CLI: raw saved to \(rawURL.path)")

    // Compute actual frame height from received bytes (OV550 outputs one FIFO flush per
    // C3 arm — typically ~614KB = ~386 rows at 1600px wide, not the full 1200 rows).
    let frameWidth  = ScannerDevice.frameWidth
    let frameHeight = rawData.count / frameWidth
    log("CLI: frame \(frameWidth)×\(frameHeight) (\(rawData.count) bytes)")

    // Trim to whole rows to satisfy demosaic precondition (rawData may have a partial row tail).
    let trimmedData = rawData.count % frameWidth == 0
        ? rawData
        : rawData.prefix(frameHeight * frameWidth)

    // Demosaic and save PNG
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
