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

    // Power cycle the sensor to clear any stale SCCB bus state from previous runs.
    // Toggling E7=0x3B→0x3A resets OV2640's power/SCCB state without USB replug.
    log("CLI: powerCycle (clears stale SCCB)")
    try ov550.powerDown()
    Thread.sleep(forTimeInterval: 0.1)
    try ov550.powerOn()
    Thread.sleep(forTimeInterval: 0.5)

    // Apply Base UsbSetting BEFORE enabling streaming (E0 still 0x08 from powerOn).
    // Windows driver applies Base UsbSetting at connect time, before TurnOnLed.
    log("CLI: applyBaseUSBConfig (E0=0x08 still)")
    try ov550.applyBaseUSBConfig()

    // Enable LED — sets E0=0x00 (streaming enabled) and turns on illumination
    log("CLI: setLED on")
    try ov550.setLED(on: true)

    // Verify SCCB writes work (write-only round-trip, no reads that corrupt bus state)
    log("CLI: verifyChipID")
    let validID = try sensor.verifyChipID()
    log("CLI: chipID valid=\(validID)")

    // Initialize sensor (CameraSetting)
    log("CLI: sensor.initialize()")
    try sensor.initialize()
    log("CLI: sensor init done")

    // Apply FrameRate1 sensor registers (FrameRate1/CameraSetting)
    log("CLI: applyFrameRate1 sensor regs")
    try sensor.applyFrameRate1()

    // Apply FrameRate1 UsbSetting — sets MCLK and primes 1C/1D FIFO for streaming
    log("CLI: configureForOV2640RAW8 (FrameRate1 UsbSetting)")
    try ov550.configureForOV2640RAW8()
    // Allow MCLK and sensor PLL to stabilise
    log("CLI: MCLK/PLL settle 1s")
    Thread.sleep(forTimeInterval: 1.0)

    // Set alt interface 1 (allocates isochronous bandwidth)
    log("CLI: setAlternateInterface(1)")
    try device.setAlternateInterface(1)

    // Alt change clears C3=0xF9 (PRE enable) and may reset 1D FIFO state.
    // Re-apply FrameRate1 UsbSetting to restore C3 and FIFO before streaming.
    log("CLI: re-apply configureForOV2640RAW8 after alt=1 (restores C3=0xF9)")
    try ov550.configureForOV2640RAW8()

    // Dump ASIC registers before streaming
    log("CLI: dumping key ASIC regs before stream")
    for reg: UInt16 in [0x0F, 0x1C, 0x1D, 0x35, 0xC3, 0xD9, 0xDA, 0xE0, 0xE5, 0xE7, 0x8C, 0x8D] {
        if let v = try? transport.readRegister(reg) {
            log(String(format: "  ASIC 0x%02X = 0x%02X", reg, v))
        }
    }

    // E0 is already 0x00 from setLED; SetUsbWork (E0=0x00) as Windows driver does at stream start
    log("CLI: startStream (SetUsbWork E0=0x00 — no blockStream)")
    try ov550.startStream()
    Thread.sleep(forTimeInterval: 0.5)

    // Capture frame
    log("CLI: readFrame (timeout=15s)")
    let rawData = try device.readFrame(withTimeout: 15.0)
    log("CLI: got \(rawData.count) bytes raw")

    try? ov550.blockStream()
    try? ov550.setLED(on: false)

    // Save raw data
    let rawURL = URL(fileURLWithPath: "\(outputPath).raw")
    try rawData.write(to: rawURL)
    log("CLI: raw saved to \(rawURL.path)")

    // Demosaic and save PNG
    let rgb = BayerDemosaic.demosaic(rawData,
                                     width: ScannerDevice.frameWidth,
                                     height: ScannerDevice.frameHeight,
                                     pattern: .rggb)
    if let img = BayerDemosaic.nsImage(fromRGB: rgb,
                                        width: ScannerDevice.frameWidth,
                                        height: ScannerDevice.frameHeight),
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
